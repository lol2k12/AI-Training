--[[
    STA TRUE AI - STAGE 1.5 PERSISTENT BRAIN v1.0.0

    PURPOSE
      * Persistent Brain shared across sessions
      * Legacy Memory Migrator (v1.0/v1.2/v1.3.1/v1.3.2/v1.4 + Stage1 + Event + Combat Outcome)
      * Cross-session loader/hydrator for STA TRUE AI v1.4.0
      * Safe save / backup / checksum / rollback
      * PC + Mobile compatible
      * Dynamic executor capability detection (Madium / Xeno / Potassium / Delta / Generic)

    SAFETY / TESTING BOUNDARIES
      * This Stage 1.5 layer NEVER calls FireServer or InvokeServer.
      * It NEVER writes KM_* attributes, movement state, trust state, remotes, callbacks or upvalues.
      * It does not generate combat or interaction traffic.
      * It only reads already-visible AI state and saves/loads local memory.
      * Hydration always leaves autonomy unarmed; Stage 1.5 persistence tests are SHADOW/OBSERVE-first.

    LOAD ORDER
      Recommended:
        1) Run STA_TRUE_AI_V140_COMPLETE.lua
        2) Run this Stage 1.5 file
        3) Start the observer (INSERT on PC or the mobile START button)

      This file can also be executed before v1.4.0; it will wait and attach when the v1.4 globals appear.

    FILES
      STA_STAGE15_PERSISTENT_BRAIN.json
      STA_STAGE15_PERSISTENT_BRAIN.checksum
      STA_STAGE15_PERSISTENT_BRAIN.bak.json
      STA_STAGE15_PERSISTENT_BRAIN.bak.checksum
      STA_STAGE15_MIGRATION_<session>.txt
      STA_STAGE15_DIAGNOSTICS_<session>.json
      STA_STAGE15_<session>.log

    MANUAL FALLBACKS
      If listfiles() is unavailable, set before running:
        getgenv().STA_STAGE15_LEGACY_FILES = {
            "STA_AI_MEMORY_V132_123.json",
            "STA_STAGE1_WORLD_MEMORY_V121_123.json",
            "ZHUB_COMBAT_OUTCOME_V21_..._AUTO_DATA.json",
        }

      If local read/write persistence is unavailable, you can still call:
        getgenv().STA_STAGE15_EXPORT()
      and later set:
        getgenv().STA_STAGE15_IMPORT_JSON = "<exported brain json>"
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    error("STA Stage 1.5: LocalPlayer not available")
end

local ENV = (getgenv and getgenv()) or _G
local TASK = task or {}
local taskWait = TASK.wait or wait
local taskSpawn = TASK.spawn or spawn
local taskDefer = TASK.defer or taskSpawn

local VERSION = "Stage1.5-v1.0.0"
local BRAIN_SCHEMA = "STA TRUE AI Persistent Brain Stage 1.5"
local BRAIN_VERSION = 1
local sessionUnix = os.time()

local CONFIG = {
    AutoAttach = true,
    AutoMigrateLegacy = true,
    AutoSaveSecondsDesktop = 30,
    AutoSaveSecondsMobile = 60,
    BaseAttachPollSeconds = 1.0,

    -- Avoid huge decode spikes. Large Stage1 files are selectively parsed.
    MaxSmallSectionDecodeBytesDesktop = 12 * 1024 * 1024,
    MaxSmallSectionDecodeBytesMobile = 3 * 1024 * 1024,
    SkipKnownHugeLegacyOnMobile = true,
    ForceLargeLegacyMigrationOnMobile = false,

    LegacyEpisodeSamplesPerType = 6,
    MaxLegacyRouteSamples = 40,
    MaxResourceClustersPerLegacySessionDesktop = 80,
    MaxResourceClustersPerLegacySessionMobile = 30,
    MaxCombatCorrelationSamplesPerSession = 30,

    MaxPersistedDecisionHistoryDesktop = 4000,
    MaxPersistedDecisionHistoryMobile = 1200,
    MaxPersistedExperiencePerBucketDesktop = 5000,
    MaxPersistedExperiencePerBucketMobile = 1500,

    CreateMobileGui = true,
    PrintStatus = true,
}

if type(ENV.STA_STAGE15_CONFIG) == "table" then
    for k,v in pairs(ENV.STA_STAGE15_CONFIG) do
        CONFIG[k] = v
    end
end

local FILES = {
    Brain = "STA_STAGE15_PERSISTENT_BRAIN.json",
    BrainChecksum = "STA_STAGE15_PERSISTENT_BRAIN.checksum",
    Backup = "STA_STAGE15_PERSISTENT_BRAIN.bak.json",
    BackupChecksum = "STA_STAGE15_PERSISTENT_BRAIN.bak.checksum",
    Temp = "STA_STAGE15_PERSISTENT_BRAIN.tmp.json",
    TempChecksum = "STA_STAGE15_PERSISTENT_BRAIN.tmp.checksum",
    Log = string.format("STA_STAGE15_%d.log", sessionUnix),
    MigrationReport = string.format("STA_STAGE15_MIGRATION_%d.txt", sessionUnix),
    Diagnostics = string.format("STA_STAGE15_DIAGNOSTICS_%d.json", sessionUnix),
}

local R = {
    running = true,
    attached = false,
    hydrated = false,
    hydrationAt = nil,
    lastSaveAt = 0,
    lastAttachTry = 0,
    lastBrainCaptureAt = 0,
    baseMemoryRef = nil,
    logBuffer = {},
    migrationLines = {},
    migrationStats = {
        discovered = 0,
        imported = 0,
        skipped = 0,
        deferred = 0,
        failed = 0,
        corrected = 0,
    },
    selfTest = {},
    mobileGui = nil,
    heartbeat = nil,
    historyRecorded = false,
}

-- ============================================================
-- DEVICE / EXECUTOR PROFILE
-- ============================================================

local function safeCall(fn, ...)
    if type(fn) ~= "function" then return false, nil end
    return pcall(fn, ...)
end

local function detectExecutorName()
    local probes = {
        function()
            if type(identifyexecutor) == "function" then
                local a,b = identifyexecutor()
                if a and tostring(a) ~= "" then
                    return b and (tostring(a) .. " / " .. tostring(b)) or tostring(a)
                end
            end
        end,
        function()
            if type(getexecutorname) == "function" then return getexecutorname() end
        end,
        function()
            if type(getexecutor) == "function" then return getexecutor() end
        end,
    }
    for _,probe in ipairs(probes) do
        local ok, value = pcall(probe)
        if ok and value and tostring(value) ~= "" then return tostring(value) end
    end
    if type(syn) == "table" then return "Synapse-compatible / Unknown" end
    return "Unknown"
end

local function executorFamily(name)
    local s = string.lower(tostring(name or ""))
    if string.find(s, "madium", 1, true) then return "MADIUM" end
    if string.find(s, "xeno", 1, true) then return "XENO" end
    if string.find(s, "potassium", 1, true) then return "POTASSIUM" end
    if string.find(s, "delta", 1, true) then return "DELTA" end
    return "GENERIC"
end

local function detectPlatform()
    local platform = "Unknown"
    pcall(function() platform = tostring(UserInputService:GetPlatform()) end)
    local touch = UserInputService.TouchEnabled == true
    local keyboard = UserInputService.KeyboardEnabled == true
    local mobile = touch and not keyboard
    return {
        platform = platform,
        touch = touch,
        keyboard = keyboard,
        mouse = UserInputService.MouseEnabled == true,
        gamepad = UserInputService.GamepadEnabled == true,
        mobile = mobile,
    }
end

local DEVICE = detectPlatform()
local EXECUTOR_NAME = detectExecutorName()
local EXECUTOR_FAMILY = executorFamily(EXECUTOR_NAME)

local API = {
    readfile = type(readfile) == "function" and readfile or nil,
    writefile = type(writefile) == "function" and writefile or nil,
    appendfile = type(appendfile) == "function" and appendfile or nil,
    isfile = type(isfile) == "function" and isfile or nil,
    delfile = type(delfile) == "function" and delfile or nil,
    listfiles = type(listfiles) == "function" and listfiles or nil,
    makefolder = type(makefolder) == "function" and makefolder or nil,
    isfolder = type(isfolder) == "function" and isfolder or nil,
    setclipboard = type(setclipboard) == "function" and setclipboard or nil,
    getfilesize = type(getfilesize) == "function" and getfilesize or nil,
}

local AUTO_PERSISTENCE = API.readfile ~= nil and API.writefile ~= nil

local function maxSmallSectionBytes()
    if DEVICE.mobile then return CONFIG.MaxSmallSectionDecodeBytesMobile end
    return CONFIG.MaxSmallSectionDecodeBytesDesktop
end

local function maxClusterKeep()
    if DEVICE.mobile then return CONFIG.MaxResourceClustersPerLegacySessionMobile end
    return CONFIG.MaxResourceClustersPerLegacySessionDesktop
end

-- ============================================================
-- LOGGING
-- ============================================================

local function elapsed()
    return os.clock()
end

local function logLine(kind, ...)
    local parts = {string.format("[%.3f]", elapsed()), tostring(kind)}
    local args = {...}
    for i=1,#args do parts[#parts+1] = tostring(args[i]) end
    local line = table.concat(parts, " | ")
    R.logBuffer[#R.logBuffer+1] = line
    if CONFIG.PrintStatus and (kind == "ERROR" or kind == "WARN" or kind == "READY" or kind == "MIGRATION") then
        print("[STA Stage 1.5] " .. line)
    end
end

local function flushLog()
    if #R.logBuffer == 0 then return end
    local text = table.concat(R.logBuffer, "\n") .. "\n"
    if API.appendfile then
        pcall(API.appendfile, FILES.Log, text)
        R.logBuffer = {}
        return
    end
    if API.writefile then
        local old = ""
        if API.readfile and API.isfile then
            pcall(function()
                if API.isfile(FILES.Log) then old = API.readfile(FILES.Log) or "" end
            end)
        end
        pcall(API.writefile, FILES.Log, old .. text)
        R.logBuffer = {}
    end
end

local function migrationLine(status, source, detail)
    local line = string.format("%s | %s | %s", tostring(status), tostring(source), tostring(detail or ""))
    R.migrationLines[#R.migrationLines+1] = line
    logLine("MIGRATION", line)
end

-- ============================================================
-- SAFE PRIMITIVE SERIALIZATION
-- ============================================================

local function validUtf8OrAsciiFallback(s)
    s = tostring(s or "")
    if utf8 and type(utf8.len) == "function" then
        local ok, length = pcall(function() return utf8.len(s) end)
        if ok and length ~= nil then return s end
    end
    return (string.gsub(s, "[\128-\255]", "?"))
end

local function finiteNumber(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function tableIsArray(t)
    local count = 0
    local max = 0
    for k,_ in pairs(t) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false, 0 end
        count = count + 1
        if k > max then max = k end
    end
    if count == 0 then return true, 0 end
    if max ~= count then return false, 0 end
    return true, count
end

local function jsonSafe(value, seen, depth)
    seen = seen or {}
    depth = depth or 0
    if depth > 40 then return "<MAX_DEPTH>" end

    local tv = type(value)
    if tv == "nil" then return nil end
    if tv == "boolean" then return value end
    if tv == "number" then
        if finiteNumber(value) then return value end
        return "<NONFINITE_NUMBER>"
    end
    if tv == "string" then return validUtf8OrAsciiFallback(value) end

    local robloxType = nil
    pcall(function() robloxType = typeof(value) end)
    if robloxType == "Vector3" then
        return {x=value.X, y=value.Y, z=value.Z}
    elseif robloxType == "Vector2" then
        return {x=value.X, y=value.Y}
    elseif robloxType == "CFrame" then
        local c = {value:GetComponents()}
        return c
    elseif robloxType == "Color3" then
        return {r=value.R, g=value.G, b=value.B}
    elseif robloxType == "EnumItem" then
        return tostring(value)
    elseif robloxType == "Instance" then
        local ok, path = pcall(function() return value:GetFullName() end)
        return ok and path or tostring(value)
    end

    if tv ~= "table" then return "<" .. tv .. ">" end
    if seen[value] then return "<CYCLE>" end
    seen[value] = true

    local isArray, n = tableIsArray(value)
    local out = {}
    if isArray then
        for i=1,n do
            local v = jsonSafe(value[i], seen, depth + 1)
            if v == nil then v = "<NIL>" end
            out[i] = v
        end
    else
        for k,v in pairs(value) do
            local key = validUtf8OrAsciiFallback(tostring(k))
            local safe = jsonSafe(v, seen, depth + 1)
            if safe ~= nil then out[key] = safe end
        end
    end
    seen[value] = nil
    return out
end

local ESCAPE_MAP = {
    ["\\"] = "\\\\",
    ["\""] = "\\\"",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

local function jsonEscape(s)
    s = validUtf8OrAsciiFallback(s)
    return (string.gsub(s, '[%z\1-\31\\"]', function(c)
        local mapped = ESCAPE_MAP[c]
        if mapped then return mapped end
        return string.format("\\u%04x", string.byte(c))
    end))
end

local function deterministicJsonEncode(value, seen)
    seen = seen or {}
    local tv = type(value)
    if tv == "nil" then return "null" end
    if tv == "boolean" then return value and "true" or "false" end
    if tv == "number" then
        if not finiteNumber(value) then return "null" end
        return tostring(value)
    end
    if tv == "string" then return '"' .. jsonEscape(value) .. '"' end
    if tv ~= "table" then return '"' .. jsonEscape(tostring(value)) .. '"' end
    if seen[value] then return '"<CYCLE>"' end
    seen[value] = true

    local isArray, n = tableIsArray(value)
    if isArray then
        local parts = {}
        for i=1,n do parts[i] = deterministicJsonEncode(value[i], seen) end
        seen[value] = nil
        return "[" .. table.concat(parts, ",") .. "]"
    end

    local keys = {}
    for k,_ in pairs(value) do keys[#keys+1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _,k in ipairs(keys) do
        parts[#parts+1] = '"' .. jsonEscape(k) .. '":' .. deterministicJsonEncode(value[k], seen)
    end
    seen[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

local function encodeSafe(value)
    local safe = jsonSafe(value, {}, 0)
    local ok, encoded = pcall(deterministicJsonEncode, safe, {})
    if ok and type(encoded) == "string" then return true, encoded end
    return false, tostring(encoded)
end

local function decodeJson(text)
    if type(text) ~= "string" then return false, "NOT_STRING" end
    local ok, value = pcall(function() return HttpService:JSONDecode(text) end)
    if ok then return true, value end
    return false, tostring(value)
end

-- Adler32: portable checksum without bit operations.
local function adler32(text)
    local MOD = 65521
    local a, b = 1, 0
    for i=1,#text do
        a = (a + string.byte(text, i)) % MOD
        b = (b + a) % MOD
    end
    return b * 65536 + a
end

local function checksumText(text)
    return string.format("A32:%u:%d", adler32(text), #text)
end

-- ============================================================
-- FILE HELPERS / SAFE SAVE
-- ============================================================

local function fileExists(path)
    if API.isfile then
        local ok, exists = pcall(API.isfile, path)
        return ok and exists == true
    end
    if API.readfile then
        local ok = pcall(API.readfile, path)
        return ok
    end
    return false
end

local function readText(path)
    if not API.readfile then return false, "READFILE_UNAVAILABLE" end
    local ok, data = pcall(API.readfile, path)
    if not ok then return false, tostring(data) end
    if type(data) ~= "string" then return false, "READFILE_NOT_STRING" end
    return true, data
end

local function writeText(path, text)
    if not API.writefile then return false, "WRITEFILE_UNAVAILABLE" end
    local ok, err = pcall(API.writefile, path, text)
    if not ok then return false, tostring(err) end
    return true
end

local function writeVerified(path, text)
    local ok, err = writeText(path, text)
    if not ok then return false, err end
    if API.readfile then
        local rok, back = readText(path)
        if not rok then return false, "VERIFY_READ_FAIL:" .. tostring(back) end
        if #back ~= #text then
            return false, string.format("VERIFY_SIZE_FAIL expected=%d actual=%d", #text, #back)
        end
        if checksumText(back) ~= checksumText(text) then return false, "VERIFY_CHECKSUM_FAIL" end
    end
    return true
end

local function deleteIfPossible(path)
    if API.delfile and fileExists(path) then pcall(API.delfile, path) end
end

local function validateBrainJson(raw, checksumRaw)
    if type(raw) ~= "string" or #raw < 2 then return false, nil, "EMPTY_BRAIN" end
    if type(checksumRaw) == "string" and checksumRaw ~= "" then
        local expected = string.gsub(checksumRaw, "%s+$", "")
        local actual = checksumText(raw)
        if expected ~= actual then
            return false, nil, "CHECKSUM_FAIL expected=" .. expected .. " actual=" .. actual
        end
    end
    local ok, decoded = decodeJson(raw)
    if not ok or type(decoded) ~= "table" then return false, nil, "JSON_DECODE_FAIL:" .. tostring(decoded) end
    if decoded.schema ~= BRAIN_SCHEMA then
        return false, nil, "SCHEMA_MISMATCH:" .. tostring(decoded.schema)
    end
    return true, decoded
end

-- ============================================================
-- BRAIN SCHEMA
-- ============================================================

local function newBrain()
    return {
        schema = BRAIN_SCHEMA,
        brainVersion = BRAIN_VERSION,
        createdUnix = os.time(),
        updatedUnix = os.time(),
        meta = {
            stage = "1.5",
            sourceSessions = {},
            deviceHistory = {},
            executorHistory = {},
            lastPlaceId = game.PlaceId,
            lastJobId = game.JobId,
            persistenceMode = AUTO_PERSISTENCE and "AUTO_LOCAL" or "MANUAL_EXPORT",
        },
        evidenceStore = {
            confirmedRuntime = {},
            confirmedSource = {},
            observedSession = {},
            inference = {},
            unknown = {},
            ruledOut = {},
            corrections = {},
        },
        worldMemory = {
            sessionSummaries = {},
            baseProfiles = {},
            resourceProfiles = {},
            semanticRules = {},
        },
        playerExperience = {
            legacyEpisodeSummary = {},
            routeSamples = {},
        },
        economyMemory = {
            sessions = {},
            skullRewards = {},
            shop = {},
            upgrades = {},
        },
        eventMemory = {
            reactor = {sessions = {}, messages = {}, observations = {}},
            military = {sessions = {}, observations = {}},
            supplyDrops = {sessions = {}},
            hostileDebuffs = {},
        },
        combatMemory = {
            sessions = {},
            jobLatest = {},
            weaponStats = {},
            confidenceTotals = {
                CONFIRMED = 0,
                HIGH_CONFIDENCE = 0,
                MEDIUM_CONFIDENCE = 0,
                LOW_CONFIDENCE = 0,
                UNMATCHED = 0,
            },
        },
        networkMemory = {
            quickNet = {},
            replication = {sessions={}},
            trustTelemetry = {sessions={}},
            technicalEvidence = {},
        },
        live = {
            capabilityMemory = {},
            experienceMemory = {player={}, ai={}, shadow={}, failures={}, predictions={}},
            skillRegistry = {skills={}, rollbacks={}, adaptations={}},
            decisionMemory = {decisions={}, goalStats={}},
            policyMemory = {parameters={}, version=1, history={}},
            runtimeKnowledge = {},
            worldSummary = {},
        },
        diagnostics = {
            loadHistory = {},
            saveHistory = {},
            warnings = {},
        },
        migrationLedger = {
            importedSources = {},
            deferredSources = {},
            failedSources = {},
            corrections = {},
        },
    }
end

local function normalizeBrain(b)
    if type(b) ~= "table" then b = newBrain() end
    b.schema = BRAIN_SCHEMA
    b.brainVersion = tonumber(b.brainVersion) or BRAIN_VERSION
    b.createdUnix = b.createdUnix or os.time()
    b.updatedUnix = b.updatedUnix or os.time()
    b.meta = b.meta or {}
    b.meta.sourceSessions = b.meta.sourceSessions or {}
    b.meta.deviceHistory = b.meta.deviceHistory or {}
    b.meta.executorHistory = b.meta.executorHistory or {}
    b.evidenceStore = b.evidenceStore or {}
    for _,k in ipairs({"confirmedRuntime","confirmedSource","observedSession","inference","unknown","ruledOut","corrections"}) do
        b.evidenceStore[k] = b.evidenceStore[k] or {}
    end
    b.worldMemory = b.worldMemory or {}
    for _,k in ipairs({"sessionSummaries","baseProfiles","resourceProfiles","semanticRules"}) do b.worldMemory[k] = b.worldMemory[k] or {} end
    b.playerExperience = b.playerExperience or {}
    b.playerExperience.legacyEpisodeSummary = b.playerExperience.legacyEpisodeSummary or {}
    b.playerExperience.routeSamples = b.playerExperience.routeSamples or {}
    b.economyMemory = b.economyMemory or {}
    for _,k in ipairs({"sessions","skullRewards","shop","upgrades"}) do b.economyMemory[k] = b.economyMemory[k] or {} end
    b.eventMemory = b.eventMemory or {}
    b.eventMemory.reactor = b.eventMemory.reactor or {sessions={},messages={},observations={}}
    b.eventMemory.reactor.sessions = b.eventMemory.reactor.sessions or {}
    b.eventMemory.reactor.messages = b.eventMemory.reactor.messages or {}
    b.eventMemory.reactor.observations = b.eventMemory.reactor.observations or {}
    b.eventMemory.military = b.eventMemory.military or {sessions={},observations={}}
    b.eventMemory.military.sessions = b.eventMemory.military.sessions or {}
    b.eventMemory.military.observations = b.eventMemory.military.observations or {}
    b.eventMemory.supplyDrops = b.eventMemory.supplyDrops or {sessions={}}
    b.eventMemory.supplyDrops.sessions = b.eventMemory.supplyDrops.sessions or {}
    b.eventMemory.hostileDebuffs = b.eventMemory.hostileDebuffs or {}
    b.combatMemory = b.combatMemory or {}
    b.combatMemory.sessions = b.combatMemory.sessions or {}
    b.combatMemory.jobLatest = b.combatMemory.jobLatest or {}
    b.combatMemory.weaponStats = b.combatMemory.weaponStats or {}
    b.combatMemory.confidenceTotals = b.combatMemory.confidenceTotals or {CONFIRMED=0,HIGH_CONFIDENCE=0,MEDIUM_CONFIDENCE=0,LOW_CONFIDENCE=0,UNMATCHED=0}
    b.networkMemory = b.networkMemory or {}
    b.networkMemory.quickNet = b.networkMemory.quickNet or {}
    b.networkMemory.replication = b.networkMemory.replication or {sessions={}}
    b.networkMemory.replication.sessions = b.networkMemory.replication.sessions or {}
    b.networkMemory.trustTelemetry = b.networkMemory.trustTelemetry or {sessions={}}
    b.networkMemory.trustTelemetry.sessions = b.networkMemory.trustTelemetry.sessions or {}
    b.networkMemory.technicalEvidence = b.networkMemory.technicalEvidence or {}
    b.live = b.live or {}
    b.live.capabilityMemory = b.live.capabilityMemory or {}
    b.live.experienceMemory = b.live.experienceMemory or {player={},ai={},shadow={},failures={},predictions={}}
    for _,k in ipairs({"player","ai","shadow","failures","predictions"}) do b.live.experienceMemory[k] = b.live.experienceMemory[k] or {} end
    b.live.skillRegistry = b.live.skillRegistry or {skills={},rollbacks={},adaptations={}}
    b.live.decisionMemory = b.live.decisionMemory or {decisions={},goalStats={}}
    b.live.policyMemory = b.live.policyMemory or {parameters={},version=1,history={}}
    b.live.runtimeKnowledge = b.live.runtimeKnowledge or {}
    b.live.worldSummary = b.live.worldSummary or {}
    b.diagnostics = b.diagnostics or {}
    b.diagnostics.loadHistory = b.diagnostics.loadHistory or {}
    b.diagnostics.saveHistory = b.diagnostics.saveHistory or {}
    b.diagnostics.warnings = b.diagnostics.warnings or {}
    b.migrationLedger = b.migrationLedger or {}
    b.migrationLedger.importedSources = b.migrationLedger.importedSources or {}
    b.migrationLedger.deferredSources = b.migrationLedger.deferredSources or {}
    b.migrationLedger.failedSources = b.migrationLedger.failedSources or {}
    b.migrationLedger.corrections = b.migrationLedger.corrections or {}
    return b
end

local Brain = normalizeBrain(newBrain())

local function recordHistoryMap(map, value)
    local key = tostring(value or "Unknown")
    map[key] = (map[key] or 0) + 1
end

local function touchBrainMeta()
    Brain = normalizeBrain(Brain)
    Brain.updatedUnix = os.time()
    Brain.meta.lastPlaceId = game.PlaceId
    Brain.meta.lastJobId = game.JobId
    if not R.historyRecorded then
        recordHistoryMap(Brain.meta.deviceHistory, DEVICE.platform .. (DEVICE.mobile and ":MOBILE" or ":DESKTOP"))
        recordHistoryMap(Brain.meta.executorHistory, EXECUTOR_FAMILY .. ":" .. EXECUTOR_NAME)
        R.historyRecorded = true
    end
end

local function loadBrainFromFile(path, checksumPath)
    if not fileExists(path) then return false, nil, "NOT_FOUND" end
    local ok, raw = readText(path)
    if not ok then return false, nil, raw end
    local checksumRaw = nil
    if checksumPath and fileExists(checksumPath) then
        local cok, ctext = readText(checksumPath)
        if cok then checksumRaw = ctext end
    end
    return validateBrainJson(raw, checksumRaw)
end

local function loadPersistentBrain()
    if type(ENV.STA_STAGE15_IMPORT_JSON) == "string" and #ENV.STA_STAGE15_IMPORT_JSON > 10 then
        local ok, decoded = decodeJson(ENV.STA_STAGE15_IMPORT_JSON)
        if ok and type(decoded) == "table" and decoded.schema == BRAIN_SCHEMA then
            Brain = normalizeBrain(decoded)
            logLine("READY", "Loaded brain from STA_STAGE15_IMPORT_JSON")
            return true, "MANUAL_IMPORT"
        else
            logLine("WARN", "Manual import rejected", tostring(decoded))
        end
    end

    if not AUTO_PERSISTENCE then
        logLine("WARN", "Automatic cross-session persistence unavailable", "readfile/writefile missing")
        return false, "NO_AUTO_FILE_IO"
    end

    local ok, loaded, err = loadBrainFromFile(FILES.Brain, FILES.BrainChecksum)
    if ok then
        Brain = normalizeBrain(loaded)
        Brain.diagnostics = Brain.diagnostics or {loadHistory={}, saveHistory={}, warnings={}}
        Brain.diagnostics.loadHistory = Brain.diagnostics.loadHistory or {}
        Brain.diagnostics.loadHistory[#Brain.diagnostics.loadHistory+1] = {unix=os.time(), source="PRIMARY", result="OK"}
        logLine("READY", "Persistent brain loaded", FILES.Brain)
        return true, "PRIMARY"
    end

    logLine("WARN", "Primary brain unavailable/invalid", tostring(err))
    local bok, backup, berr = loadBrainFromFile(FILES.Backup, FILES.BackupChecksum)
    if bok then
        Brain = normalizeBrain(backup)
        Brain.diagnostics = Brain.diagnostics or {loadHistory={}, saveHistory={}, warnings={}}
        Brain.diagnostics.loadHistory = Brain.diagnostics.loadHistory or {}
        Brain.diagnostics.loadHistory[#Brain.diagnostics.loadHistory+1] = {unix=os.time(), source="BACKUP", result="RECOVERED"}
        logLine("READY", "Recovered persistent brain from backup")
        return true, "BACKUP"
    end

    logLine("WARN", "Backup brain unavailable/invalid", tostring(berr), "Creating new brain")
    return false, "NEW_BRAIN"
end

local function savePersistentBrain(reason)
    reason = reason or "MANUAL"
    touchBrainMeta()

    local okEncode, raw = encodeSafe(Brain)
    if not okEncode then
        logLine("ERROR", "BRAIN_ENCODE_FAIL", raw)
        return false, raw
    end
    local checksum = checksumText(raw)

    if not API.writefile then
        ENV.STA_STAGE15_LAST_EXPORT = raw
        if API.setclipboard then pcall(API.setclipboard, raw) end
        logLine("WARN", "Brain exported in-memory only", reason)
        return false, "WRITEFILE_UNAVAILABLE"
    end

    -- Step 1: verified temp.
    local okTemp, tempErr = writeVerified(FILES.Temp, raw)
    if not okTemp then
        logLine("ERROR", "TEMP_SAVE_FAIL", tempErr)
        return false, tempErr
    end
    local okTempC, tempCErr = writeVerified(FILES.TempChecksum, checksum)
    if not okTempC then
        logLine("ERROR", "TEMP_CHECKSUM_SAVE_FAIL", tempCErr)
        return false, tempCErr
    end

    -- Step 2: backup current primary before replacement.
    if API.readfile and fileExists(FILES.Brain) then
        local oldOk, oldRaw = readText(FILES.Brain)
        if oldOk then
            local oldChecksum = nil
            if fileExists(FILES.BrainChecksum) then
                local cok, ctext = readText(FILES.BrainChecksum)
                if cok then oldChecksum = ctext end
            end
            local validOld = validateBrainJson(oldRaw, oldChecksum)
            if validOld then
                local b1 = writeVerified(FILES.Backup, oldRaw)
                local b2 = writeVerified(FILES.BackupChecksum, checksumText(oldRaw))
                if not b1 or not b2 then logLine("WARN", "BACKUP_WRITE_PARTIAL") end
            else
                logLine("WARN", "Existing primary invalid; not promoted to backup")
            end
        end
    end

    -- Step 3: replace primary and verify.
    local p1, p1err = writeVerified(FILES.Brain, raw)
    if not p1 then
        logLine("ERROR", "PRIMARY_WRITE_FAIL", p1err)
        return false, p1err
    end
    local p2, p2err = writeVerified(FILES.BrainChecksum, checksum)
    if not p2 then
        logLine("ERROR", "PRIMARY_CHECKSUM_WRITE_FAIL", p2err)
        return false, p2err
    end

    if API.readfile then
        local vok, verifiedBrain, verr = loadBrainFromFile(FILES.Brain, FILES.BrainChecksum)
        if not vok or type(verifiedBrain) ~= "table" then
            logLine("ERROR", "PRIMARY_POST_VERIFY_FAIL", tostring(verr))
            return false, verr
        end
    end

    deleteIfPossible(FILES.Temp)
    deleteIfPossible(FILES.TempChecksum)

    Brain.diagnostics = Brain.diagnostics or {}
    Brain.diagnostics.saveHistory = Brain.diagnostics.saveHistory or {}
    Brain.diagnostics.saveHistory[#Brain.diagnostics.saveHistory+1] = {
        unix=os.time(), reason=reason, bytes=#raw, checksum=checksum, result="OK"
    }
    while #Brain.diagnostics.saveHistory > 50 do table.remove(Brain.diagnostics.saveHistory, 1) end

    R.lastSaveAt = os.clock()
    logLine("READY", "Persistent brain saved", reason, "bytes=" .. tostring(#raw), checksum)
    flushLog()
    return true, checksum
end

-- ============================================================
-- JSON SELECTIVE SCANNER FOR LARGE LEGACY FILES
-- ============================================================

local function skipWs(s, i, limit)
    limit = limit or #s
    while i <= limit do
        local c = string.byte(s, i)
        if c == 32 or c == 9 or c == 10 or c == 13 then i = i + 1 else break end
    end
    return i
end

local function scanStringEnd(s, i, limit)
    limit = limit or #s
    if string.sub(s, i, i) ~= '"' then return nil end
    local j = i + 1
    while j <= limit do
        local c = string.sub(s, j, j)
        if c == "\\" then
            j = j + 2
        elseif c == '"' then
            return j
        else
            j = j + 1
        end
    end
    return nil
end

local function scanValueEnd(s, i, limit)
    limit = limit or #s
    i = skipWs(s, i, limit)
    local first = string.sub(s, i, i)
    if first == '"' then return scanStringEnd(s, i, limit) end
    if first == "{" or first == "[" then
        local depth = 0
        local inString = false
        local escaped = false
        for j=i,limit do
            local c = string.sub(s, j, j)
            if inString then
                if escaped then
                    escaped = false
                elseif c == "\\" then
                    escaped = true
                elseif c == '"' then
                    inString = false
                end
            else
                if c == '"' then
                    inString = true
                elseif c == "{" or c == "[" then
                    depth = depth + 1
                elseif c == "}" or c == "]" then
                    depth = depth - 1
                    if depth == 0 then return j end
                end
            end
        end
        return nil
    end
    local j = i
    while j <= limit do
        local c = string.sub(s, j, j)
        if c == "," or c == "}" or c == "]" or c == "\n" or c == "\r" then return j - 1 end
        j = j + 1
    end
    return limit
end

local function decodeJsonStringToken(token)
    local ok, value = decodeJson(token)
    if ok then return value end
    return string.sub(token, 2, -2)
end

local function iterateObjectEntries(raw, objStart, objEnd, callback)
    if not objStart or not objEnd or string.sub(raw, objStart, objStart) ~= "{" then return false end
    local i = objStart + 1
    while i < objEnd do
        i = skipWs(raw, i, objEnd)
        if string.sub(raw, i, i) == "," then i = skipWs(raw, i + 1, objEnd) end
        if i >= objEnd then break end
        if string.sub(raw, i, i) ~= '"' then return false end
        local keyEnd = scanStringEnd(raw, i, objEnd)
        if not keyEnd then return false end
        local key = decodeJsonStringToken(string.sub(raw, i, keyEnd))
        local colon = skipWs(raw, keyEnd + 1, objEnd)
        if string.sub(raw, colon, colon) ~= ":" then return false end
        local valueStart = skipWs(raw, colon + 1, objEnd)
        local valueEnd = scanValueEnd(raw, valueStart, objEnd)
        if not valueEnd then return false end
        local stop = callback(key, valueStart, valueEnd)
        if stop == true then return true end
        i = valueEnd + 1
    end
    return true
end

local function topLevelBounds(raw, wantedKey)
    if type(raw) ~= "string" then return nil end
    local start = skipWs(raw, 1, #raw)
    if string.sub(raw, start, start) ~= "{" then return nil end
    local finish = scanValueEnd(raw, start, #raw)
    local outS, outE = nil, nil
    iterateObjectEntries(raw, start, finish or #raw, function(key, vs, ve)
        if key == wantedKey then outS, outE = vs, ve return true end
    end)
    return outS, outE
end

local function nestedFieldBounds(raw, objStart, objEnd, wantedKey)
    local outS, outE = nil, nil
    if not objStart or not objEnd then return nil end
    iterateObjectEntries(raw, objStart, objEnd, function(key, vs, ve)
        if key == wantedKey then outS, outE = vs, ve return true end
    end)
    return outS, outE
end

local function decodeBounds(raw, s, e, sizeLimit)
    if not s or not e then return nil, "MISSING" end
    local size = e - s + 1
    if sizeLimit and size > sizeLimit then return nil, "TOO_LARGE:" .. tostring(size) end
    local ok, value = decodeJson(string.sub(raw, s, e))
    if ok then return value end
    return nil, tostring(value)
end

local function decodeTopField(raw, key, sizeLimit)
    local s,e = topLevelBounds(raw, key)
    return decodeBounds(raw, s, e, sizeLimit)
end

local function decodeObjectField(raw, objStart, objEnd, key, sizeLimit)
    local s,e = nestedFieldBounds(raw, objStart, objEnd, key)
    return decodeBounds(raw, s, e, sizeLimit)
end

local function iterateCollection(raw, startPos, endPos, callback)
    if not startPos or not endPos then return false end
    local first = string.sub(raw, startPos, startPos)
    if first == "{" then
        return iterateObjectEntries(raw, startPos, endPos, function(key, vs, ve)
            return callback(key, vs, ve)
        end)
    elseif first == "[" then
        local i = startPos + 1
        local index = 0
        while i < endPos do
            i = skipWs(raw, i, endPos)
            if string.sub(raw, i, i) == "," then i = skipWs(raw, i + 1, endPos) end
            if i >= endPos then break end
            local ve = scanValueEnd(raw, i, endPos)
            if not ve then return false end
            index = index + 1
            local stop = callback(index, i, ve)
            if stop == true then return true end
            i = ve + 1
        end
        return true
    end
    return false
end

-- ============================================================
-- GENERIC MERGE / COMPACTION HELPERS
-- ============================================================

local function deepCopy(v, seen, depth)
    return jsonSafe(v, seen or {}, depth or 0)
end

local function mergeMissing(target, source, depth)
    if type(target) ~= "table" or type(source) ~= "table" then return end
    depth = depth or 0
    if depth > 30 then return end
    for k,v in pairs(source) do
        if target[k] == nil then
            target[k] = deepCopy(v)
        elseif type(target[k]) == "table" and type(v) == "table" then
            mergeMissing(target[k], v, depth + 1)
        end
    end
end

local function restoreTable(target, persisted, depth, skipKeys)
    if type(target) ~= "table" or type(persisted) ~= "table" then return end
    depth = depth or 0
    if depth > 30 then return end
    skipKeys = skipKeys or {}
    for k,v in pairs(persisted) do
        if not skipKeys[k] then
            if type(v) == "table" then
                if type(target[k]) ~= "table" then target[k] = {} end
                restoreTable(target[k], v, depth + 1, skipKeys)
            else
                target[k] = v
            end
        end
    end
end

local function countTable(t)
    local n = 0
    if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
    return n
end

local function appendLimited(list, value, limit)
    if type(list) ~= "table" then return end
    list[#list+1] = value
    while #list > limit do table.remove(list, 1) end
end

local function safeBasename(path)
    path = tostring(path or "")
    path = string.gsub(path, "\\", "/")
    return string.match(path, "([^/]+)$") or path
end

local function normalizeLower(s)
    return string.lower(tostring(s or ""))
end

local function sourceFingerprint(path, raw)
    return string.format("%s|%d|%u", safeBasename(path), #raw, adler32(raw))
end

local function sourceAlreadyImported(fp)
    return type(Brain.migrationLedger.importedSources) == "table" and Brain.migrationLedger.importedSources[fp] ~= nil
end

local function markImported(fp, path, kind, extra)
    Brain.migrationLedger.importedSources[fp] = {
        path = tostring(path),
        basename = safeBasename(path),
        kind = kind,
        importedUnix = os.time(),
        extra = extra,
    }
end

local function addCorrection(code, source, detail)
    Brain.migrationLedger.corrections[#Brain.migrationLedger.corrections+1] = {
        unix=os.time(), code=code, source=source, detail=detail
    }
    Brain.evidenceStore.corrections[code] = {
        source=source, detail=detail, updatedUnix=os.time()
    }
    R.migrationStats.corrected = R.migrationStats.corrected + 1
end

local function confidenceBucket(score, targetMatched)
    score = tonumber(score) or 0
    if targetMatched == true and score >= 160 then return "CONFIRMED" end
    if score >= 160 then return "HIGH_CONFIDENCE" end
    if score >= 120 then return "MEDIUM_CONFIDENCE" end
    if score >= 80 then return "LOW_CONFIDENCE" end
    return "UNMATCHED"
end

local function compactMapEntries(map, maxEntries)
    if type(map) ~= "table" then return {} end
    local keys = {}
    for k,_ in pairs(map) do keys[#keys+1] = k end
    table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)
    local out = {}
    local start = math.max(1, #keys - maxEntries + 1)
    for i=start,#keys do out[keys[i]] = deepCopy(map[keys[i]]) end
    return out
end

local function compactList(list, maxEntries)
    if type(list) ~= "table" then return {} end
    local out = {}
    local n = #list
    local start = math.max(1, n - maxEntries + 1)
    for i=start,n do out[#out+1] = deepCopy(list[i]) end
    return out
end

-- ============================================================
-- LEGACY MIGRATION: AI OBSERVER v1.x / TRUE AI v1.4
-- ============================================================

local function summarizeEpisodes(raw, sourceKey)
    local s,e = topLevelBounds(raw, "completedEpisodes")
    if not s or not e then return {count=0, byType={}} end
    local summary = {count=0, byType={}, samples={}}
    iterateCollection(raw, s, e, function(_, es, ee)
        summary.count = summary.count + 1
        local etype = decodeObjectField(raw, es, ee, "type", 1024) or "UNKNOWN"
        local success = decodeObjectField(raw, es, ee, "success", 128)
        local duration = tonumber(decodeObjectField(raw, es, ee, "duration", 128)) or 0
        local endReason = decodeObjectField(raw, es, ee, "endReason", 1024)
        local metrics = decodeObjectField(raw, es, ee, "metrics", 256 * 1024)
        etype = tostring(etype)
        local rec = summary.byType[etype]
        if not rec then
            rec = {count=0, success=0, failure=0, unknown=0, totalDuration=0, metricTotals={}}
            summary.byType[etype] = rec
        end
        rec.count = rec.count + 1
        rec.totalDuration = rec.totalDuration + duration
        if success == true then rec.success = rec.success + 1
        elseif success == false then rec.failure = rec.failure + 1
        else rec.unknown = rec.unknown + 1 end
        if type(metrics) == "table" then
            for mk,mv in pairs(metrics) do
                if type(mv) == "number" and finiteNumber(mv) then
                    rec.metricTotals[mk] = (rec.metricTotals[mk] or 0) + mv
                end
            end
        end
        summary.samples[etype] = summary.samples[etype] or {}
        if #summary.samples[etype] < CONFIG.LegacyEpisodeSamplesPerType then
            summary.samples[etype][#summary.samples[etype]+1] = {
                success=success, duration=duration, endReason=endReason, metrics=metrics
            }
        end
    end)
    Brain.playerExperience.legacyEpisodeSummary[sourceKey] = summary
    return summary
end

local function migrateSkullKnowledge(raw, sourceKey)
    local s,e = topLevelBounds(raw, "skullRewardKnowledge")
    if not s or not e then return nil end
    local totals = decodeObjectField(raw, s, e, "totals", 1024 * 1024)
    local observedAmounts = decodeObjectField(raw, s, e, "observedAmounts", 1024 * 1024)
    local byVariant = decodeObjectField(raw, s, e, "byVariant", 4 * 1024 * 1024)
    local result = {totals=totals or {}, observedAmounts=observedAmounts or {}, byVariant=byVariant or {}}
    Brain.economyMemory.skullRewards[sourceKey] = result
    return result
end

local function migrateRouteKnowledge(raw, sourceKey)
    local s,e = topLevelBounds(raw, "routeKnowledge")
    if not s or not e then return end
    local samples = {}
    local total = 0
    iterateCollection(raw, s, e, function(_, rs, re)
        total = total + 1
        if #samples < CONFIG.MaxLegacyRouteSamples then
            local value = decodeBounds(raw, rs, re, 128 * 1024)
            if type(value) == "table" then samples[#samples+1] = value end
        end
    end)
    Brain.playerExperience.routeSamples[sourceKey] = {total=total, samples=samples}
end

local function sanitizeLegacyLearning(learning, sourceName)
    if type(learning) ~= "table" then return {} end
    local out = {}
    for k,v in pairs(learning) do
        local lk = normalizeLower(k)
        if string.find(lk, "combat|merchant", 1, true) then
            addCorrection("LEGACY_MERCHANT_COMBAT_REJECTED", sourceName, tostring(k))
        else
            out[k] = v
        end
    end
    return out
end

local function migrateLegacyAI(path, raw, fp)
    local sourceName = safeBasename(path)
    local limit = maxSmallSectionBytes()
    local version = decodeTopField(raw, "version", 4096)
    local schema = decodeTopField(raw, "schema", 4096)
    local duration = decodeTopField(raw, "sessionDuration", 1024)
    local economy = decodeTopField(raw, "economy", limit)
    local upgrade = decodeTopField(raw, "weaponUpgradeKnowledge", limit)
    local shop = decodeTopField(raw, "shopKnowledge", limit)
    local food = decodeTopField(raw, "foodKnowledge", limit)
    local medical = decodeTopField(raw, "medicalKnowledge", limit)
    local lastState = decodeTopField(raw, "lastState", limit)
    local legacyLearning = decodeTopField(raw, "memory", limit)
    if legacyLearning == nil then legacyLearning = decodeTopField(raw, "learning", limit) end

    local sourceKey = fp
    local episodeSummary = summarizeEpisodes(raw, sourceKey)
    migrateSkullKnowledge(raw, sourceKey)
    migrateRouteKnowledge(raw, sourceKey)

    Brain.economyMemory.sessions[sourceKey] = {
        source=sourceName, version=version, schema=schema, sessionDuration=duration,
        economy=economy or {}, lastState=lastState
    }
    if type(upgrade) == "table" then Brain.economyMemory.upgrades[sourceKey] = upgrade end
    if type(shop) == "table" then Brain.economyMemory.shop[sourceKey] = shop end

    if type(food) == "table" then
        local signatures = food.signatures
        if type(signatures) == "table" and signatures.SpitterSlow ~= nil then
            Brain.eventMemory.hostileDebuffs.SpitterSlow = {
                source=sourceName,
                evidence=deepCopy(signatures.SpitterSlow),
                classification="HOSTILE_DEBUFF_EVIDENCE",
            }
            signatures.SpitterSlow = nil
            addCorrection("SPITTERSLOW_RECLASSIFIED_FROM_FOOD", sourceName, "Legacy positive-food interpretation rejected")
        end
    end

    Brain.playerExperience.legacyEpisodeSummary[sourceKey].foodKnowledge = food or {}
    Brain.playerExperience.legacyEpisodeSummary[sourceKey].medicalKnowledge = medical or {}
    Brain.playerExperience.legacyEpisodeSummary[sourceKey].legacyLearning = sanitizeLegacyLearning(legacyLearning, sourceName)

    -- Spawn semantics correction applies to pre-v1.3.2 data.
    local lv = normalizeLower(version or schema)
    if string.find(lv, "v1.0", 1, true) or string.find(lv, "v1.2", 1, true) or string.find(lv, "v1.3.1", 1, true) then
        addCorrection("LEGACY_SPAWN_PHASE_DOWNGRADED", sourceName, "Spawn/SpawnedPhase retained only as legacy observation context")
    end

    -- If this is a previous True AI v1.4 memory, selectively restore persistent AI state.
    if string.find(normalizeLower(sourceName), "sta_true_ai_memory_v140", 1, true)
        or string.find(normalizeLower(schema), "true ai foundation v1.4", 1, true)
    then
        local capability = decodeTopField(raw, "capabilityMemory", limit)
        local experience = decodeTopField(raw, "experienceMemory", limit)
        local skills = decodeTopField(raw, "skillRegistry", limit)
        local decisions = decodeTopField(raw, "decisionMemory", limit)
        local policy = decodeTopField(raw, "policyMemory", limit)
        if type(capability) == "table" then mergeMissing(Brain.live.capabilityMemory, capability) end
        if type(experience) == "table" then mergeMissing(Brain.live.experienceMemory, experience) end
        if type(skills) == "table" then mergeMissing(Brain.live.skillRegistry, skills) end
        if type(decisions) == "table" then mergeMissing(Brain.live.decisionMemory, decisions) end
        if type(policy) == "table" then restoreTable(Brain.live.policyMemory, policy) end
    end

    return true, string.format("AI legacy imported version=%s episodes=%d", tostring(version or schema), episodeSummary.count or 0)
end

-- ============================================================
-- LEGACY MIGRATION: STAGE 1 SEMANTIC WORLD MEMORY
-- ============================================================

local function clusterPersistentKey(category, center)
    local x,y,z = 0,0,0
    if type(center) == "table" then
        x = tonumber(center.x or center.X or center[1]) or 0
        y = tonumber(center.y or center.Y or center[2]) or 0
        z = tonumber(center.z or center.Z or center[3]) or 0
    end
    local grid = 25
    return string.format("%s|%d|%d|%d", tostring(category or "UNKNOWN"), math.floor(x/grid+0.5), math.floor(y/grid+0.5), math.floor(z/grid+0.5))
end

local function migrateStage1World(path, raw, fp)
    local sourceName = safeBasename(path)
    local limit = maxSmallSectionBytes()
    local schema = decodeTopField(raw, "schema", 4096)
    local version = decodeTopField(raw, "version", 4096)
    local sessionUnixLegacy = decodeTopField(raw, "sessionUnix", 1024)
    local duration = decodeTopField(raw, "sessionDuration", 1024)
    local fullSnapshot = decodeTopField(raw, "fullMemorySnapshot", 128)
    local statistics = decodeTopField(raw, "statistics", limit)
    local currentContext = decodeTopField(raw, "currentContext", 512 * 1024)
    local memoryGuard = decodeTopField(raw, "memoryGuard", 512 * 1024)
    local baseRegion = decodeTopField(raw, "baseRegionModel", 2 * 1024 * 1024)
    local semanticRules = decodeTopField(raw, "semanticRules", 512 * 1024)
    local executorProfile = decodeTopField(raw, "executorProfile", 512 * 1024)

    if type(semanticRules) == "table" then
        for k,v in pairs(semanticRules) do Brain.worldMemory.semanticRules[k] = v end
    end

    local profileKey = "LEGACY_STAGE1:" .. fp
    Brain.worldMemory.sessionSummaries[profileKey] = {
        source=sourceName,
        schema=schema,
        version=version,
        sessionUnix=sessionUnixLegacy,
        sessionDuration=duration,
        fullMemorySnapshot=fullSnapshot,
        statistics=statistics or {},
        currentContext=currentContext or {},
        memoryGuard=memoryGuard or {},
        executorProfile=executorProfile or {},
        placeId=game.PlaceId,
        jobId=nil,
        identityRule="LEGACY_RUNTIME_IDS_NOT_PERSISTED",
    }

    if type(baseRegion) == "table" then
        local compactBase = deepCopy(baseRegion)
        -- Runtime anchor ids are session-local and must not survive as identity.
        compactBase.anchorIds = nil
        compactBase.recentSamples = compactList(compactBase.recentSamples or {}, 40)
        Brain.worldMemory.baseProfiles[profileKey] = {
            source=sourceName,
            placeId=game.PlaceId,
            jobId=nil,
            sessionUnix=sessionUnixLegacy,
            model=compactBase,
            confidenceMeaning="SESSION_OBSERVATION_NOT_GLOBAL_BASE_COORDINATE",
        }
    end

    local cs,ce = topLevelBounds(raw, "resourceClusters")
    local candidates = {}
    local totalClusters = 0
    if cs and ce then
        iterateCollection(raw, cs, ce, function(clusterKey, vs, ve)
            totalClusters = totalClusters + 1
            local category = decodeObjectField(raw, vs, ve, "category", 2048)
            local observations = tonumber(decodeObjectField(raw, vs, ve, "observations", 128)) or 0
            local maxCount = tonumber(decodeObjectField(raw, vs, ve, "maxCount", 128)) or 0
            local lastCount = tonumber(decodeObjectField(raw, vs, ve, "lastCount", 128)) or 0
            local center = decodeObjectField(raw, vs, ve, "center", 16 * 1024)
            local radius = tonumber(decodeObjectField(raw, vs, ve, "radius", 128)) or 0
            local role = decodeObjectField(raw, vs, ve, "semanticRoleCandidate", 4096)
            local roleConfidence = tonumber(decodeObjectField(raw, vs, ve, "semanticRoleConfidence", 128)) or 0
            local inside = tonumber(decodeObjectField(raw, vs, ve, "observedInsideLearnedBaseRegion", 128)) or 0
            local outside = tonumber(decodeObjectField(raw, vs, ve, "observedOutsideLearnedBaseRegion", 128)) or 0
            if category or center then
                candidates[#candidates+1] = {
                    sourceClusterKey=tostring(clusterKey), category=category or "UNKNOWN",
                    observations=observations, maxCount=maxCount, lastCount=lastCount,
                    center=center, radius=radius, semanticRoleCandidate=role,
                    semanticRoleConfidence=roleConfidence, insideObservations=inside, outsideObservations=outside,
                }
            end
        end)
    end

    table.sort(candidates, function(a,b)
        if (a.observations or 0) == (b.observations or 0) then return tostring(a.category) < tostring(b.category) end
        return (a.observations or 0) > (b.observations or 0)
    end)
    local keep = maxClusterKeep()
    local compact = {}
    for i=1,math.min(keep, #candidates) do
        local c = candidates[i]
        local pk = clusterPersistentKey(c.category, c.center)
        compact[pk] = c
    end
    Brain.worldMemory.resourceProfiles[profileKey] = {
        source=sourceName,
        totalClustersObserved=totalClusters,
        retainedTopClusters=countTable(compact),
        clusters=compact,
        identityRule="CATEGORY_PLUS_SESSION_SPATIAL_CLUSTER_NOT_RUNTIME_ID",
    }

    return true, string.format("Stage1 imported version=%s clusters=%d retained=%d", tostring(version or schema), totalClusters, countTable(compact))
end

-- ============================================================
-- LEGACY MIGRATION: COMBAT OUTCOME CORRELATOR
-- ============================================================

local function mergeWeaponAggregate(weapon, stats)
    if type(stats) ~= "table" then return end
    local agg = Brain.combatMemory.weaponStats[weapon]
    if not agg then
        agg = {
            weapon=weapon, sessions=0, samples=0, correlatedHits=0, kills=0,
            totalDamage=0, protocolCalls=0, shootCalls=0, projectileHitCalls=0, hitTargetsCalls=0,
            minDamage=nil, maxDamage=nil,
        }
        Brain.combatMemory.weaponStats[weapon] = agg
    end
    agg.sessions = agg.sessions + 1
    local numericKeys = {"samples","correlatedHits","kills","totalDamage","protocolCalls","shootCalls","projectileHitCalls","hitTargetsCalls"}
    for _,k in ipairs(numericKeys) do agg[k] = (agg[k] or 0) + (tonumber(stats[k]) or 0) end
    local minD = tonumber(stats.minDamage)
    local maxD = tonumber(stats.maxDamage)
    if minD then agg.minDamage = agg.minDamage and math.min(agg.minDamage, minD) or minD end
    if maxD then agg.maxDamage = agg.maxDamage and math.max(agg.maxDamage, maxD) or maxD end
    agg.averageDamage = (agg.samples or 0) > 0 and ((agg.totalDamage or 0) / agg.samples) or 0
end

local function rebuildCombatAggregates()
    Brain.combatMemory.weaponStats = {}
    Brain.combatMemory.confidenceTotals = {CONFIRMED=0,HIGH_CONFIDENCE=0,MEDIUM_CONFIDENCE=0,LOW_CONFIDENCE=0,UNMATCHED=0}
    for _,session in pairs(Brain.combatMemory.sessions or {}) do
        if type(session.weaponStats) == "table" then
            for weapon,wstats in pairs(session.weaponStats) do mergeWeaponAggregate(tostring(weapon), wstats) end
        end
        if type(session.confidenceTotals) == "table" then
            for bucket,count in pairs(session.confidenceTotals) do
                Brain.combatMemory.confidenceTotals[bucket] = (Brain.combatMemory.confidenceTotals[bucket] or 0) + (tonumber(count) or 0)
            end
        end
    end
end

local function migrateCombatOutcome(path, raw, fp)
    local sourceName = safeBasename(path)
    local schema = decodeTopField(raw, "schema", 4096)
    local placeId = decodeTopField(raw, "placeId", 1024)
    local jobId = decodeTopField(raw, "jobId", 4096)
    local seconds = decodeTopField(raw, "seconds", 1024)
    local stats = decodeTopField(raw, "stats", 1024 * 1024)
    local boundaries = decodeTopField(raw, "boundaries", 512 * 1024)
    local weaponStats = decodeTopField(raw, "weaponStats", maxSmallSectionBytes())

    local session = {
        source=sourceName, schema=schema, placeId=placeId, jobId=jobId, seconds=seconds,
        stats=stats or {}, boundaries=boundaries or {},
        confidenceTotals={CONFIRMED=0,HIGH_CONFIDENCE=0,MEDIUM_CONFIDENCE=0,LOW_CONFIDENCE=0,UNMATCHED=0},
        correlationSamples={},
    }

    if type(weaponStats) == "table" then
        session.weaponStats = weaponStats
    end

    local cs,ce = topLevelBounds(raw, "correlations")
    local correlations = 0
    if cs and ce then
        iterateCollection(raw, cs, ce, function(_, vs, ve)
            correlations = correlations + 1
            local score = tonumber(decodeObjectField(raw, vs, ve, "score", 128)) or 0
            local targetMatched = decodeObjectField(raw, vs, ve, "targetMatched", 128)
            local bucket = confidenceBucket(score, targetMatched)
            session.confidenceTotals[bucket] = (session.confidenceTotals[bucket] or 0) + 1
            if #session.correlationSamples < CONFIG.MaxCombatCorrelationSamplesPerSession then
                local weapon = decodeObjectField(raw, vs, ve, "weapon", 4096)
                local callKind = decodeObjectField(raw, vs, ve, "callKind", 4096)
                local damage = decodeObjectField(raw, vs, ve, "damage", 128)
                local target = decodeObjectField(raw, vs, ve, "target", 16 * 1024)
                session.correlationSamples[#session.correlationSamples+1] = {
                    score=score, targetMatched=targetMatched, confidence=bucket,
                    weapon=weapon, callKind=callKind, damage=damage, target=target,
                }
            end
        end)
    end
    session.correlationCount = correlations

    -- Passive-evidence boundary check is stored, not assumed.
    if type(boundaries) == "table" then
        local generated = tonumber(boundaries.generatedServerCalls) or 0
        local stateMutation = tonumber(boundaries.stateMutation) or 0
        local movementModification = tonumber(boundaries.movementModification) or 0
        local authBypass = tonumber(boundaries.authBypass) or 0
        session.passiveEvidence = generated == 0 and stateMutation == 0 and movementModification == 0 and authBypass == 0
    end

    local jid = tostring(jobId or "")
    if jid ~= "" then
        local oldFp = Brain.combatMemory.jobLatest[jid]
        if oldFp and oldFp ~= fp then
            Brain.combatMemory.sessions[oldFp] = nil
        end
        Brain.combatMemory.jobLatest[jid] = fp
    end
    Brain.combatMemory.sessions[fp] = session
    rebuildCombatAggregates()
    return true, string.format("Combat Outcome imported correlations=%d weapons=%d", correlations, type(weaponStats)=="table" and countTable(weaponStats) or 0)
end

-- ============================================================
-- LEGACY MIGRATION: REACTOR / EVENT TRACKER
-- ============================================================

local function migrateEventTracker(path, raw, fp)
    local sourceName = safeBasename(path)
    local version = decodeTopField(raw, "version", 4096)
    local duration = decodeTopField(raw, "sessionDuration", 1024)
    local finalState = decodeTopField(raw, "finalState", 1024 * 1024)
    local summary = {
        source=sourceName, version=version, sessionDuration=duration, finalState=finalState or {},
        eventCounts={}, messages={}, bossEvidence={},
    }

    local es,ee = topLevelBounds(raw, "events")
    local total = 0
    if es and ee then
        iterateCollection(raw, es, ee, function(_, vs, ve)
            total = total + 1
            local eventType = tostring(decodeObjectField(raw, vs, ve, "eventType", 4096) or "UNKNOWN")
            summary.eventCounts[eventType] = (summary.eventCounts[eventType] or 0) + 1
            if eventType == "REACTOR_REMOTE_IN" or eventType == "REACTOR_GUI_TEXT_FOUND" then
                local data = decodeObjectField(raw, vs, ve, "data", 128 * 1024)
                if type(data) == "table" then
                    local text = data.text or data.args
                    if text then
                        local st = tostring(text)
                        if string.find(normalizeLower(st), "nuclear reactor", 1, true) then
                            summary.messages[st] = (summary.messages[st] or 0) + 1
                            Brain.eventMemory.reactor.messages[st] = (Brain.eventMemory.reactor.messages[st] or 0) + 1
                        end
                    end
                end
            end
        end)
    end
    summary.totalEvents = total
    Brain.eventMemory.reactor.sessions[fp] = summary
    return true, string.format("Event tracker imported events=%d", total)
end

-- ============================================================
-- LEGACY MIGRATION: TRUST / REPLICATION TECHNICAL EVIDENCE
-- ============================================================

local function migrateTrustReplication(path, raw, fp)
    local sourceName = safeBasename(path)
    local schema = decodeTopField(raw, "schema", 4096)
    local version = decodeTopField(raw, "version", 4096)
    local placeId = decodeTopField(raw, "placeId", 1024)
    local jobId = decodeTopField(raw, "jobId", 4096)
    local sessionSeconds = decodeTopField(raw, "sessionSeconds", 1024)
    local stats = decodeTopField(raw, "stats", 512 * 1024)
    local quickNet = decodeTopField(raw, "quickNet", 512 * 1024)

    local trustSummary = {
        source=sourceName, schema=schema, version=version, placeId=placeId, jobId=jobId,
        sessionSeconds=sessionSeconds, stats=stats or {}, transitions={}, limitChanges={},
        meaningRule="OBSERVED_CLIENT_TELEMETRY_ONLY_SERVER_FORMULA_UNKNOWN",
    }

    local ts,te = topLevelBounds(raw, "trustTimeline")
    if ts and te then
        iterateCollection(raw, ts, te, function(_, vs, ve)
            local kind = tostring(decodeObjectField(raw, vs, ve, "kind", 1024) or "UNKNOWN")
            local attribute = tostring(decodeObjectField(raw, vs, ve, "attribute", 4096) or "UNKNOWN")
            local value = decodeObjectField(raw, vs, ve, "value", 128)
            local t = decodeObjectField(raw, vs, ve, "t", 128)
            if kind == "LIMIT_CHANGE" then
                trustSummary.limitChanges[attribute] = trustSummary.limitChanges[attribute] or {count=0, samples={}}
                local rec = trustSummary.limitChanges[attribute]
                rec.count = rec.count + 1
                if #rec.samples < 20 then rec.samples[#rec.samples+1] = {t=t, value=value} end
            end
        end)
    end

    local es,ee = topLevelBounds(raw, "trustEvents")
    if es and ee then
        iterateCollection(raw, es, ee, function(_, vs, ve)
            local attribute = tostring(decodeObjectField(raw, vs, ve, "attribute", 4096) or "UNKNOWN")
            local oldValue = decodeObjectField(raw, vs, ve, "oldValue", 128)
            local newValue = decodeObjectField(raw, vs, ve, "newValue", 128)
            local t = decodeObjectField(raw, vs, ve, "t", 128)
            local character = decodeObjectField(raw, vs, ve, "character", 512 * 1024)
            trustSummary.transitions[#trustSummary.transitions+1] = {
                attribute=attribute, oldValue=oldValue, newValue=newValue, t=t,
                context=type(character)=="table" and {
                    humanoidState=character.humanoidState,
                    floorMaterial=character.floorMaterial,
                    assemblyLinearVelocity=character.assemblyLinearVelocity,
                    position=character.position,
                } or nil,
            }
        end)
    end

    Brain.networkMemory.trustTelemetry.sessions[fp] = trustSummary
    if type(quickNet) == "table" then
        Brain.networkMemory.quickNet[sourceName] = {
            source=sourceName, placeId=placeId, jobId=jobId, observed=deepCopy(quickNet),
            interpretation="CLIENT_REPLICATION_REGISTRY_EVIDENCE",
        }
    end

    local rs,re = topLevelBounds(raw, "replicationSamples")
    local repSummary = {source=sourceName, placeId=placeId, jobId=jobId, samples=0, entities={}, throttled=0, unthrottled=0, maxTargetActualError=0}
    if rs and re then
        iterateCollection(raw, rs, re, function(_, ss, se)
            repSummary.samples = repSummary.samples + 1
            local recordsS, recordsE = nestedFieldBounds(raw, ss, se, "records")
            if recordsS and recordsE then
                iterateCollection(raw, recordsS, recordsE, function(_, rvs, rve)
                    local model = tostring(decodeObjectField(raw, rvs, rve, "model", 16 * 1024) or "UNKNOWN")
                    local entity = string.match(model, "([^%.]+)$") or model
                    local throttled = decodeObjectField(raw, rvs, rve, "throttled", 128)
                    local err = tonumber(decodeObjectField(raw, rvs, rve, "actualToTargetDistance", 128)) or 0
                    local er = repSummary.entities[entity] or {samples=0, throttled=0, unthrottled=0, maxError=0, errorSum=0}
                    repSummary.entities[entity] = er
                    er.samples = er.samples + 1
                    er.errorSum = er.errorSum + err
                    er.maxError = math.max(er.maxError or 0, err)
                    if throttled == true then er.throttled=er.throttled+1 repSummary.throttled=repSummary.throttled+1
                    else er.unthrottled=er.unthrottled+1 repSummary.unthrottled=repSummary.unthrottled+1 end
                    repSummary.maxTargetActualError = math.max(repSummary.maxTargetActualError or 0, err)
                end)
            end
        end)
    end
    for _,er in pairs(repSummary.entities) do er.meanError = er.samples > 0 and er.errorSum / er.samples or 0 end
    Brain.networkMemory.replication.sessions[fp] = repSummary
    return true, string.format("Trust/Replication imported trustEvents=%d replicationSamples=%d", #trustSummary.transitions, repSummary.samples)
end

local function migrateEventInfoText(path, raw, fp)
    local sourceName = safeBasename(path)
    local lower = string.lower(raw)
    local rec = {
        source=sourceName,
        text=raw,
        observedMilitarySignature=string.find(lower, "militarybase = true", 1, true) ~= nil,
        observedReactorSignature=string.find(lower, "reactor = true", 1, true) ~= nil,
        containsBossZombie=string.find(lower, "bosszombie", 1, true) ~= nil,
        containsExperiment=string.find(lower, "experiment", 1, true) ~= nil,
        evidenceClass="HUMAN_CURATED_OBSERVED_SUMMARY",
    }
    Brain.eventMemory.military.observations[fp] = rec
    Brain.eventMemory.reactor.observations[fp] = rec
    return true, "Military/Reactor observed-summary text imported"
end

-- ============================================================
-- LEGACY SOURCE DISCOVERY / MIGRATION CONTROL
-- ============================================================

local function classifyLegacyPath(path)
    local name = normalizeLower(safeBasename(path))
    if string.find(name, "sta_military_base_and_nuclear_reactor_current_info", 1, true) and string.find(name, ".txt", 1, true) then return "EVENT_INFO_TEXT" end
    if not string.find(name, ".json", 1, true) then return nil end
    if string.find(name, "sta_stage15_persistent_brain", 1, true) then return nil end
    if string.find(name, "zhub_replication_trust", 1, true) and string.find(name, "_data", 1, true) then return "TRUST_REPLICATION" end
    if string.find(name, "sta_ai_memory", 1, true) then return "AI_LEGACY" end
    if string.find(name, "sta_true_ai_memory_v140", 1, true) then return "AI_LEGACY" end
    if string.find(name, "sta_stage1_world_memory", 1, true) then return "STAGE1_WORLD" end
    if string.find(name, "sta_nuclear_reactor", 1, true) then return "EVENT_TRACKER" end
    if string.find(name, "zhub_combat_outcome", 1, true) and string.find(name, "_auto_data.json", 1, true) then return "COMBAT_OUTCOME" end
    if string.find(name, "zhub_combat_outcome", 1, true) and string.find(name, "_data.json", 1, true) then return "COMBAT_OUTCOME" end
    return nil
end

local function shouldSkipKnownHugeOnMobile(path, kind)
    if not DEVICE.mobile or not CONFIG.SkipKnownHugeLegacyOnMobile or CONFIG.ForceLargeLegacyMigrationOnMobile then return false end
    local name = normalizeLower(safeBasename(path))
    if kind == "STAGE1_WORLD" then return true end
    if kind == "AI_LEGACY" and string.find(name, "v131", 1, true) then return true end
    return false
end

local function discoverLegacyFiles()
    local paths = {}
    local seen = {}
    local function add(path)
        if type(path) ~= "string" or path == "" or seen[path] then return end
        seen[path] = true
        if classifyLegacyPath(path) then paths[#paths+1] = path end
    end

    if type(ENV.STA_STAGE15_LEGACY_FILES) == "table" then
        for _,p in ipairs(ENV.STA_STAGE15_LEGACY_FILES) do add(p) end
    end

    if API.listfiles then
        local roots = {"", ".", "workspace"}
        for _,root in ipairs(roots) do
            local ok, list = pcall(API.listfiles, root)
            if ok and type(list) == "table" then
                for _,p in ipairs(list) do add(p) end
                if #list > 0 then break end
            end
        end
    end

    table.sort(paths, function(a,b) return tostring(a) > tostring(b) end)
    return paths
end

local function migrateOne(path, combatJobsSeen)
    local kind = classifyLegacyPath(path)
    if not kind then return false, "UNSUPPORTED" end
    R.migrationStats.discovered = R.migrationStats.discovered + 1

    if shouldSkipKnownHugeOnMobile(path, kind) then
        R.migrationStats.deferred = R.migrationStats.deferred + 1
        Brain.migrationLedger.deferredSources[path] = {
            unix=os.time(), kind=kind, reason="MOBILE_LARGE_FILE_DEFERRED",
            action="Migrate once on desktop or set ForceLargeLegacyMigrationOnMobile=true"
        }
        migrationLine("DEFERRED", safeBasename(path), "Large legacy source intentionally deferred on mobile")
        return false, "DEFERRED"
    end

    if API.getfilesize then
        local okSize, size = pcall(API.getfilesize, path)
        if okSize and DEVICE.mobile and tonumber(size) and tonumber(size) > 20 * 1024 * 1024 and not CONFIG.ForceLargeLegacyMigrationOnMobile then
            R.migrationStats.deferred = R.migrationStats.deferred + 1
            Brain.migrationLedger.deferredSources[path] = {unix=os.time(), kind=kind, reason="MOBILE_SIZE_LIMIT", bytes=size}
            migrationLine("DEFERRED", safeBasename(path), "bytes=" .. tostring(size))
            return false, "DEFERRED"
        end
    end

    local okRead, raw = readText(path)
    if not okRead then
        R.migrationStats.failed = R.migrationStats.failed + 1
        Brain.migrationLedger.failedSources[path] = {unix=os.time(), kind=kind, reason=tostring(raw)}
        migrationLine("FAILED", safeBasename(path), tostring(raw))
        return false, raw
    end

    local fp = sourceFingerprint(path, raw)

    -- Combat autosaves are cumulative. The newest discovered snapshot for a JobId wins this pass.
    -- Mark the JobId as seen even when the newest file was already imported, so older autosaves cannot be re-imported later.
    if kind == "COMBAT_OUTCOME" then
        local jobId = decodeTopField(raw, "jobId", 4096)
        if jobId and combatJobsSeen[tostring(jobId)] then
            R.migrationStats.skipped = R.migrationStats.skipped + 1
            migrationLine("SKIPPED", safeBasename(path), "Older cumulative combat autosave for JobId=" .. tostring(jobId))
            return false, "SUPERSEDED_COMBAT_AUTOSAVE"
        end
        if jobId then combatJobsSeen[tostring(jobId)] = true end
    end

    if sourceAlreadyImported(fp) then
        R.migrationStats.skipped = R.migrationStats.skipped + 1
        migrationLine("SKIPPED", safeBasename(path), "Already imported")
        return false, "ALREADY_IMPORTED"
    end

    local ok, detail
    if kind == "AI_LEGACY" then
        ok, detail = migrateLegacyAI(path, raw, fp)
    elseif kind == "STAGE1_WORLD" then
        ok, detail = migrateStage1World(path, raw, fp)
    elseif kind == "COMBAT_OUTCOME" then
        ok, detail = migrateCombatOutcome(path, raw, fp)
    elseif kind == "EVENT_TRACKER" then
        ok, detail = migrateEventTracker(path, raw, fp)
    elseif kind == "TRUST_REPLICATION" then
        ok, detail = migrateTrustReplication(path, raw, fp)
    elseif kind == "EVENT_INFO_TEXT" then
        ok, detail = migrateEventInfoText(path, raw, fp)
    end

    if ok then
        markImported(fp, path, kind, detail)
        R.migrationStats.imported = R.migrationStats.imported + 1
        migrationLine("IMPORTED", safeBasename(path), detail)
        return true, detail
    end

    R.migrationStats.failed = R.migrationStats.failed + 1
    Brain.migrationLedger.failedSources[path] = {unix=os.time(), kind=kind, reason=tostring(detail)}
    migrationLine("FAILED", safeBasename(path), tostring(detail))
    return false, detail
end

local function runLegacyMigration()
    if not API.readfile then
        migrationLine("DEFERRED", "ALL", "readfile unavailable; use manual persistent-brain import/export")
        return false, "READFILE_UNAVAILABLE"
    end
    local files = discoverLegacyFiles()
    if #files == 0 then
        migrationLine("INFO", "NONE", "No supported legacy JSON files discovered")
        return true, "NO_FILES"
    end
    local combatJobsSeen = {}
    for i,path in ipairs(files) do
        migrateOne(path, combatJobsSeen)
        if i % 2 == 0 then taskWait(0.03) end
    end
    return true, "DONE"
end

-- ============================================================
-- TRUE AI v1.4 ATTACH / HYDRATE / CAPTURE
-- ============================================================

local function getGlobalTableGetter(name)
    local fn = ENV[name]
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn)
    if ok and type(value) == "table" then return value end
    return nil
end

local function hydrateBaseAI()
    local memory = getGlobalTableGetter("STA_AI_OBSERVER_MEMORY")
    if not memory then return false, "BASE_MEMORY_GETTER_NOT_READY" end

    local capability = getGlobalTableGetter("STA_AI_CAPABILITIES") or memory.capabilityMemory
    local experience = getGlobalTableGetter("STA_AI_EXPERIENCES") or memory.experienceMemory
    local skills = getGlobalTableGetter("STA_AI_SKILLS") or memory.skillRegistry
    local decisions = getGlobalTableGetter("STA_AI_DECISIONS") or memory.decisionMemory
    local policy = getGlobalTableGetter("STA_AI_POLICY") or memory.policyMemory

    if type(capability) == "table" and type(Brain.live.capabilityMemory) == "table" then
        restoreTable(capability, Brain.live.capabilityMemory)
    end
    if type(experience) == "table" and type(Brain.live.experienceMemory) == "table" then
        restoreTable(experience, Brain.live.experienceMemory)
    end
    if type(skills) == "table" and type(Brain.live.skillRegistry) == "table" then
        restoreTable(skills, Brain.live.skillRegistry)
    end
    if type(decisions) == "table" and type(Brain.live.decisionMemory) == "table" then
        -- Never restore an in-flight current decision from a dead session.
        restoreTable(decisions, Brain.live.decisionMemory, 0, {current=true})
        decisions.current = nil
    end
    if type(policy) == "table" and type(Brain.live.policyMemory) == "table" then
        restoreTable(policy, Brain.live.policyMemory)
    end

    -- Do not hydrate old live WorldModel.objects or runtime ids into a new server.
    -- Persistent world knowledge lives in Brain.worldMemory by session/profile.
    if type(memory.trueAICore) == "table" then
        memory.trueAICore.autonomyArmed = false
        memory.trueAICore.mode = "SHADOW"
    end

    R.baseMemoryRef = memory
    R.attached = true
    R.hydrated = true
    R.hydrationAt = os.time()
    logLine("READY", "Attached to STA TRUE AI v1.4 and hydrated persistent learning state")
    return true
end

local function summarizeEpisodeTable(episodes)
    local out = {count=0, byType={}}
    if type(episodes) ~= "table" then return out end
    for _,ep in pairs(episodes) do
        if type(ep) == "table" then
            out.count = out.count + 1
            local t = tostring(ep.type or "UNKNOWN")
            local r = out.byType[t] or {count=0, success=0, failure=0, unknown=0, totalDuration=0}
            out.byType[t] = r
            r.count = r.count + 1
            r.totalDuration = r.totalDuration + (tonumber(ep.duration) or 0)
            if ep.success == true then r.success=r.success+1 elseif ep.success == false then r.failure=r.failure+1 else r.unknown=r.unknown+1 end
        end
    end
    return out
end

local function compactLiveWorld(world)
    if type(world) ~= "table" then return {} end
    return {
        schema = world.schema,
        stats = deepCopy(world.stats or {}),
        semanticsCount = countTable(world.semantics),
        resourceClusterCount = countTable(world.resourceClusters),
        chestCount = countTable(world.chests),
        unknownInteractableCount = countTable(world.unknownInteractables),
        geometryCellCount = world.geometry and world.geometry.cellCount or nil,
        -- A small recent semantic snapshot is useful; object/runtime-id tables are deliberately excluded.
        semanticsSample = compactMapEntries(world.semantics or {}, DEVICE.mobile and 120 or 400),
        resourceClusterSample = compactMapEntries(world.resourceClusters or {}, DEVICE.mobile and 80 or 250),
    }
end

local function captureLiveAI(reason)
    local memory = getGlobalTableGetter("STA_AI_OBSERVER_MEMORY")
    if not memory then return false, "BASE_NOT_ATTACHED" end

    local capability = getGlobalTableGetter("STA_AI_CAPABILITIES") or memory.capabilityMemory or {}
    local experience = getGlobalTableGetter("STA_AI_EXPERIENCES") or memory.experienceMemory or {}
    local skills = getGlobalTableGetter("STA_AI_SKILLS") or memory.skillRegistry or {}
    local decisions = getGlobalTableGetter("STA_AI_DECISIONS") or memory.decisionMemory or {}
    local policy = getGlobalTableGetter("STA_AI_POLICY") or memory.policyMemory or {}
    local world = getGlobalTableGetter("STA_AI_WORLD_MODEL") or memory.worldModel or {}
    local episodes = getGlobalTableGetter("STA_AI_OBSERVER_EPISODES") or {}

    local expLimit = DEVICE.mobile and CONFIG.MaxPersistedExperiencePerBucketMobile or CONFIG.MaxPersistedExperiencePerBucketDesktop
    local decisionLimit = DEVICE.mobile and CONFIG.MaxPersistedDecisionHistoryMobile or CONFIG.MaxPersistedDecisionHistoryDesktop

    Brain.live.capabilityMemory = deepCopy(capability)
    Brain.live.experienceMemory = {
        player = compactList(experience.player or {}, expLimit),
        ai = compactList(experience.ai or {}, expLimit),
        shadow = compactList(experience.shadow or {}, expLimit),
        failures = compactList(experience.failures or {}, expLimit),
        predictions = compactList(experience.predictions or {}, expLimit),
    }
    Brain.live.skillRegistry = deepCopy(skills)
    Brain.live.decisionMemory = {
        decisions = compactList(decisions.decisions or {}, decisionLimit),
        goalStats = deepCopy(decisions.goalStats or {}),
        current = nil,
    }
    Brain.live.policyMemory = deepCopy(policy)
    Brain.live.worldSummary = compactLiveWorld(world)
    Brain.live.runtimeKnowledge = {
        economy = deepCopy(getGlobalTableGetter("STA_AI_SKULL_ECONOMY") or memory.economy or {}),
        upgradeKnowledge = deepCopy(getGlobalTableGetter("STA_AI_UPGRADE_KNOWLEDGE") or memory.weaponUpgradeKnowledge or {}),
        skullRewardKnowledge = deepCopy(getGlobalTableGetter("STA_AI_SKULL_REWARD_KNOWLEDGE") or memory.skullRewardKnowledge or {}),
        foodKnowledge = deepCopy(getGlobalTableGetter("STA_AI_FOOD_KNOWLEDGE") or memory.foodKnowledge or {}),
        medicalKnowledge = deepCopy(getGlobalTableGetter("STA_AI_MEDICAL_KNOWLEDGE") or memory.medicalKnowledge or {}),
        shopKnowledge = deepCopy(getGlobalTableGetter("STA_AI_SHOP_KNOWLEDGE") or memory.shopKnowledge or {}),
        episodeSummary = summarizeEpisodeTable(episodes),
        capturedUnix = os.time(),
        reason = reason,
    }

    local profileKey = string.format("LIVE:%s:%s", tostring(game.PlaceId), tostring(game.JobId))
    Brain.worldMemory.sessionSummaries[profileKey] = {
        source="LIVE_V140",
        placeId=game.PlaceId,
        jobId=game.JobId,
        updatedUnix=os.time(),
        worldSummary=deepCopy(Brain.live.worldSummary),
        identityRule="LIVE_RUNTIME_OBJECTS_NOT_REUSED_ACROSS_JOB_IDS",
    }
    Brain.meta.sourceSessions[profileKey] = {
        placeId=game.PlaceId, jobId=game.JobId, updatedUnix=os.time(), executor=EXECUTOR_NAME, platform=DEVICE.platform,
    }
    R.lastBrainCaptureAt = os.clock()
    return true
end

local function attachIfReady()
    if R.attached then return true end
    local memory = getGlobalTableGetter("STA_AI_OBSERVER_MEMORY")
    if not memory then return false end
    return hydrateBaseAI()
end

-- ============================================================
-- REPORTS / SELF TEST / EXPORT
-- ============================================================

local function brainStats()
    return {
        schema=Brain.schema,
        brainVersion=Brain.brainVersion,
        importedSources=countTable(Brain.migrationLedger and Brain.migrationLedger.importedSources),
        deferredSources=countTable(Brain.migrationLedger and Brain.migrationLedger.deferredSources),
        failedSources=countTable(Brain.migrationLedger and Brain.migrationLedger.failedSources),
        worldSessions=countTable(Brain.worldMemory and Brain.worldMemory.sessionSummaries),
        baseProfiles=countTable(Brain.worldMemory and Brain.worldMemory.baseProfiles),
        resourceProfiles=countTable(Brain.worldMemory and Brain.worldMemory.resourceProfiles),
        combatSessions=countTable(Brain.combatMemory and Brain.combatMemory.sessions),
        combatWeapons=countTable(Brain.combatMemory and Brain.combatMemory.weaponStats),
        reactorSessions=Brain.eventMemory and Brain.eventMemory.reactor and countTable(Brain.eventMemory.reactor.sessions) or 0,
        trustSessions=Brain.networkMemory and Brain.networkMemory.trustTelemetry and countTable(Brain.networkMemory.trustTelemetry.sessions) or 0,
        replicationSessions=Brain.networkMemory and Brain.networkMemory.replication and countTable(Brain.networkMemory.replication.sessions) or 0,
        capabilityObjects=Brain.live and Brain.live.capabilityMemory and countTable(Brain.live.capabilityMemory.byObject) or 0,
        skillCount=Brain.live and Brain.live.skillRegistry and countTable(Brain.live.skillRegistry.skills) or 0,
        decisionHistory=Brain.live and Brain.live.decisionMemory and #(Brain.live.decisionMemory.decisions or {}) or 0,
        persistenceMode=AUTO_PERSISTENCE and "AUTO_LOCAL" or "MANUAL_EXPORT",
        attached=R.attached,
        hydrated=R.hydrated,
    }
end

local function diagnosticsPayload()
    return {
        schema="STA Stage 1.5 Diagnostics v1",
        version=VERSION,
        unix=os.time(),
        placeId=game.PlaceId,
        jobId=game.JobId,
        executor={name=EXECUTOR_NAME, family=EXECUTOR_FAMILY},
        device=DEVICE,
        api={
            readfile=API.readfile~=nil, writefile=API.writefile~=nil, appendfile=API.appendfile~=nil,
            isfile=API.isfile~=nil, listfiles=API.listfiles~=nil, delfile=API.delfile~=nil,
            setclipboard=API.setclipboard~=nil, getfilesize=API.getfilesize~=nil,
        },
        automaticCrossSessionPersistence=AUTO_PERSISTENCE,
        runtime={attached=R.attached, hydrated=R.hydrated, hydrationAt=R.hydrationAt},
        migration=R.migrationStats,
        selfTest=R.selfTest,
        brain=brainStats(),
        boundaries={
            generatedServerCalls=0,
            stateMutation=0,
            movementModification=0,
            trustAttributeWrites=0,
            remoteManipulation=0,
        },
    }
end

local function writeReports()
    local header = {
        "STA TRUE AI - STAGE 1.5 MIGRATION REPORT",
        "Version: " .. VERSION,
        "Executor: " .. EXECUTOR_NAME,
        "Platform: " .. DEVICE.platform,
        "Mobile: " .. tostring(DEVICE.mobile),
        "Persistence: " .. (AUTO_PERSISTENCE and "AUTO_LOCAL" or "MANUAL_EXPORT"),
        string.format("Discovered=%d Imported=%d Skipped=%d Deferred=%d Failed=%d Corrected=%d",
            R.migrationStats.discovered, R.migrationStats.imported, R.migrationStats.skipped,
            R.migrationStats.deferred, R.migrationStats.failed, R.migrationStats.corrected),
        "",
    }
    local lines = {}
    for _,v in ipairs(header) do lines[#lines+1]=v end
    for _,v in ipairs(R.migrationLines) do lines[#lines+1]=v end
    if API.writefile then pcall(API.writefile, FILES.MigrationReport, table.concat(lines, "\n")) end

    local ok, diag = encodeSafe(diagnosticsPayload())
    if ok and API.writefile then pcall(API.writefile, FILES.Diagnostics, diag) end
end

local function runSelfTest()
    local t = {json=false, checksum=false, fileRoundTrip=false, autoPersistence=AUTO_PERSISTENCE}
    local sample = {schema="SELFTEST", n=123.5, b=true, arr={1,2,3}, text="Stage15"}
    local okEnc, raw = encodeSafe(sample)
    if okEnc then
        local okDec, decoded = decodeJson(raw)
        t.json = okDec and type(decoded)=="table" and decoded.schema=="SELFTEST" and decoded.arr and decoded.arr[3]==3
        t.checksum = checksumText(raw) == checksumText(raw)
    end
    if API.writefile and API.readfile then
        local tmp = "STA_STAGE15_SELFTEST.tmp"
        local okWrite = writeVerified(tmp, raw or "{}")
        local okRead, back = readText(tmp)
        t.fileRoundTrip = okWrite and okRead and back == raw
        deleteIfPossible(tmp)
    else
        t.fileRoundTrip = false
    end
    R.selfTest = t
    logLine(t.json and "READY" or "ERROR", "SELF_TEST", "json="..tostring(t.json), "checksum="..tostring(t.checksum), "file="..tostring(t.fileRoundTrip))
    return t
end

local function exportBrain()
    captureLiveAI("EXPORT")
    local ok, raw = encodeSafe(Brain)
    if not ok then return nil, raw end
    ENV.STA_STAGE15_LAST_EXPORT = raw
    if API.setclipboard then pcall(API.setclipboard, raw) end
    return raw
end

local function importBrainJson(raw)
    local ok, decoded = decodeJson(raw)
    if not ok or type(decoded) ~= "table" or decoded.schema ~= BRAIN_SCHEMA then
        return false, "INVALID_STAGE15_BRAIN"
    end
    Brain = normalizeBrain(decoded)
    R.hydrated = false
    R.attached = false
    attachIfReady()
    savePersistentBrain("MANUAL_IMPORT")
    return true
end

-- ============================================================
-- MOBILE UI + DESKTOP HOTKEYS
-- ============================================================

local function createMobileGui()
    if not DEVICE.mobile or not CONFIG.CreateMobileGui then return end
    local ok, playerGui = pcall(function() return LocalPlayer:WaitForChild("PlayerGui", 10) end)
    if not ok or not playerGui then return end

    if playerGui:FindFirstChild("STA_STAGE15_GUI") then
        pcall(function() playerGui.STA_STAGE15_GUI:Destroy() end)
    end

    local gui = Instance.new("ScreenGui")
    gui.Name = "STA_STAGE15_GUI"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = false
    gui.Parent = playerGui

    local frame = Instance.new("Frame")
    frame.Name = "Panel"
    frame.Size = UDim2.fromOffset(178, 138)
    frame.Position = UDim2.new(1, -188, 0.5, -69)
    frame.BackgroundTransparency = 0.18
    frame.Parent = gui

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 28)
    title.BackgroundTransparency = 1
    title.Text = "STA AI Stage 1.5"
    title.TextScaled = true
    title.Parent = frame

    local function button(text, y, callback)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, -12, 0, 30)
        b.Position = UDim2.fromOffset(6, y)
        b.Text = text
        b.TextScaled = true
        b.Parent = frame
        b.Activated:Connect(function()
            local ok2, err = pcall(callback)
            if not ok2 then logLine("ERROR", "MOBILE_BUTTON", text, err) end
        end)
        return b
    end

    button("START / ATTACH", 32, function()
        attachIfReady()
        if type(ENV.STA_AI_OBSERVER_START) == "function" then ENV.STA_AI_OBSERVER_START() end
    end)
    button("SAVE BRAIN", 66, function()
        captureLiveAI("MOBILE_SAVE")
        savePersistentBrain("MOBILE_SAVE")
        writeReports()
    end)
    button("STOP + SAVE", 100, function()
        if type(ENV.STA_AI_OBSERVER_STOP) == "function" then pcall(ENV.STA_AI_OBSERVER_STOP) end
        captureLiveAI("MOBILE_STOP")
        savePersistentBrain("MOBILE_STOP")
        writeReports()
    end)

    R.mobileGui = gui
end

local function installDesktopHotkeys()
    if DEVICE.mobile then return end
    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if input.KeyCode == Enum.KeyCode.F8 then
            captureLiveAI("F8_SAVE")
            savePersistentBrain("F8_SAVE")
            writeReports()
        elseif input.KeyCode == Enum.KeyCode.F9 then
            local s = brainStats()
            print("[STA Stage 1.5 STATUS] Imported="..tostring(s.importedSources)
                .." WorldSessions="..tostring(s.worldSessions)
                .." CombatSessions="..tostring(s.combatSessions)
                .." Skills="..tostring(s.skillCount)
                .." Attached="..tostring(s.attached)
                .." Hydrated="..tostring(s.hydrated))
        end
    end)
end

-- ============================================================
-- GLOBAL API
-- ============================================================

ENV.STA_STAGE15_BRAIN = function() return Brain end
ENV.STA_STAGE15_STATUS = function() return diagnosticsPayload() end
ENV.STA_STAGE15_ATTACH = function() return attachIfReady() end
ENV.STA_STAGE15_MIGRATE = function()
    local ok, msg = runLegacyMigration()
    captureLiveAI("POST_MANUAL_MIGRATION")
    savePersistentBrain("POST_MANUAL_MIGRATION")
    writeReports()
    return ok, msg
end
ENV.STA_STAGE15_SAVE = function()
    captureLiveAI("MANUAL_SAVE")
    local ok, detail = savePersistentBrain("MANUAL_SAVE")
    writeReports()
    return ok, detail
end
ENV.STA_STAGE15_EXPORT = exportBrain
ENV.STA_STAGE15_IMPORT = importBrainJson
ENV.STA_STAGE15_SELFTEST = runSelfTest
ENV.STA_STAGE15_STOP = function()
    captureLiveAI("STAGE15_STOP")
    savePersistentBrain("STAGE15_STOP")
    writeReports()
    flushLog()
    R.running = false
    if R.heartbeat then pcall(function() R.heartbeat:Disconnect() end) R.heartbeat=nil end
    if R.mobileGui then pcall(function() R.mobileGui:Destroy() end) R.mobileGui=nil end
end

-- ============================================================
-- STARTUP
-- ============================================================

logLine("READY", "Stage 1.5 boot", VERSION, "Executor="..EXECUTOR_NAME, "Family="..EXECUTOR_FAMILY,
    "Platform="..DEVICE.platform, "Mobile="..tostring(DEVICE.mobile), "AutoPersistence="..tostring(AUTO_PERSISTENCE))

loadPersistentBrain()
touchBrainMeta()
runSelfTest()

if CONFIG.AutoMigrateLegacy then
    local ok, err = pcall(runLegacyMigration)
    if not ok then logLine("ERROR", "LEGACY_MIGRATION_FATAL", err) end
end

if CONFIG.AutoAttach then
    attachIfReady()
end

createMobileGui()
installDesktopHotkeys()

-- Save a migrated brain immediately, even before base AI starts.
savePersistentBrain("STAGE15_STARTUP")
writeReports()
flushLog()

R.heartbeat = RunService.Heartbeat:Connect(function()
    if not R.running then return end
    local t = os.clock()

    if not R.attached and t - R.lastAttachTry >= CONFIG.BaseAttachPollSeconds then
        R.lastAttachTry = t
        attachIfReady()
    end

    local interval = DEVICE.mobile and CONFIG.AutoSaveSecondsMobile or CONFIG.AutoSaveSecondsDesktop
    if t - R.lastSaveAt >= interval then
        if R.attached then captureLiveAI("AUTOSAVE") end
        savePersistentBrain("AUTOSAVE")
        writeReports()
    end
end)

print("============================================================")
print(" STA TRUE AI - STAGE 1.5 PERSISTENT BRAIN " .. VERSION)
print(" Executor: " .. EXECUTOR_NAME .. " [" .. EXECUTOR_FAMILY .. "]")
print(" Platform: " .. DEVICE.platform .. (DEVICE.mobile and " / MOBILE" or " / DESKTOP"))
print(" Persistence: " .. (AUTO_PERSISTENCE and "AUTO LOCAL" or "MANUAL EXPORT/IMPORT"))
print(" Base AI attached: " .. tostring(R.attached))
if not DEVICE.mobile then
    print(" F8 = SAVE BRAIN | F9 = STATUS")
else
    print(" Mobile controls created in PlayerGui")
end
print(" No FireServer / No InvokeServer / No trust or movement mutation")
print("============================================================")
