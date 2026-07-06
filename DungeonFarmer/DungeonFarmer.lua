local addonName, addon = ...

-- Public addon metadata
local ADDON_TITLE = "DungeonFarmer"
local ADDON_AUTHOR = "Csongor Farago"
local ADDON_MODEL = "OpenAI GPT-5 (Codex)"
local ADDON_VERSION = "1.0.0"

-- User-configurable settings
local WINDOW_SECONDS = 3600
local LOG_RETENTION_SECONDS = 5400
local MAX_DUNGEONS_PER_HOUR = 10
local GREEN_COLOR_COUNT_THRESHOLD = 7
local ORANGE_COLOR_COUNT_THRESHOLD = 9
local RED_COLOR_COUNT_THRESHOLD = 10

-- Internal constants
local NO_LOCKOUTS_TEXT = "No active hourly dungeon lockouts."
local CHAT_PREFIX = "|cffffd100DungeonFarmer:|r"
local TOOLTIP_REFRESH_SECONDS = 1
local RESET_DEBOUNCE_SECONDS = 2
local ACTIVE_STATUS_TEXT = "A"
local INACTIVE_STATUS_TEXT = "X"
local ACTIVE_LOG_COLOR = "ffffffff"
local INACTIVE_LOG_COLOR = "ff9d9d9d"

local eventFrame = CreateFrame("Frame")
local lastDungeonKey
local lastResetAdvanceAt = 0
local instanceResetHooked = false

addon.TITLE = ADDON_TITLE
addon.AUTHOR = ADDON_AUTHOR
addon.MODEL = ADDON_MODEL
addon.VERSION = ADDON_VERSION

-- Player identity helpers
local function BuildCharacterKey(characterName, realmName)
    return string.format("%s:%s", realmName or "Unknown", characterName or "Unknown")
end

local function GetPlayerIdentity()
    local name, realm = UnitName("player")
    if not name then
        return "Unknown", "Unknown"
    end

    if realm and realm ~= "" then
        return name, realm
    end

    local normalizedRealm = GetNormalizedRealmName and GetNormalizedRealmName()
    if normalizedRealm and normalizedRealm ~= "" then
        return name, normalizedRealm
    end

    return name, "Unknown"
end

local function GetNow()
    if GetServerTime then
        local serverTime = GetServerTime()
        if type(serverTime) == "number" and serverTime > 0 then
            return serverTime
        end
    end

    return time()
end

-- SavedVariables storage
local function GetDatabase()
    if type(DungeonFarmerDB) ~= "table" then
        DungeonFarmerDB = {}
    end

    if type(DungeonFarmerDB.log) ~= "table" then
        DungeonFarmerDB.log = {}
    end

    if type(DungeonFarmerDB.resetSequences) ~= "table" then
        DungeonFarmerDB.resetSequences = {}
    end

    return DungeonFarmerDB
end

-- Log retention and lockout timing
local function GetEntryTime(entry)
    if not entry then
        return nil
    end

    return tonumber(entry.entryTime) or tonumber(entry.time)
end

local function GetLockoutReferenceTime(entry)
    if not entry then
        return nil
    end

    return tonumber(entry.exitTime) or GetEntryTime(entry)
end

local function IsEntryActive(entry, now)
    local lockoutReferenceTime = GetLockoutReferenceTime(entry)
    return lockoutReferenceTime and (now - lockoutReferenceTime) < WINDOW_SECONDS
end

local function GetLogRetentionReferenceTime(entry)
    if not entry then
        return nil
    end

    local lastSeenTime = tonumber(entry.lastSeenTime)
    if lastSeenTime then
        return lastSeenTime
    end

    local exitTime = tonumber(entry.exitTime)
    if exitTime then
        return exitTime
    end

    return GetEntryTime(entry)
end

local function GetCharacterResetSequence(characterName, realmName)
    local database = GetDatabase()
    local characterKey = BuildCharacterKey(characterName, realmName)
    local resetSequence = tonumber(database.resetSequences[characterKey]) or 0

    database.resetSequences[characterKey] = resetSequence
    return resetSequence
end

local function AdvanceCharacterResetSequence()
    local characterName, realmName = GetPlayerIdentity()
    local database = GetDatabase()
    local characterKey = BuildCharacterKey(characterName, realmName)
    local nextResetSequence = GetCharacterResetSequence(characterName, realmName) + 1

    database.resetSequences[characterKey] = nextResetSequence
    return nextResetSequence
end

local function NormalizeEntry(entry)
    local timestamp = entry and tonumber(entry.time)
    if not timestamp then
        return nil
    end

    entry.time = timestamp
    entry.entryTime = tonumber(entry.entryTime) or timestamp
    entry.exitTime = entry.exitTime and tonumber(entry.exitTime) or nil
    entry.lastSeenTime = tonumber(entry.lastSeenTime) or tonumber(entry.exitTime) or entry.entryTime
    entry.resetSequence = tonumber(entry.resetSequence) or 0
    return entry
end

local function PruneEntries(now)
    local entries = GetDatabase().log
    local writeIndex = 1

    for readIndex = 1, #entries do
        local entry = NormalizeEntry(entries[readIndex])
        local retentionReferenceTime = entry and GetLogRetentionReferenceTime(entry)

        if entry and retentionReferenceTime and (now - retentionReferenceTime) < LOG_RETENTION_SECONDS then
            entries[writeIndex] = entry
            writeIndex = writeIndex + 1
        end
    end

    for clearIndex = writeIndex, #entries do
        entries[clearIndex] = nil
    end

    return writeIndex - 1
end

-- Dungeon entry detection and recording
local function GetCurrentDungeonDetails()
    local instanceName, instanceType, difficultyID, _, _, _, _, instanceMapID, _, lfgDungeonID = GetInstanceInfo()
    return {
        instanceName = instanceName or "Unknown",
        instanceType = instanceType or "unknown",
        difficultyID = difficultyID or 0,
        instanceID = instanceMapID or 0,
        lfgDungeonID = lfgDungeonID or 0,
    }
end

local function IsTrackedDungeon(details)
    local inInstance, instanceType = IsInInstance()
    return inInstance and instanceType == "party" and details and details.instanceType == "party"
end

local function BuildDungeonKey(details)
    if not details or not details.instanceName or not details.instanceType then
        return nil
    end

    return table.concat({
        tostring(details.instanceName),
        tostring(details.instanceType),
        tostring(details.difficultyID),
        tostring(details.instanceID),
        tostring(details.lfgDungeonID),
    }, ":")
end

local function FindReusableDungeonEntry(dungeonKey, characterName, realmName)
    local currentResetSequence = GetCharacterResetSequence(characterName, realmName)
    local entries = GetDatabase().log

    for index = #entries, 1, -1 do
        local entry = entries[index]
        if entry
            and entry.characterName == characterName
            and entry.realmName == realmName
            and entry.dungeonKey == dungeonKey
            and (tonumber(entry.resetSequence) or 0) == currentResetSequence then
            return entry
        end
    end
end

local function UpdateDungeonEntry(entry, details, now)
    entry.instanceName = details.instanceName
    entry.instanceID = details.instanceID
    entry.exitTime = nil
    entry.lastSeenTime = now
    return entry
end

local function CreateDungeonEntry(database, details, characterName, realmName, dungeonKey, now)
    local entry = {
        time = now,
        entryTime = now,
        exitTime = nil,
        lastSeenTime = now,
        characterName = characterName,
        realmName = realmName,
        instanceName = details.instanceName,
        instanceID = details.instanceID,
        dungeonKey = dungeonKey,
        resetSequence = GetCharacterResetSequence(characterName, realmName),
    }

    database.log[#database.log + 1] = entry
    return entry
end

local function EnsureDungeonEntry(details, reuseClosedEntry)
    local now = GetNow()
    local characterName, realmName = GetPlayerIdentity()
    local database = GetDatabase()
    local dungeonKey = BuildDungeonKey(details)
    local reusableEntry

    PruneEntries(now)
    reusableEntry = FindReusableDungeonEntry(dungeonKey, characterName, realmName)
    if reusableEntry then
        if reuseClosedEntry or not reusableEntry.exitTime then
            return UpdateDungeonEntry(reusableEntry, details, now)
        end
    end

    return CreateDungeonEntry(database, details, characterName, realmName, dungeonKey, now)
end

local function RestoreDungeonEntry(details)
    -- On login or /reload inside a dungeon, only resume an already-open row.
    -- If the newest matching row is closed, treat the current instance presence as a new run.
    return EnsureDungeonEntry(details, false)
end

local function RecordDungeonEntry(details)
    return EnsureDungeonEntry(details, true)
end

local function FindMostRecentOpenEntry(characterName, realmName)
    local entries = GetDatabase().log

    for index = #entries, 1, -1 do
        local entry = entries[index]
        if entry
            and entry.characterName == characterName
            and entry.realmName == realmName
            and not tonumber(entry.exitTime) then
            return entry
        end
    end
end

local function RecordDungeonExit()
    local characterName, realmName = GetPlayerIdentity()
    local now = GetNow()
    local entry = FindMostRecentOpenEntry(characterName, realmName)
    if not entry then
        return
    end

    entry.exitTime = now
    entry.lastSeenTime = now
end

local function IsStartupWorldEntry(isInitialLogin, isReloadingUi)
    return isInitialLogin or isReloadingUi
end

local function UpdateDungeonHistory(isInitialLogin, isReloadingUi)
    local details = GetCurrentDungeonDetails()
    if not IsTrackedDungeon(details) then
        if not IsStartupWorldEntry(isInitialLogin, isReloadingUi) and lastDungeonKey then
            RecordDungeonExit()
        end
        lastDungeonKey = nil
        return
    end

    local dungeonKey = BuildDungeonKey(details)
    if IsStartupWorldEntry(isInitialLogin, isReloadingUi) then
        RestoreDungeonEntry(details)
        lastDungeonKey = dungeonKey
        return
    end

    if dungeonKey ~= lastDungeonKey then
        if lastDungeonKey then
            RecordDungeonExit()
        end

        RecordDungeonEntry(details)
    end

    lastDungeonKey = dungeonKey
end

-- Display helpers
local function TryAdvanceResetSequence()
    local now = GetNow()
    if (now - lastResetAdvanceAt) < RESET_DEBOUNCE_SECONDS then
        return
    end

    AdvanceCharacterResetSequence()
    lastResetAdvanceAt = now
end

local function ExtractMessageFromEventArgs(...)
    local firstArg, secondArg = ...

    if type(firstArg) == "string" then
        return firstArg
    end

    if type(secondArg) == "string" then
        return secondArg
    end

    return nil
end

local function IsInstanceResetMessage(message)
    if type(message) ~= "string" or message == "" then
        return false
    end

    if INSTANCE_RESET_SUCCESS and message == INSTANCE_RESET_SUCCESS then
        return true
    end

    local normalizedMessage = strlower(message)
    if normalizedMessage:find("cannot", 1, true) or normalizedMessage:find("can't", 1, true) then
        return false
    end

    if normalizedMessage:find("all instances have been reset", 1, true) then
        return true
    end

    if normalizedMessage:find("all instances are reset", 1, true) then
        return true
    end

    if normalizedMessage:find("instance has been reset", 1, true) then
        return true
    end

    if normalizedMessage:find("instances have been reset", 1, true) then
        return true
    end

    return false
end

local function HookInstanceReset()
    if type(ResetInstances) ~= "function" or instanceResetHooked then
        return
    end

    hooksecurefunc("ResetInstances", function()
        TryAdvanceResetSequence()
    end)

    instanceResetHooked = true
end

local function GetCountColor(count)
    if count >= RED_COLOR_COUNT_THRESHOLD then
        return 1.00, 0.25, 0.25, "ff4040"
    end

    if count <= GREEN_COLOR_COUNT_THRESHOLD then
        return 0.25, 1.00, 0.25, "40ff40"
    end

    if count <= ORANGE_COLOR_COUNT_THRESHOLD then
        return 1.00, 0.65, 0.00, "ffaa00"
    end

    return 1.00, 0.65, 0.00, "ffaa00"
end

local function BuildNextLockoutText(secondsUntilNextLockoutFalls)
    local nextLockoutText

    if secondsUntilNextLockoutFalls then
        if secondsUntilNextLockoutFalls < 60 then
            local secondLabel = secondsUntilNextLockoutFalls == 1 and "second" or "seconds"
            nextLockoutText = string.format("%d %s until next lockout falls", secondsUntilNextLockoutFalls, secondLabel)
        else
            local minutesUntilNextLockoutFalls = math.ceil(secondsUntilNextLockoutFalls / 60)
            local minuteLabel = minutesUntilNextLockoutFalls == 1 and "minute" or "minutes"
            nextLockoutText = string.format("%d %s until next lockout falls", minutesUntilNextLockoutFalls, minuteLabel)
        end
    else
        nextLockoutText = NO_LOCKOUTS_TEXT
    end

    return nextLockoutText
end

local function BuildDisplayInfo(activeEntryCount, secondsUntilNextLockoutFalls)
    local red, green, blue, chatColor = GetCountColor(activeEntryCount)
    local shortCountText = string.format("%d/%d", activeEntryCount, MAX_DUNGEONS_PER_HOUR)

    return {
        count = activeEntryCount,
        shortCountText = shortCountText,
        countText = string.format("Entered in the last hour: %s", shortCountText),
        nextLockoutText = BuildNextLockoutText(secondsUntilNextLockoutFalls),
        color = {
            r = red,
            g = green,
            b = blue,
        },
        chatColor = chatColor,
    }
end

local function CreateDisplaySnapshot()
    local now = GetNow()
    PruneEntries(now)
    local entries = GetDatabase().log
    local expirationTimes = {}

    for _, entry in ipairs(entries) do
        local lockoutReferenceTime = GetLockoutReferenceTime(entry)
        if IsEntryActive(entry, now) and lockoutReferenceTime then
            expirationTimes[#expirationTimes + 1] = lockoutReferenceTime + WINDOW_SECONDS
        end
    end

    table.sort(expirationTimes)

    return {
        expirationTimes = expirationTimes,
        nextExpirationIndex = 1,
    }
end

local function GetDisplayInfoFromSnapshot(snapshot)
    if not snapshot then
        return BuildDisplayInfo(0, nil)
    end

    local now = GetNow()
    local expirationTimes = snapshot.expirationTimes or {}
    local nextExpirationIndex = snapshot.nextExpirationIndex or 1

    while expirationTimes[nextExpirationIndex] and expirationTimes[nextExpirationIndex] <= now do
        nextExpirationIndex = nextExpirationIndex + 1
    end

    snapshot.nextExpirationIndex = nextExpirationIndex

    local nextExpirationTime = expirationTimes[nextExpirationIndex]
    local activeEntryCount
    local secondsUntilNextLockoutFalls

    if nextExpirationTime then
        activeEntryCount = #expirationTimes - nextExpirationIndex + 1
        secondsUntilNextLockoutFalls = math.max(0, nextExpirationTime - now)
    else
        activeEntryCount = 0
        secondsUntilNextLockoutFalls = nil
    end

    return BuildDisplayInfo(activeEntryCount, secondsUntilNextLockoutFalls)
end

local function GetDisplayInfo()
    return GetDisplayInfoFromSnapshot(CreateDisplaySnapshot())
end

local function CreateTooltipDisplayState()
    local snapshot = CreateDisplaySnapshot()
    return snapshot, GetDisplayInfoFromSnapshot(snapshot)
end

addon.CreateDisplaySnapshot = CreateDisplaySnapshot
addon.GetDisplayInfo = GetDisplayInfo
addon.GetDisplayInfoFromSnapshot = GetDisplayInfoFromSnapshot

-- Chat output and slash commands
local function PrintAddonMessage(message)
    print(string.format("%s %s", CHAT_PREFIX, message))
end

local function PrintPlainMessage(message)
    print(message)
end

local function GetRetentionWindowText()
    if (LOG_RETENTION_SECONDS % 60) == 0 then
        return string.format("%d minutes", LOG_RETENTION_SECONDS / 60)
    end

    return string.format("%d seconds", LOG_RETENTION_SECONDS)
end

local function GetRetainedLogHeading()
    return string.format("Retained log entries from the last %s:", GetRetentionWindowText())
end

local function GetEmptyLogMessage()
    return string.format("No retained log entries in the last %s.", GetRetentionWindowText())
end

local function FormatEntryTime(entry)
    return date("%Y-%m-%d %H:%M:%S", tonumber(entry.entryTime) or tonumber(entry.time))
end

local function FormatExitTime(entry)
    return entry.exitTime and date("%H:%M:%S", tonumber(entry.exitTime)) or "-"
end

local function BuildLogStatus(entry, now)
    if IsEntryActive(entry, now) then
        return ACTIVE_STATUS_TEXT, ACTIVE_LOG_COLOR
    end

    return INACTIVE_STATUS_TEXT, INACTIVE_LOG_COLOR
end

local function PrintStatus(displayInfo, usePrefix)
    local printer = usePrefix == false and PrintPlainMessage or PrintAddonMessage
    printer(string.format("|cff%s%s|r", displayInfo.chatColor, displayInfo.countText))
    printer(displayInfo.nextLockoutText)
end

local function PrintDungeonLog()
    local database = GetDatabase()
    local displayInfo = GetDisplayInfo()
    local now = GetNow()

    PrintAddonMessage(string.format("|cff%s%s|r", displayInfo.chatColor, displayInfo.countText))
    PrintPlainMessage(displayInfo.nextLockoutText)
    if #database.log == 0 then
        PrintPlainMessage(GetEmptyLogMessage())
        return
    end

    PrintPlainMessage(GetRetainedLogHeading())
    for _, entry in ipairs(database.log) do
        local statusText, colorCode = BuildLogStatus(entry, now)
        PrintPlainMessage(string.format(
            "|c%s%s | %s | %s | %s | %s | %s|r",
            colorCode,
            FormatEntryTime(entry),
            FormatExitTime(entry),
            entry.realmName or "Unknown",
            entry.characterName or "Unknown",
            entry.instanceName or "Unknown",
            statusText
        ))
    end
end

local function PrintDungeonCount()
    PrintStatus(GetDisplayInfo())
end

addon.PrintDungeonLog = PrintDungeonLog

local function RegisterSlashCommands()
    SLASH_DUNGEONFARMER1 = "/dungeonfarmer"
    SLASH_DUNGEONFARMER2 = "/df"
    SLASH_DUNGEONFARMERLOG1 = "/dflog"

    SlashCmdList.DUNGEONFARMER = function(message)
        local command = strlower(strtrim(message or ""))
        if command == "log" then
            PrintDungeonLog()
            return
        end

        PrintDungeonCount()
    end

    SlashCmdList.DUNGEONFARMERLOG = function()
        PrintDungeonLog()
    end
end

-- Minimap tooltip hooks
local function GetTooltipLineFontString(tooltip, lineIndex)
    local tooltipName = tooltip and tooltip:GetName()
    if not tooltipName then
        return nil
    end

    return _G[string.format("%sTextLeft%d", tooltipName, lineIndex)]
end

local function GetTooltipLineText(tooltip, lineIndex)
    local fontString = GetTooltipLineFontString(tooltip, lineIndex)
    return fontString and fontString:GetText() or nil
end

local function SetTooltipLine(tooltip, lineIndex, text, red, green, blue)
    local fontString = GetTooltipLineFontString(tooltip, lineIndex)
    if not fontString then
        return
    end

    fontString:SetText(text)
    if red and green and blue then
        fontString:SetTextColor(red, green, blue)
    end
end

local function IsDifficultyTooltipText(tooltip)
    local line1 = GetTooltipLineText(tooltip, 1)
    local line2 = GetTooltipLineText(tooltip, 2)

    if not line1 or not line2 then
        return false
    end

    local hasDifficultyHeader = line1:find("Difficulty", 1, true) ~= nil
    local hasPlayerCount = line2:find("Players", 1, true) ~= nil and line2:find("%d+/%d+") ~= nil

    return hasDifficultyHeader and hasPlayerCount
end

local function StopDifficultyTooltipRefresh(tooltip)
    if tooltip and tooltip.DungeonFarmerRefreshTicker then
        tooltip.DungeonFarmerRefreshTicker:Cancel()
        tooltip.DungeonFarmerRefreshTicker = nil
    end
end

local function RefreshDifficultyTooltip(tooltip)
    if not tooltip or not tooltip.DungeonFarmerSnapshot then
        return
    end

    local displayInfo = GetDisplayInfoFromSnapshot(tooltip.DungeonFarmerSnapshot)
    SetTooltipLine(tooltip, tooltip.DungeonFarmerCountLineIndex, displayInfo.countText, displayInfo.color.r, displayInfo.color.g, displayInfo.color.b)
    SetTooltipLine(tooltip, tooltip.DungeonFarmerLockoutLineIndex, displayInfo.nextLockoutText, 1.00, 1.00, 1.00)
end

local function StartDifficultyTooltipRefresh(tooltip)
    if not tooltip or tooltip.DungeonFarmerRefreshTicker then
        return
    end

    tooltip.DungeonFarmerRefreshTicker = C_Timer.NewTicker(TOOLTIP_REFRESH_SECONDS, function()
        if not tooltip:IsShown() or not tooltip.DungeonFarmerAppended then
            StopDifficultyTooltipRefresh(tooltip)
            return
        end

        RefreshDifficultyTooltip(tooltip)
    end)
end

local function AppendTooltipLine(tooltip)
    if not tooltip or tooltip.DungeonFarmerAppended or not IsDifficultyTooltipText(tooltip) then
        return
    end

    local displaySnapshot, displayInfo = CreateTooltipDisplayState()
    local countLineIndex = tooltip:NumLines() + 2
    local lockoutLineIndex = tooltip:NumLines() + 3

    tooltip.DungeonFarmerAppended = true
    tooltip.DungeonFarmerSnapshot = displaySnapshot
    tooltip.DungeonFarmerCountLineIndex = countLineIndex
    tooltip.DungeonFarmerLockoutLineIndex = lockoutLineIndex
    tooltip:AddLine(" ")
    tooltip:AddLine(displayInfo.countText, displayInfo.color.r, displayInfo.color.g, displayInfo.color.b, true)
    tooltip:AddLine(displayInfo.nextLockoutText, 1.00, 1.00, 1.00, true)
    StartDifficultyTooltipRefresh(tooltip)
    tooltip:Show()
end

local function HookDifficultyTooltip()
    if not GameTooltip or GameTooltip.DungeonFarmerHooked then
        return
    end

    GameTooltip:HookScript("OnShow", function(tooltip)
        C_Timer.After(0, function()
            if tooltip and tooltip:IsShown() then
                AppendTooltipLine(tooltip)
            end
        end)
    end)

    GameTooltip:HookScript("OnHide", function(tooltip)
        StopDifficultyTooltipRefresh(tooltip)
        tooltip.DungeonFarmerAppended = nil
        tooltip.DungeonFarmerSnapshot = nil
        tooltip.DungeonFarmerCountLineIndex = nil
        tooltip.DungeonFarmerLockoutLineIndex = nil
    end)

    GameTooltip.DungeonFarmerHooked = true
end

-- Addon lifecycle and command registration
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")
eventFrame:RegisterEvent("UI_INFO_MESSAGE")
eventFrame:RegisterEvent("UI_ERROR_MESSAGE")
eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddonName = ...
        if loadedAddonName == addonName then
            PruneEntries(GetNow())
        end
        return
    end

    if event == "PLAYER_LOGIN" then
        RegisterSlashCommands()
        HookDifficultyTooltip()
        HookInstanceReset()
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        local isInitialLogin, isReloadingUi = ...
        UpdateDungeonHistory(isInitialLogin, isReloadingUi)
        return
    end

    if event == "CHAT_MSG_SYSTEM" or event == "UI_INFO_MESSAGE" or event == "UI_ERROR_MESSAGE" then
        local message = ExtractMessageFromEventArgs(...)
        if IsInstanceResetMessage(message) then
            TryAdvanceResetSequence()
        end
    end
end)
