--[[
    STA TRUE AI PROJECT
    STAGE 1 / 8 - SEMANTIC WORLD OBSERVER v1.1.7 - UNIVERSAL EXECUTOR

    PURPOSE
    -------
    Build a precise, passive model of what exists in the client-visible game world.
    This stage DOES NOT learn how to use objects and DOES NOT control the player.

    PASSIVE / READ-ONLY GUARANTEES
    ------------------------------
    - No FireServer
    - No InvokeServer
    - No ProximityPrompt activation
    - No ClickDetector activation
    - No movement / Pathfinding / Humanoid control
    - No Tool activation
    - No aiming / shooting
    - No remote manipulation

    CONTROLS
    --------
    INSERT = START
    DELETE = STOP + SAVE

    OUTPUTS
    -------
    STA_STAGE1_WORLD_<timestamp>.log
    STA_STAGE1_WORLD_MEMORY_<timestamp>.json

    IMPORTANT SEMANTIC RULE
    -----------------------
    ChildAdded / DescendantAdded means FIRST OBSERVED, not "spawned".
    Streaming can make an already-existing object appear later on the client.
]]


print("[STA Stage 1 v1.1.7] FILE_ENTRY_OK")

local function __STA_STAGE1_FATAL_HANDLER(err)
    local message = tostring(err)
    local dbg = debug
    if type(dbg) == "table" and type(dbg.traceback) == "function" then
        local okTrace, trace = pcall(dbg.traceback, message, 2)
        if okTrace and type(trace) == "string" then
            message = trace
        end
    end
    if type(warn) == "function" then
        warn("[STA Stage 1 v1.1.7] TOP_LEVEL_FATAL | " .. message)
    else
        print("[STA Stage 1 v1.1.7] TOP_LEVEL_FATAL | " .. message)
    end
    return message
end

local __STA_STAGE1_TOP_OK, __STA_STAGE1_TOP_ERR = xpcall(function()
    print("[STA Stage 1 v1.1.7] MODULE_START | TOP_LEVEL_INIT")
    local Players = game:GetService("Players")
    local Workspace = game:GetService("Workspace")
    local UserInputService = game:GetService("UserInputService")
    local RunService = game:GetService("RunService")
    local HttpService = game:GetService("HttpService")
    local CollectionService = game:GetService("CollectionService")
    local Lighting = game:GetService("Lighting")
    local StatsService = game:GetService("Stats")

    local LocalPlayer = Players.LocalPlayer
    if not LocalPlayer then
        error("STA Stage 1 Observer: LocalPlayer is not available")
    end

    local ENV = _G
    do
        local gg = getgenv
        if type(gg) == "function" then
            local ok, candidate = pcall(gg)
            if ok and type(candidate) == "table" then
                ENV = candidate
            end
        end
    end

    -- ============================================================
    -- UNIVERSAL EXECUTOR PROFILE
    -- ============================================================

    local EXECUTOR = {
        name = "Unknown",
        version = "",
        display = "Unknown",
        family = "GENERIC",

        getgenv = type(getgenv) == "function",
        writefile = type(writefile) == "function",
        readfile = type(readfile) == "function",
        appendfile = type(appendfile) == "function",
        isfile = type(isfile) == "function",
        delfile = type(delfile) == "function",
        loadstring = type(loadstring) == "function",

        nativeJsonVectorBehavior = "UNTESTED",
        nativeJsonSparseBehavior = "UNTESTED",
        forceCustomJson = false,
        jsonMode = "AUTO_SANITIZED_NATIVE_WITH_CUSTOM_FALLBACK",

        statsMemory = false,

        -- FULL_PLAYERGUI_BUDGETED on executors proven stable with it.
        -- XENO uses TARGETED_STATE_ONLY because full PlayerGui traversal +
        -- thousands of property watchers correlates with CoreGui Locales
        -- failures on the tested XENO build.
        guiMode = "FULL_PLAYERGUI_BUDGETED",

        compatibilityWarnings = {},
    }

    local function addExecutorWarning(text)
        EXECUTOR.compatibilityWarnings[#EXECUTOR.compatibilityWarnings + 1] =
            tostring(text)
    end

    local function detectExecutor()
        local identified = false

        if type(identifyexecutor) == "function" then
            local ok, a, b = pcall(identifyexecutor)
            if ok and a ~= nil then
                EXECUTOR.name = tostring(a)
                EXECUTOR.version = b ~= nil and tostring(b) or ""
                identified = true
            end
        end

        if not identified and type(getexecutorname) == "function" then
            local ok, a = pcall(getexecutorname)
            if ok and a ~= nil then
                EXECUTOR.name = tostring(a)
                identified = true
            end
        end

        local lowerName = string.lower(EXECUTOR.name or "")

        if string.find(lowerName, "xeno", 1, true) then
            EXECUTOR.family = "XENO"
        elseif string.find(lowerName, "potassium", 1, true) then
            EXECUTOR.family = "POTASSIUM"
        else
            EXECUTOR.family = "GENERIC"
        end

        if EXECUTOR.version ~= "" then
            EXECUTOR.display = EXECUTOR.name .. " / " .. EXECUTOR.version
        else
            EXECUTOR.display = EXECUTOR.name
        end

        local okMemory = pcall(function()
            local v = StatsService:GetTotalMemoryUsageMb()
            assert(type(v) == "number")
        end)
        EXECUTOR.statsMemory = okMemory

        -- XENO was measured to serialize Roblox datatypes such as Vector3 as
        -- JSON null without throwing. Potassium was measured to reject some
        -- valid sanitized payloads. Both therefore use our deterministic
        -- encoder directly.
        if EXECUTOR.family == "XENO" or EXECUTOR.family == "POTASSIUM" then
            EXECUTOR.forceCustomJson = true
            EXECUTOR.jsonMode = "CUSTOM_JSON_ONLY"
        end

        if EXECUTOR.family == "XENO" then
            EXECUTOR.guiMode = "TARGETED_STATE_ONLY"
        else
            EXECUTOR.guiMode = "FULL_PLAYERGUI_BUDGETED"
        end
    end

    detectExecutor()

    local VERSION = "Stage1-v1.1.7"
    local SCHEMA = "STA True AI - Semantic World Observer Stage 1 v1.1.7"

    local CONFIG = {
        AutoStart = false,
        SaveToFile = true,

        InitialScanBatch = 220,
        InitialScanYield = 0.02,

        ObjectStateInterval = 0.85,
        ImportantMoveDistance = 1.75,
        ClusterInterval = 3.0,
        ClusterDistance = 24.0,
        ClusterGrid = 25.0,

        PlayerContextInterval = 0.5,
        AutoSaveInterval = 1800.0, -- 30 minutes
        ConsoleStatusInterval = 30.0,
        LogFlushSize = 180,

        MaxChildrenSummary = 40,
        MaxAttributesPerObject = 120,
        MaxTagsPerObject = 40,
        MaxClusterHistory = 30,
        MaxUnknownObjects = 8000,

        -- Performance budgets. Stage 1 must never try to process an entire
        -- streaming burst in one frame.
        DynamicWorldPerFrame = 30,
        DynamicGuiPerFrame = 20,
        DynamicBudgetMs = 3.0,

        RefreshObjectsPerFrame = 60,
        RefreshBudgetMs = 2.5,

        -- High-frequency numeric/UI changes are still stored as latest state,
        -- but console/file logging is sampled to prevent thousands of lines/sec.
        NumericChangeLogInterval = 0.20,
        GuiTextLogInterval = 0.30,

        -- Resource clustering is expensive; only recalc when dirty or on a
        -- periodic verification pass.
        ClusterVerifyInterval = 45.0,

        LowFpsThreshold = 35,
        CriticalFpsThreshold = 24,

        BaseRegionMinSamples = 8,
        BaseRegionMaxSamples = 160,
        BaseRegionPadding = 35.0,
        BaseRegionMinimumRadius = 45.0,

        ReclassifyOnPathChange = true,

        -- MEMORY GUARD
        MemoryGuardEnabled = true,
        MemoryCheckInterval = 5.0,
        MemoryPruneInterval = 15.0,

        MemoryWarnAbsoluteMb = 4000,
        MemoryHighAbsoluteMb = 5500,
        MemoryCriticalAbsoluteMb = 7000,

        MemoryWarnDeltaMb = 1000,
        MemoryHighDeltaMb = 2200,
        MemoryCriticalDeltaMb = 3500,

        MemoryElevatedWorldRetention = 600,
        MemoryHighWorldRetention = 180,
        MemoryCriticalWorldRetention = 30,

        MemoryElevatedGuiRetention = 180,
        MemoryHighGuiRetention = 60,
        MemoryCriticalGuiRetention = 15,

        MemoryElevatedPruneLimit = 800,
        MemoryHighPruneLimit = 3000,
        MemoryCriticalPruneLimit = 8000,

        MaxArchivedSemanticEntities = 6000,

        -- Universal executor compatibility.
        InitialFullMemorySave = false,
        ValidateEveryCustomJsonSave = true,
        ExecutorJsonSelfTest = true,

        -- Targeted GUI state is always allowed because it avoids recursive
        -- UI traversal. Current Day already uses TopUI.DayCounter directly.
        TargetedGuiPollInterval = 1.0,
    }

    -- ============================================================
    -- UNIVERSAL DEVICE PROFILE (DESKTOP + MOBILE)
    -- ============================================================

    local DEVICE = {
        TouchEnabled = UserInputService.TouchEnabled == true,
        KeyboardEnabled = UserInputService.KeyboardEnabled == true,
        MouseEnabled = UserInputService.MouseEnabled == true,
        GamepadEnabled = UserInputService.GamepadEnabled == true,
        Platform = "UNKNOWN",
        Mobile = false,
    }

    pcall(function()
        if type(UserInputService.GetPlatform) == "function" then
            DEVICE.Platform = tostring(UserInputService:GetPlatform())
        end
    end)

    -- A touchscreen Windows laptop can report TouchEnabled=true, so do not
    -- call it mobile while a keyboard/mouse is also available.
    DEVICE.Mobile = DEVICE.TouchEnabled and not DEVICE.KeyboardEnabled

    if DEVICE.Mobile then
        -- Same information model, gentler polling cadence for phones/tablets.
        -- Dynamic Added/Removing/attribute signals remain active, so discovery
        -- is still continuous; only periodic refresh work is spread out.
        CONFIG.InitialScanBatch = 40
        CONFIG.InitialScanYield = 0.02
        CONFIG.ObjectStateInterval = 1.25
        CONFIG.ClusterInterval = 12.0
        CONFIG.PlayerContextInterval = 0.75
        CONFIG.LogFlushSize = 120

        CONFIG.DynamicWorldPerFrame = 8
        CONFIG.DynamicGuiPerFrame = 5
        CONFIG.DynamicBudgetMs = 1.25

        CONFIG.RefreshObjectsPerFrame = 10
        CONFIG.RefreshBudgetMs = 0.9

        CONFIG.NumericChangeLogInterval = 0.45
        CONFIG.GuiTextLogInterval = 0.65
        CONFIG.ClusterVerifyInterval = 75.0

        -- Mobile memory thresholds.
        CONFIG.MemoryWarnAbsoluteMb = 2200
        CONFIG.MemoryHighAbsoluteMb = 3000
        CONFIG.MemoryCriticalAbsoluteMb = 4000

        CONFIG.MemoryWarnDeltaMb = 650
        CONFIG.MemoryHighDeltaMb = 1200
        CONFIG.MemoryCriticalDeltaMb = 2000
    end

    local function runExecutorJsonSelfTest()
        if not CONFIG.ExecutorJsonSelfTest then return end

        -- Vector3 behavior. Some executors return {"vector":null} instead of
        -- failing, which is silent data loss.
        local okVector, vectorResult = pcall(function()
            return HttpService:JSONEncode({
                vector = Vector3.new(1, 2, 3),
            })
        end)

        if okVector and type(vectorResult) == "string" then
            local lower = string.lower(vectorResult)
            if string.find(lower, "null", 1, true) then
                EXECUTOR.nativeJsonVectorBehavior = "SILENT_NULL"
                EXECUTOR.forceCustomJson = true
                EXECUTOR.jsonMode = "CUSTOM_JSON_ONLY"
                addExecutorWarning("Native JSON converts Roblox datatype to null")
            else
                EXECUTOR.nativeJsonVectorBehavior = "ACCEPTED_NON_NULL"
            end
        else
            EXECUTOR.nativeJsonVectorBehavior = "REJECTED"
        end

        local sparse = {}
        sparse[1] = "a"
        sparse[3] = "c"

        local okSparse, sparseResult = pcall(function()
            return HttpService:JSONEncode(sparse)
        end)

        if okSparse then
            EXECUTOR.nativeJsonSparseBehavior =
                "ACCEPTED:" .. tostring(sparseResult)
        else
            EXECUTOR.nativeJsonSparseBehavior = "REJECTED"
        end

        if EXECUTOR.forceCustomJson then
            EXECUTOR.jsonMode = "CUSTOM_JSON_ONLY"
        end
    end

    runExecutorJsonSelfTest()

    -- ============================================================
    -- EXECUTOR / LUAU COMPATIBILITY
    -- ============================================================

    local TASK = task
    local LEGACY_WAIT = wait

    local function safeWait(seconds)
        if type(TASK) == "table" and type(TASK.wait) == "function" then
            return TASK.wait(seconds)
        end
        if type(LEGACY_WAIT) == "function" then
            return LEGACY_WAIT(seconds)
        end
        return RunService.Heartbeat:Wait()
    end

    local function safeSpawn(fn)
        if type(TASK) == "table" and type(TASK.spawn) == "function" then
            return TASK.spawn(fn)
        end
        return coroutine.wrap(fn)()
    end

    local function safeDefer(fn)
        if type(TASK) == "table" and type(TASK.defer) == "function" then
            return TASK.defer(fn)
        end
        return safeSpawn(function()
            safeWait()
            fn()
        end)
    end

    -- Forward declaration: reportRuntimeError is defined before the
    -- logging section, but it must still be able to persist diagnostics.
    local logLine

    local RuntimeErrorLimiter = {}

    local function reportRuntimeError(stage, err)
        local stageText = tostring(stage)
        local errText = tostring(err)
        local fingerprint = stageText .. "|" .. errText
        local t = 0

        if type(os) == "table" and type(os.clock) == "function" then
            local okClock, v = pcall(os.clock)
            if okClock and type(v) == "number" then
                t = v
            end
        end

        local state = RuntimeErrorLimiter[fingerprint]
        if not state then
            state = {
                windowStart = t,
                shown = 0,
                suppressed = 0,
                total = 0,
            }
            RuntimeErrorLimiter[fingerprint] = state
        end

        state.total = state.total + 1

        -- New 5-second window: report suppression summary, then reset.
        if t - state.windowStart >= 5 then
            if state.suppressed > 0 then
                warn(
                    "[STA Stage 1 v1.1.7] ERROR_SUPPRESSION_SUMMARY"
                    .. " | Stage=" .. stageText
                    .. " | Suppressed=" .. tostring(state.suppressed)
                    .. " identical errors"
                )
                pcall(function()
                    logLine(
                        "ERROR_SUPPRESSION_SUMMARY",
                        "Stage=" .. stageText,
                        "Suppressed=" .. tostring(state.suppressed),
                        "Error=" .. errText
                    )
                end)
            end

            state.windowStart = t
            state.shown = 0
            state.suppressed = 0
        end

        -- Show at most 3 identical errors per 5 seconds.
        if state.shown >= 3 then
            state.suppressed = state.suppressed + 1
            return
        end

        state.shown = state.shown + 1

        local message = errText
        if type(debug) == "table" and type(debug.traceback) == "function" then
            local okTrace, trace = pcall(debug.traceback, errText, 2)
            if okTrace and type(trace) == "string" then
                message = trace
            end
        end

        warn(
            "[STA Stage 1 v1.1.7 ERROR] "
            .. stageText
            .. " | "
            .. message
        )

        pcall(function()
            logLine(
                "RUNTIME_ERROR",
                "Stage=" .. stageText,
                "Error=" .. errText
            )
        end)
    end

    local function protectedStage(stage, fn)
        local stageName = tostring(stage)
        local quiet = string.sub(stageName, 1, 9) == "PERIODIC_"

        if not quiet then
            print("[STA Stage 1 v1.1.7] MODULE_START | " .. stageName)
        end

        local started = 0
        if type(os) == "table" and type(os.clock) == "function" then
            local okClock, v = pcall(os.clock)
            if okClock and type(v) == "number" then started = v end
        end

        local ok, result = pcall(fn)
        if not ok then
            reportRuntimeError("MODULE_FAIL:" .. stageName, result)
            return false, result
        end

        if not quiet then
            local finished = started
            if type(os) == "table" and type(os.clock) == "function" then
                local okClock, v = pcall(os.clock)
                if okClock and type(v) == "number" then finished = v end
            end
            print(
                "[STA Stage 1 v1.1.7] MODULE_OK | "
                .. stageName
                .. " | Duration="
                .. tostring(math.floor(((finished - started) * 1000) + 0.5) / 1000)
            )
        end

        return true, result
    end

    -- Robust time helpers for executor compatibility.
    -- Some executors expose os.time but not os.clock consistently.
    local function safeClock()
        if type(os) == "table" and type(os.clock) == "function" then
            local ok, value = pcall(os.clock)
            if ok and type(value) == "number" then return value end
        end
        if type(time) == "function" then
            local ok, value = pcall(time)
            if ok and type(value) == "number" then return value end
        end
        if type(tick) == "function" then
            local ok, value = pcall(tick)
            if ok and type(value) == "number" then return value end
        end
        return 0
    end

    local function safeUnixTime()
        if type(os) == "table" and type(os.time) == "function" then
            local ok, value = pcall(os.time)
            if ok and type(value) == "number" then return value end
        end
        if type(tick) == "function" then
            local ok, value = pcall(tick)
            if ok and type(value) == "number" then return math.floor(value) end
        end
        return math.floor(safeClock())
    end

    -- ============================================================
    -- RUNTIME STATE
    -- ============================================================

    local Running = false
    local SessionStartClock = nil
    local SessionUnix = safeUnixTime()

    local LOG_FILE = string.format("STA_STAGE1_WORLD_V117_%d.log", SessionUnix)
    local MEMORY_FILE = string.format("STA_STAGE1_WORLD_MEMORY_V117_%d.json", SessionUnix)

    local canWrite = CONFIG.SaveToFile and type(writefile) == "function"
    local canAppend = CONFIG.SaveToFile and type(appendfile) == "function"

    local LogBuffer = {}
    local Connections = {}
    local MainHeartbeatConnection = nil
    local CharacterConnection = nil
    local ControlConnection = nil
    local MobileUIConnection = nil
    local MobileGui = nil
    local MobileStatusLabel = nil
    local MobileStartButton = nil
    local MobileSaveButton = nil
    local MobileStopButton = nil

    local ObjectCounter = 0
    local GuiCounter = 0
    local ClusterCounter = 0

    local RuntimeByInstance = setmetatable({}, {__mode = "k"})
    local GuiRuntimeByInstance = setmetatable({}, {__mode = "k"})

    -- Weak reverse references: do not keep streamed-out Instances alive.
    local WorldInstanceByRuntimeId = setmetatable({}, {__mode = "v"})
    local GuiInstanceByRuntimeId = setmetatable({}, {__mode = "v"})

    -- Event connections owned by individual observed objects.
    local ObjectConnectionsByRuntimeId = {}
    local GuiConnectionsByRuntimeId = {}

    local WorldObjects = {}
    local GuiObjects = {}
    local SemanticCandidates = {}
    local ResourceClusters = {}
    local BaseInfrastructure = {}
    local WorldInfrastructure = {}
    local LootContainers = {}
    local Interactables = {}
    local UnknownObjects = {}
    local SignatureHistory = {}

    -- Compact history retained when large removed records are pruned.
    local ArchivedWorldEntities = {}
    local ArchivedWorldOrder = {}

    local MemoryGuard = {
        enabled = CONFIG.MemoryGuardEnabled,
        level = "NORMAL",
        totalMb = nil,
        source = "UNKNOWN",
        baselineMb = nil,
        peakMb = 0,
        deltaMb = 0,
        workFactor = 1.0,
        logMultiplier = 1.0,
        clusterMultiplier = 1.0,
        lastCheckAt = 0,
        lastPruneAt = 0,
        transitions = 0,
        worldRecordsPruned = 0,
        guiRecordsPruned = 0,
        semanticArchivesCreated = 0,
        ownedConnectionsDisconnected = 0,
        periodicRefreshEntriesDropped = 0,
        emergencyCollections = 0,
    }

    local LastObjectStateScan = 0
    local LastClusterScan = 0
    local LastTargetedGuiPoll = 0

    local TargetedGuiState = {
        mode = EXECUTOR.guiMode,
        dayCounterPath = nil,
        dayCounterText = nil,
        observations = 0,
        changes = 0,
        lastObservedAt = nil,
    }
    local LastContextScan = 0
    local LastAutosave = 0
    local LastConsoleStatus = 0

    -- Streaming-safe work queues.
    local DynamicWorldQueue = {}
    local DynamicWorldHead = 1
    local DynamicWorldQueued = setmetatable({}, {__mode = "k"})

    local DynamicGuiQueue = {}
    local DynamicGuiHead = 1
    local DynamicGuiQueued = setmetatable({}, {__mode = "k"})

    -- Only objects marked periodicRefresh enter this list.
    local PeriodicRefreshList = {}
    local PeriodicRefreshIndex = 1

    local ResourceClusterDirty = true
    local LastClusterVerification = 0

    local FpsEma = 60
    local LastHeartbeatAt = nil
    local StreamingBurstPeak = 0

    local BaseRegionModel = {
        sampleCount = 0,
        recentSamples = {},
        center = nil,
        observedRadius = 0,
        effectiveRadius = 0,
        confidence = 0,
        lastUpdatedAt = nil,
        anchorIds = {},
    }

    local CurrentContext = {
        phase = nil,
        nearBase = nil,
        playerPosition = nil,
        day = nil,
        daySource = nil,
        highestDayRecord = nil,
    }

    local Statistics = {
        objectsObserved = 0,
        objectsPreexistingAtStart = 0,
        objectsObservedAfterStart = 0,
        objectsRemoved = 0,
        objectsReobserved = 0,
        objectsMoved = 0,
        attributeChanges = 0,
        valueChanges = 0,
        promptDiscovered = 0,
        promptChanges = 0,
        guiObserved = 0,
        guiChanges = 0,
        semanticCandidates = 0,
        resourceClustersCreated = 0,
        resourceClusterUpdates = 0,
        dynamicWorldQueued = 0,
        dynamicWorldProcessed = 0,
        dynamicGuiQueued = 0,
        dynamicGuiProcessed = 0,
        streamingBurstPeak = 0,
        throttledNumericLogs = 0,
        throttledGuiTextLogs = 0,
        semanticReclassifications = 0,
        canonicalEntities = 0,
        baseRegionSamples = 0,
        dynamicWorldDuplicateSkips = 0,
        dynamicGuiDuplicateSkips = 0,
        invalidUtf8BytesReplaced = 0,
        memoryGuardTransitions = 0,
        memoryWorldRecordsPruned = 0,
        memoryGuiRecordsPruned = 0,
        memorySemanticArchivesCreated = 0,
        memoryOwnedConnectionsDisconnected = 0,
        byClass = {},
        byCategory = {},
    }

    -- ============================================================
    -- BASIC HELPERS
    -- ============================================================

    local function now()
        return safeClock()
    end

    local function elapsed()
        if not SessionStartClock then return 0 end
        return now() - SessionStartClock
    end

    local function round(n, digits)
        if type(n) ~= "number" then return n end
        local p = 10 ^ (digits or 2)
        return math.floor(n * p + 0.5) / p
    end

    local function safeFullName(obj)
        if not obj then return "nil" end
        local ok, result = pcall(function()
            return obj:GetFullName()
        end)
        return ok and result or tostring(obj)
    end

    local function boolString(v)
        if v == nil then return "nil" end
        return tostring(v)
    end

    local function tableCount(t)
        local n = 0
        for _ in pairs(t or {}) do n = n + 1 end
        return n
    end

    local function shallowCopy(t)
        local out = {}
        for k,v in pairs(t or {}) do out[k] = v end
        return out
    end

    local function arrayCopy(t)
        local out = {}
        for i,v in ipairs(t or {}) do out[i] = v end
        return out
    end

    local function vectorToTable(v)
        if typeof(v) ~= "Vector3" then return nil end
        return {x = round(v.X, 3), y = round(v.Y, 3), z = round(v.Z, 3)}
    end

    local function cframeToTable(cf)
        if typeof(cf) ~= "CFrame" then return nil end
        local c = {cf:GetComponents()}
        local out = {}
        for i = 1, #c do out[i] = round(c[i], 5) end
        return out
    end

    local function udim2ToTable(v)
        if typeof(v) ~= "UDim2" then return nil end
        return {
            xScale = v.X.Scale,
            xOffset = v.X.Offset,
            yScale = v.Y.Scale,
            yOffset = v.Y.Offset,
        }
    end

    local function safeScalar(v)
        local tv = typeof(v)
        if tv == "nil" or tv == "boolean" or tv == "string" then
            return v
        elseif tv == "number" then
            if v ~= v then return "<NON_FINITE:NaN>" end
            if v == math.huge then return "<NON_FINITE:+INF>" end
            if v == -math.huge then return "<NON_FINITE:-INF>" end
            return v
        elseif tv == "Vector3" then
            return vectorToTable(v)
        elseif tv == "CFrame" then
            return cframeToTable(v)
        elseif tv == "Color3" then
            return {r = round(v.R, 5), g = round(v.G, 5), b = round(v.B, 5)}
        elseif tv == "BrickColor" then
            return tostring(v)
        elseif tv == "EnumItem" then
            return tostring(v)
        elseif tv == "UDim2" then
            return udim2ToTable(v)
        elseif tv == "Instance" then
            return {instancePath = safeFullName(v), class = v.ClassName, name = v.Name}
        end
        return tostring(v)
    end

    local function getAttributes(obj)
        local out = {}
        local ok, attrs = pcall(function() return obj:GetAttributes() end)
        if not ok or type(attrs) ~= "table" then return out end
        local count = 0
        for k,v in pairs(attrs) do
            count = count + 1
            if count > CONFIG.MaxAttributesPerObject then break end
            out[tostring(k)] = safeScalar(v)
        end
        return out
    end

    local function getTags(obj)
        local out = {}
        local ok, tags = pcall(function() return CollectionService:GetTags(obj) end)
        if not ok or type(tags) ~= "table" then return out end
        for i = 1, math.min(#tags, CONFIG.MaxTagsPerObject) do
            out[i] = tostring(tags[i])
        end
        table.sort(out)
        return out
    end

    local function arraysEqual(a, b)
        if #(a or {}) ~= #(b or {}) then return false end
        for i = 1, #(a or {}) do
            if a[i] ~= b[i] then return false end
        end
        return true
    end

    local function dictEquivalent(a, b)
        a = a or {}
        b = b or {}
        if tableCount(a) ~= tableCount(b) then return false end
        for k,v in pairs(a) do
            local av = v
            local bv = b[k]
            if type(av) == "table" or type(bv) == "table" then
                local ok1, enc1 = pcall(function() return HttpService:JSONEncode(av) end)
                local ok2, enc2 = pcall(function() return HttpService:JSONEncode(bv) end)
                if not ok1 or not ok2 or enc1 ~= enc2 then return false end
            elseif av ~= bv then
                return false
            end
        end
        return true
    end

    local function getSpatialInstance(obj)
        if not obj then return nil end
        if obj:IsA("BasePart") then return obj end
        if obj:IsA("Model") then
            if obj.PrimaryPart then return obj.PrimaryPart end
            return obj:FindFirstChildWhichIsA("BasePart", true)
        end
        if obj:IsA("Tool") then
            return obj:FindFirstChild("Handle") or obj:FindFirstChildWhichIsA("BasePart", true)
        end
        if obj:IsA("Attachment") then return obj end
        local parent = obj.Parent
        if parent and (obj:IsA("ProximityPrompt") or obj:IsA("ClickDetector")) then
            if parent:IsA("BasePart") then return parent end
            if parent:IsA("Attachment") then return parent end
            if parent:IsA("Model") then
                return parent.PrimaryPart or parent:FindFirstChildWhichIsA("BasePart", true)
            end
        end
        return nil
    end

    local function getPosition(obj)
        local spatial = getSpatialInstance(obj)
        if not spatial then return nil end
        if spatial:IsA("Attachment") then
            local ok, p = pcall(function() return spatial.WorldPosition end)
            return ok and p or nil
        end
        if spatial:IsA("BasePart") then return spatial.Position end
        return nil
    end

    local function getCFrame(obj)
        local spatial = getSpatialInstance(obj)
        if not spatial then return nil end
        if spatial:IsA("Attachment") then
            local ok, cf = pcall(function() return spatial.WorldCFrame end)
            return ok and cf or nil
        end
        if spatial:IsA("BasePart") then return spatial.CFrame end
        return nil
    end

    local function getSize(obj)
        if obj:IsA("BasePart") then return obj.Size end
        if obj:IsA("Model") then
            local ok, size = pcall(function()
                local _, s = obj:GetBoundingBox()
                return s
            end)
            return ok and size or nil
        end
        local spatial = getSpatialInstance(obj)
        if spatial and spatial:IsA("BasePart") then return spatial.Size end
        return nil
    end

    local function distance(a, b)
        if typeof(a) ~= "Vector3" or typeof(b) ~= "Vector3" then return math.huge end
        return (a - b).Magnitude
    end

    local function currentCharacter()
        return LocalPlayer.Character
    end

    local function currentRoot()
        local c = currentCharacter()
        if not c then return nil end
        return c:FindFirstChild("HumanoidRootPart") or c.PrimaryPart
    end

    local function currentPlayerPosition()
        local root = currentRoot()
        return root and root.Position or nil
    end

    local function currentNearBase()
        local c = currentCharacter()
        if not c then return nil end
        local value = c:GetAttribute("NearBase")
        if value == nil then return nil end
        return value == true
    end

    local function currentPhase()
        local ct = Lighting.ClockTime
        if ct >= 6 and ct < 18 then return "DAY" end
        return "NIGHT"
    end

    local function readDayCounterGui()
        local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if not playerGui then return nil end

        local topUI = playerGui:FindFirstChild("TopUI")
        if not topUI then return nil end

        local dayCounter = topUI:FindFirstChild("DayCounter")
        if not dayCounter then return nil end

        local ok, text = pcall(function() return dayCounter.Text end)
        if not ok or type(text) ~= "string" then return nil end

        local n = string.match(text, "[Dd][Aa][Yy]%s*:%s*(%d+)")
        if not n then
            n = string.match(text, "(%d+)")
        end

        return tonumber(n)
    end

    local function currentDay()
        local guiDay = readDayCounterGui()
        if guiDay ~= nil then
            return guiDay, "TopUI.DayCounter"
        end

        local highest = LocalPlayer:GetAttribute("HighestDay")
        if highest ~= nil then
            return highest, "HighestDay_FALLBACK"
        end

        return nil, "UNKNOWN"
    end

    local function currentHighestDayRecord()
        return LocalPlayer:GetAttribute("HighestDay")
    end

    local function normalizeText(s)
        s = tostring(s or "")
        s = string.lower(s)
        s = string.gsub(s, "[_%-]+", " ")
        s = string.gsub(s, "%s+", " ")
        return s
    end

    local function containsText(haystack, needle)
        return string.find(normalizeText(haystack), normalizeText(needle), 1, true) ~= nil
    end

    logLine = function(kind, ...)
        if not Running and kind ~= "CONTROL" then return end
        local parts = {string.format("[%.3f] %s", elapsed(), tostring(kind))}
        local args = {...}
        for i = 1, #args do
            parts[#parts + 1] = tostring(args[i])
        end
        local line = table.concat(parts, " | ")
        LogBuffer[#LogBuffer + 1] = line
        if #LogBuffer >= CONFIG.LogFlushSize then
            local text = table.concat(LogBuffer, "\n") .. "\n"
            if canAppend then
                pcall(function() appendfile(LOG_FILE, text) end)
            elseif canWrite then
                local existing = ""
                if type(readfile) == "function" and type(isfile) == "function" then
                    pcall(function()
                        if isfile(LOG_FILE) then existing = readfile(LOG_FILE) end
                    end)
                end
                pcall(function() writefile(LOG_FILE, existing .. text) end)
            end
            LogBuffer = {}
        end
    end

    local function flushLog()
        if #LogBuffer == 0 then return end
        local text = table.concat(LogBuffer, "\n") .. "\n"
        if canAppend then
            pcall(function() appendfile(LOG_FILE, text) end)
        elseif canWrite then
            local existing = ""
            if type(readfile) == "function" and type(isfile) == "function" then
                pcall(function()
                    if isfile(LOG_FILE) then existing = readfile(LOG_FILE) end
                end)
            end
            pcall(function() writefile(LOG_FILE, existing .. text) end)
        end
        LogBuffer = {}
    end

    local function connect(conn)
        Connections[#Connections + 1] = conn
        return conn
    end

    local function connectOwned(runtimeId, conn)
        local list = ObjectConnectionsByRuntimeId[runtimeId]
        if not list then
            list = {}
            ObjectConnectionsByRuntimeId[runtimeId] = list
        end
        list[#list + 1] = conn
        return conn
    end

    local function connectGuiOwned(runtimeId, conn)
        local list = GuiConnectionsByRuntimeId[runtimeId]
        if not list then
            list = {}
            GuiConnectionsByRuntimeId[runtimeId] = list
        end
        list[#list + 1] = conn
        return conn
    end

    local function disconnectOwned(map, runtimeId)
        local list = map[runtimeId]
        if not list then return 0 end

        local disconnected = 0
        for _,conn in ipairs(list) do
            local ok = pcall(function() conn:Disconnect() end)
            if ok then disconnected = disconnected + 1 end
        end

        map[runtimeId] = nil

        MemoryGuard.ownedConnectionsDisconnected =
            (MemoryGuard.ownedConnectionsDisconnected or 0) + disconnected
        Statistics.memoryOwnedConnectionsDisconnected =
            (Statistics.memoryOwnedConnectionsDisconnected or 0) + disconnected

        return disconnected
    end

    local function disconnectAllOwned(map)
        local ids = {}
        for runtimeId,_ in pairs(map) do
            ids[#ids + 1] = runtimeId
        end
        for _,runtimeId in ipairs(ids) do
            disconnectOwned(map, runtimeId)
        end
    end

    local function disconnectAll()
        for _,conn in ipairs(Connections) do
            pcall(function() conn:Disconnect() end)
        end
        Connections = {}

        disconnectAllOwned(ObjectConnectionsByRuntimeId)
        disconnectAllOwned(GuiConnectionsByRuntimeId)
    end

    -- ============================================================
    -- SEMANTIC CLASSIFICATION - HINTS ONLY, NEVER PROOF
    -- ============================================================

    local function addCandidate(list, category, confidence, evidence)
        for _,c in ipairs(list) do
            if c.category == category then
                if confidence > c.confidence then c.confidence = confidence end
                c.evidence[#c.evidence + 1] = evidence
                return
            end
        end
        list[#list + 1] = {
            category = category,
            confidence = confidence,
            evidence = {evidence},
        }
    end

    local function lowerPath(obj)
        return string.lower(safeFullName(obj))
    end

    local function pathContains(path, token)
        return string.find(string.lower(path or ""), string.lower(token or ""), 1, true) ~= nil
    end

    local function explicitTypeText(attrs)
        return normalizeText(
            attrs.ToolType
            or attrs.ItemType
            or attrs.Category
            or attrs.Type
            or ""
        )
    end

    local function promptHintForEntity(obj)
        local prompt = nil

        if obj:IsA("ProximityPrompt") then
            prompt = obj
        elseif obj:IsA("Model") or obj:IsA("Tool") or obj:IsA("BasePart") then
            local ok, found = pcall(function()
                return obj:FindFirstChildWhichIsA("ProximityPrompt", true)
            end)
            if ok then prompt = found end
        end

        if not prompt then return "", "" end

        local actionText, objectText = "", ""
        pcall(function() actionText = prompt.ActionText or "" end)
        pcall(function() objectText = prompt.ObjectText or "" end)

        return normalizeText(actionText), normalizeText(objectText)
    end

    local function modelLooksCanonical(obj)
        if not obj then return false end

        if obj:IsA("Tool") then
            return true
        end

        local path = lowerPath(obj)
        local name = normalizeText(obj.Name)
        local parentName = obj.Parent and normalizeText(obj.Parent.Name) or ""

        if parentName == "droppeditems" or pathContains(path, "workspace.droppeditems.") then
            return obj:IsA("Model") or obj:IsA("BasePart")
        end

        if pathContains(path, "workspace.map.crates.") then
            return obj:IsA("Model")
        end

        if pathContains(path, "workspace.structures.generator") then
            return obj:IsA("Model")
        end

        if pathContains(path, "workspace.crafting.workbench") then
            return obj:IsA("Model")
        end

        if pathContains(path, "gas station.pump") and name == "pump" then
            return obj:IsA("Model")
        end

        if pathContains(path, "power plant.power box")
            and (name == "power box" or name == "powerbox")
        then
            return obj:IsA("Model")
        end

        if name == "mysterybox" or name == "mystery box" then
            return obj:IsA("Model")
        end

        if containsText(name, "healpad") or containsText(name, "heal pad") then
            return obj:IsA("Model") or obj:IsA("BasePart")
        end

        if containsText(name, "ammo craft") or containsText(name, "ammo bench") then
            return obj:IsA("Model")
        end

        return false
    end

    local function semanticOwnerFor(obj)
        if not obj then return nil end

        if modelLooksCanonical(obj) then
            return obj
        end

        local cursor = obj.Parent
        local depth = 0
        while cursor and cursor ~= game and depth < 10 do
            if modelLooksCanonical(cursor) then
                return cursor
            end
            cursor = cursor.Parent
            depth = depth + 1
        end

        if obj:IsA("Tool") or obj:IsA("Model") then
            return obj
        end

        return nil
    end

    local function identityTextFor(obj)
        local actionText, objectText = promptHintForEntity(obj)
        return normalizeText(table.concat({
            obj.Name,
            obj.ClassName,
            safeFullName(obj),
            actionText,
            objectText,
        }, " ")), actionText, objectText
    end

    local function classifyObject(obj)
        local candidates = {}
        local attrs = getAttributes(obj)
        local identity, promptAction, promptObject = identityTextFor(obj)
        local path = lowerPath(obj)
        local name = normalizeText(obj.Name)
        local owner = semanticOwnerFor(obj)
        local isCanonical = owner == obj

        if obj:IsA("ProximityPrompt") then
            addCandidate(candidates, "INTERACTABLE_PROMPT", 0.98, "PROXIMITY_PROMPT_CLASS")
        end

        if obj:IsA("DragDetector") then
            addCandidate(candidates, "INTERACTABLE_DRAG", 0.99, "DRAG_DETECTOR_CLASS")
        elseif obj:IsA("ClickDetector") then
            addCandidate(candidates, "INTERACTABLE_CLICK", 0.98, "CLICK_DETECTOR_CLASS")
        end

        if not isCanonical then
            return candidates
        end

        -- Loot containers.
        if pathContains(path, "workspace.map.crates.emerald")
            or name == "emerald chest"
        then
            addCandidate(candidates, "LOOT_EMERALD_CHEST", 0.99, "CANONICAL_PATH_OR_NAME")
        elseif pathContains(path, "workspace.map.crates.default")
            or name == "default chest"
            or name == "defult chest"
        then
            addCandidate(candidates, "LOOT_DEFAULT_CHEST", 0.99, "CANONICAL_PATH_OR_NAME")
        elseif pathContains(path, "workspace.map.crates.super") then
            addCandidate(candidates, "LOOT_SUPER_CRATE", 0.98, "CANONICAL_PATH")
        elseif containsText(identity, "supply drop crate")
            or (containsText(identity, "supply drop") and containsText(identity, "crate"))
        then
            addCandidate(candidates, "LOOT_SUPPLY_DROP_CRATE", 0.96, "NAME_OR_PROMPT_HINT")
        elseif name == "mysterybox"
            or name == "mystery box"
            or containsText(promptObject, "mystery box")
        then
            addCandidate(candidates, "LOOT_MYSTERY_BOX", 0.99, "CANONICAL_NAME_OR_PROMPT")
        elseif containsText(name, "chest") then
            addCandidate(candidates, "LOOT_CHEST_UNKNOWN_TYPE", 0.48, "GENERIC_CANONICAL_CHEST_NAME")
        elseif containsText(name, "crate") and not containsText(path, "spawn") then
            addCandidate(candidates, "LOOT_CRATE_UNKNOWN_TYPE", 0.45, "GENERIC_CANONICAL_CRATE_NAME")
        end

        -- Base/world infrastructure. Attribute names are intentionally not
        -- identity evidence (prevents Zombie AI TargetGenerator false positives).
        if pathContains(path, "workspace.structures.generator") and name == "generator" then
            addCandidate(candidates, "INFRA_GENERATOR", 0.99, "CANONICAL_GENERATOR_PATH")
        elseif name == "generator" and containsText(promptObject, "generator") then
            addCandidate(candidates, "INFRA_GENERATOR", 0.92, "NAME_PLUS_PROMPT")
        end

        if pathContains(path, "workspace.crafting.workbench")
            and (name == "workbench" or containsText(promptObject, "workbench"))
        then
            addCandidate(candidates, "INFRA_CRAFT", 0.99, "CANONICAL_WORKBENCH_PATH")
        elseif containsText(name, "workbench") or containsText(promptAction, "craft") then
            addCandidate(candidates, "INFRA_CRAFT", 0.78, "CANONICAL_NAME_OR_PROMPT")
        end

        if containsText(name, "ammo craft")
            or containsText(name, "ammo bench")
            or (containsText(promptObject, "ammo") and containsText(promptAction, "craft"))
        then
            addCandidate(candidates, "INFRA_AMMO_CRAFT", 0.94, "CANONICAL_NAME_OR_PROMPT")
        end

        if containsText(name, "healpad")
            or containsText(name, "heal pad")
            or containsText(promptObject, "healpad")
            or containsText(promptObject, "heal pad")
        then
            addCandidate(candidates, "INFRA_HEALPAD", 0.94, "CANONICAL_NAME_OR_PROMPT")
        end

        if pathContains(path, "gas station.pump")
            and (name == "pump" or containsText(promptObject, "gas pump"))
        then
            addCandidate(candidates, "WORLD_FUEL_PUMP", 0.99, "GAS_STATION_PATH_PLUS_PROMPT")
        elseif containsText(promptObject, "gas pump") then
            addCandidate(candidates, "WORLD_FUEL_PUMP", 0.92, "PROMPT_OBJECT_TEXT")
        end

        if pathContains(path, "power plant.power box")
            and (containsText(promptObject, "power plant") or containsText(promptAction, "repair"))
        then
            addCandidate(candidates, "WORLD_POWER_PLANT", 0.99, "POWER_PLANT_PATH_PLUS_PROMPT")
        end

        -- Canonical portable/dropped resources only.
        local toolType = explicitTypeText(attrs)

        if toolType ~= "" then
            if containsText(toolType, "medical") then
                addCandidate(candidates, "RESOURCE_MEDICAL", 0.94, "EXPLICIT_TYPE_ATTRIBUTE_VALUE")
            end
            if containsText(toolType, "food") then
                addCandidate(candidates, "RESOURCE_FOOD", 0.94, "EXPLICIT_TYPE_ATTRIBUTE_VALUE")
            end
            if containsText(toolType, "fuel") then
                addCandidate(candidates, "RESOURCE_FUEL", 0.94, "EXPLICIT_TYPE_ATTRIBUTE_VALUE")
            end
            if containsText(toolType, "ammo") or containsText(toolType, "ammunition") then
                addCandidate(candidates, "RESOURCE_AMMO", 0.94, "EXPLICIT_TYPE_ATTRIBUTE_VALUE")
            end
            if containsText(toolType, "gun")
                or containsText(toolType, "melee")
                or containsText(toolType, "weapon")
                or containsText(toolType, "throwable")
            then
                addCandidate(candidates, "RESOURCE_WEAPON", 0.92, "EXPLICIT_TYPE_ATTRIBUTE_VALUE")
            end
            if containsText(toolType, "scrap") then
                addCandidate(candidates, "RESOURCE_SCRAP", 0.94, "EXPLICIT_TYPE_ATTRIBUTE_VALUE")
            end
        end

        if name == "fuel"
            or name == "refined fuel"
            or name == "gas can"
            or name == "gasoline"
        then
            addCandidate(candidates, "RESOURCE_FUEL", 0.84, "CANONICAL_NAME_HINT")
        end

        if name == "scrap" then
            addCandidate(candidates, "RESOURCE_SCRAP", 0.86, "CANONICAL_NAME_HINT")
        elseif name == "screws" or name == "screw" then
            addCandidate(candidates, "RESOURCE_CRAFT_MATERIAL", 0.60, "CANONICAL_NAME_HINT")
        end

        if containsText(name, " ammo")
            or name == "ammo"
            or containsText(name, "ammunition")
            or name == "shells"
        then
            addCandidate(candidates, "RESOURCE_AMMO", 0.84, "CANONICAL_NAME_HINT")
        end

        if name == "bandage"
            or name == "medkit"
            or containsText(name, "medical")
            or name == "compound r"
            or name == "compound s"
            or name == "compound i"
        then
            addCandidate(candidates, "RESOURCE_MEDICAL", 0.82, "CANONICAL_NAME_HINT")
        end

        if name == "beans"
            or name == "apple"
            or name == "carrot"
            or name == "bread"
            or name == "meat"
            or containsText(name, "canned")
            or containsText(name, "food")
        then
            addCandidate(candidates, "RESOURCE_FOOD", 0.80, "CANONICAL_NAME_HINT")
        end

        if obj:IsA("Tool") and toolType == "" then
            local hasResource = false
            for _,candidate in ipairs(candidates) do
                if string.sub(candidate.category or "", 1, 9) == "RESOURCE_" then
                    hasResource = true
                    break
                end
            end
            if not hasResource then
                addCandidate(candidates, "RESOURCE_PORTABLE_ITEM_UNKNOWN", 0.30, "TOOL_CLASS")
            end
        end

        return candidates
    end

    local function isResourceCategory(category)
        return string.sub(category or "", 1, 9) == "RESOURCE_"
    end

    -- Must be defined before registerWorldObject().
    -- Dynamic streaming registrations call this helper immediately.
    local function recordHasResourceCandidate(rec)
        for _,c in ipairs((rec and rec.semanticCandidates) or {}) do
            if isResourceCategory(c.category) and c.confidence >= 0.45 then
                return true
            end
        end
        return false
    end

    local function isInfrastructureCategory(category)
        return string.sub(category or "", 1, 6) == "INFRA_"
    end

    local function isWorldInfrastructureCategory(category)
        return string.sub(category or "", 1, 6) == "WORLD_"
    end

    local function isLootCategory(category)
        return string.sub(category or "", 1, 5) == "LOOT_"
    end

    local function classificationImportant(candidates)
        for _,c in ipairs(candidates or {}) do
            if c.confidence >= 0.45 then return true end
        end
        return false
    end

    -- ============================================================
    -- LEARNED BASE REGION
    -- ============================================================

    local function recomputeBaseRegion()
        local samples = BaseRegionModel.recentSamples
        if #samples == 0 then
            BaseRegionModel.center = nil
            BaseRegionModel.observedRadius = 0
            BaseRegionModel.effectiveRadius = 0
            BaseRegionModel.confidence = 0
            return
        end

        local sx, sy, sz = 0, 0, 0
        for _,p in ipairs(samples) do
            sx = sx + p.x
            sy = sy + p.y
            sz = sz + p.z
        end

        local center = Vector3.new(sx / #samples, sy / #samples, sz / #samples)
        local radius = 0
        for _,p in ipairs(samples) do
            local v = Vector3.new(p.x, p.y, p.z)
            radius = math.max(radius, distance(center, v))
        end

        BaseRegionModel.center = vectorToTable(center)
        BaseRegionModel.observedRadius = round(radius, 2)
        BaseRegionModel.effectiveRadius = round(
            math.max(CONFIG.BaseRegionMinimumRadius, radius + CONFIG.BaseRegionPadding),
            2
        )
        BaseRegionModel.confidence = round(
            math.min(0.97, 0.20 + (math.min(BaseRegionModel.sampleCount, 60) / 60) * 0.77),
            3
        )
        BaseRegionModel.lastUpdatedAt = elapsed()
    end

    local function addBaseRegionSample(pos)
        if typeof(pos) ~= "Vector3" then return end

        local samples = BaseRegionModel.recentSamples
        local last = samples[#samples]

        if last then
            local lastVector = Vector3.new(last.x, last.y, last.z)
            if distance(lastVector, pos) < 2.5 then
                return
            end
        end

        samples[#samples + 1] = vectorToTable(pos)
        while #samples > CONFIG.BaseRegionMaxSamples do
            table.remove(samples, 1)
        end

        BaseRegionModel.sampleCount = BaseRegionModel.sampleCount + 1
        Statistics.baseRegionSamples = (Statistics.baseRegionSamples or 0) + 1
        recomputeBaseRegion()
    end

    local function baseRegionStatusForPosition(pos)
        if typeof(pos) ~= "Vector3" then return nil, 0, nil end
        if BaseRegionModel.sampleCount < CONFIG.BaseRegionMinSamples then
            return nil, BaseRegionModel.confidence or 0, nil
        end
        if not BaseRegionModel.center then
            return nil, BaseRegionModel.confidence or 0, nil
        end

        local c = BaseRegionModel.center
        local center = Vector3.new(c.x, c.y, c.z)
        local d = distance(pos, center)
        local inside = d <= (BaseRegionModel.effectiveRadius or CONFIG.BaseRegionMinimumRadius)

        return inside, BaseRegionModel.confidence or 0, round(d, 2)
    end

    -- ============================================================
    -- OBJECT SNAPSHOT / IDENTITY
    -- ============================================================

    local function shouldTrackObject(obj)
        if not obj or obj == game then return false end
        if obj:IsA("Terrain") then return true end
        if obj:IsA("Model") or obj:IsA("BasePart") or obj:IsA("Tool") or obj:IsA("Attachment") then return true end
        if obj:IsA("ProximityPrompt") or obj:IsA("ClickDetector") or obj:IsA("DragDetector") then return true end
        if obj:IsA("ValueBase") then return true end
        if obj:IsA("Humanoid") then return true end
        if obj:IsA("Folder") then
            local attrs = getAttributes(obj)
            local tags = getTags(obj)
            return next(attrs) ~= nil or #tags > 0
        end
        local attrs = getAttributes(obj)
        if next(attrs) ~= nil then return true end
        local tags = getTags(obj)
        if #tags > 0 then return true end
        return false
    end

    local function childrenSummary(obj)
        local out = {}
        local ok, children = pcall(function() return obj:GetChildren() end)
        if not ok then return out end
        for i = 1, math.min(#children, CONFIG.MaxChildrenSummary) do
            local child = children[i]
            out[#out + 1] = {name = child.Name, class = child.ClassName}
        end
        return out
    end

    local function promptSnapshot(prompt)
        if not prompt or not prompt:IsA("ProximityPrompt") then return nil end
        return {
            actionText = prompt.ActionText,
            objectText = prompt.ObjectText,
            enabled = prompt.Enabled,
            holdDuration = prompt.HoldDuration,
            maxActivationDistance = prompt.MaxActivationDistance,
            requiresLineOfSight = prompt.RequiresLineOfSight,
            keyboardKeyCode = tostring(prompt.KeyboardKeyCode),
            gamepadKeyCode = tostring(prompt.GamepadKeyCode),
            clickablePrompt = prompt.ClickablePrompt,
        }
    end

    local function valueSnapshot(obj)
        if obj and obj:IsA("ValueBase") then
            local ok, value = pcall(function() return obj.Value end)
            if ok then return safeScalar(value) end
        end
        return nil
    end

    local function makeSignature(obj, pos)
        local parent = obj.Parent
        local parentName = parent and parent.Name or "nil"
        local qx, qy, qz = "?", "?", "?"
        if pos then
            local g = CONFIG.ClusterGrid
            qx = tostring(math.floor(pos.X / g + 0.5))
            qy = tostring(math.floor(pos.Y / g + 0.5))
            qz = tostring(math.floor(pos.Z / g + 0.5))
        end
        return table.concat({obj.ClassName, obj.Name, parentName, qx, qy, qz}, "|")
    end

    local function snapshotObject(obj)
        local pos = getPosition(obj)
        local cf = getCFrame(obj)
        local size = getSize(obj)
        local attrs = getAttributes(obj)
        local tags = getTags(obj)
        local candidates = classifyObject(obj)
        local playerPos = currentPlayerPosition()
        local semanticOwner = semanticOwnerFor(obj)
        local inBaseCandidate, baseConfidence, baseDistance = baseRegionStatusForPosition(pos)

        return {
            name = obj.Name,
            class = obj.ClassName,
            path = safeFullName(obj),
            parentPath = obj.Parent and safeFullName(obj.Parent) or nil,
            position = vectorToTable(pos),
            cframe = cframeToTable(cf),
            size = vectorToTable(size),
            distanceFromPlayer = pos and playerPos and round(distance(pos, playerPos), 2) or nil,

            semanticOwnerPath = semanticOwner and safeFullName(semanticOwner) or nil,
            semanticOwnerClass = semanticOwner and semanticOwner.ClassName or nil,
            semanticOwnerName = semanticOwner and semanticOwner.Name or nil,
            isCanonicalSemanticEntity = semanticOwner == obj,

            objectBaseRegionCandidate = inBaseCandidate,
            objectBaseRegionConfidence = baseConfidence,
            objectDistanceFromLearnedBaseCenter = baseDistance,

            attributes = attrs,
            tags = tags,
            -- Every child is tracked independently, so a full recursive
            -- GetDescendants() count on every BasePart is redundant and very
            -- expensive during map streaming.
            directChildren = (obj:IsA("Model") or obj:IsA("Folder") or obj:IsA("Tool") or obj:IsA("ProximityPrompt"))
                and childrenSummary(obj) or {},
            childCount = #obj:GetChildren(),
            descendantCount = (obj:IsA("Model") or obj:IsA("Folder") or obj:IsA("Tool"))
                and #obj:GetDescendants() or 0,
            prompt = obj:IsA("ProximityPrompt") and promptSnapshot(obj) or nil,
            value = obj:IsA("ValueBase") and valueSnapshot(obj) or nil,
            semanticCandidates = candidates,
            signature = makeSignature(obj, pos),
        }
    end

    local function nextObjectId()
        ObjectCounter = ObjectCounter + 1
        return string.format("O%06d", ObjectCounter)
    end

    local function nextGuiId()
        GuiCounter = GuiCounter + 1
        return string.format("G%06d", GuiCounter)
    end

    local function registerSemanticRecord(runtimeId, candidates, record)
        if not candidates or #candidates == 0 then return end
        SemanticCandidates[runtimeId] = candidates

        for _,c in ipairs(candidates) do
            Statistics.semanticCandidates = Statistics.semanticCandidates + 1
            Statistics.byCategory[c.category] = (Statistics.byCategory[c.category] or 0) + 1

            if isInfrastructureCategory(c.category) then
                BaseInfrastructure[c.category] = BaseInfrastructure[c.category] or {}
                BaseInfrastructure[c.category][runtimeId] = true
                if record and record.isCanonicalSemanticEntity and record.position then
                    BaseRegionModel.anchorIds[runtimeId] = true
                end
            elseif isWorldInfrastructureCategory(c.category) then
                WorldInfrastructure[c.category] = WorldInfrastructure[c.category] or {}
                WorldInfrastructure[c.category][runtimeId] = true
            elseif isLootCategory(c.category) then
                LootContainers[c.category] = LootContainers[c.category] or {}
                LootContainers[c.category][runtimeId] = true
            end

            if c.category == "INTERACTABLE_PROMPT"
                or c.category == "INTERACTABLE_CLICK"
                or c.category == "INTERACTABLE_DRAG"
            then
                Interactables[runtimeId] = true
            end
        end
    end

    local function unregisterSemanticRecord(runtimeId, candidates)
        if not candidates then return end

        for _,c in ipairs(candidates) do
            Statistics.semanticCandidates = math.max(0, (Statistics.semanticCandidates or 0) - 1)
            if Statistics.byCategory[c.category] then
                Statistics.byCategory[c.category] = math.max(0, Statistics.byCategory[c.category] - 1)
            end

            if isInfrastructureCategory(c.category) and BaseInfrastructure[c.category] then
                BaseInfrastructure[c.category][runtimeId] = nil
            elseif isWorldInfrastructureCategory(c.category) and WorldInfrastructure[c.category] then
                WorldInfrastructure[c.category][runtimeId] = nil
            elseif isLootCategory(c.category) and LootContainers[c.category] then
                LootContainers[c.category][runtimeId] = nil
            end
        end

        Interactables[runtimeId] = nil
        BaseRegionModel.anchorIds[runtimeId] = nil
        SemanticCandidates[runtimeId] = nil
    end

    local function semanticFingerprint(candidates)
        local parts = {}
        for _,c in ipairs(candidates or {}) do
            parts[#parts + 1] =
                tostring(c.category) .. ":" .. tostring(round(c.confidence or 0, 3))
        end
        table.sort(parts)
        return table.concat(parts, "|")
    end

    local function refreshSemanticClassification(obj, runtimeId, reason)
        local rec = WorldObjects[runtimeId]
        if not rec or rec.removedAt or not obj or not obj.Parent then return end

        local owner = semanticOwnerFor(obj)
        local newCandidates = classifyObject(obj)
        local oldFingerprint = semanticFingerprint(rec.semanticCandidates)
        local newFingerprint = semanticFingerprint(newCandidates)

        rec.semanticOwnerPath = owner and safeFullName(owner) or nil
        rec.semanticOwnerClass = owner and owner.ClassName or nil
        rec.semanticOwnerName = owner and owner.Name or nil
        rec.isCanonicalSemanticEntity = owner == obj

        if oldFingerprint == newFingerprint then return end

        unregisterSemanticRecord(runtimeId, rec.semanticCandidates or {})
        rec.semanticCandidates = newCandidates
        registerSemanticRecord(runtimeId, newCandidates, rec)

        Statistics.semanticReclassifications =
            (Statistics.semanticReclassifications or 0) + 1

        local encoded = ""
        pcall(function() encoded = HttpService:JSONEncode(newCandidates) end)
        logLine(
            "SEMANTIC_RECLASSIFIED",
            runtimeId,
            "Reason=" .. tostring(reason),
            "Path=" .. safeFullName(obj),
            encoded
        )
    end

    local function maybeUnknown(runtimeId, record)
        if classificationImportant(record.semanticCandidates) then return end
        if tableCount(UnknownObjects) >= CONFIG.MaxUnknownObjects then return end
        if tableCount(record.attributes) > 0 or #(record.tags or {}) > 0 or record.class == "Model" or record.class == "Tool" or record.class == "ProximityPrompt" then
            UnknownObjects[runtimeId] = true
        end
    end

    local function monitorPrompt(prompt, runtimeId)
        if not prompt:IsA("ProximityPrompt") then return end
        Statistics.promptDiscovered = Statistics.promptDiscovered + 1
        local properties = {
            "ActionText", "ObjectText", "Enabled", "HoldDuration",
            "MaxActivationDistance", "RequiresLineOfSight",
            "KeyboardKeyCode", "GamepadKeyCode", "ClickablePrompt",
        }
        for _,prop in ipairs(properties) do
            connectOwned(runtimeId, prompt:GetPropertyChangedSignal(prop):Connect(function()
                if not Running then return end
                local rec = WorldObjects[runtimeId]
                if not rec or rec.removedAt then return end
                local fresh = promptSnapshot(prompt)
                local mapKey = ({
                    ActionText = "actionText", ObjectText = "objectText", Enabled = "enabled",
                    HoldDuration = "holdDuration", MaxActivationDistance = "maxActivationDistance",
                    RequiresLineOfSight = "requiresLineOfSight", KeyboardKeyCode = "keyboardKeyCode",
                    GamepadKeyCode = "gamepadKeyCode", ClickablePrompt = "clickablePrompt",
                })[prop]
                local old = rec.prompt and rec.prompt[mapKey] or nil
                local newValue = fresh and fresh[mapKey] or nil
                rec.prompt = fresh
                rec.lastSeenAt = elapsed()
                Statistics.promptChanges = Statistics.promptChanges + 1
                logLine("PROMPT_CHANGED", runtimeId, safeFullName(prompt), prop, tostring(old), "->", tostring(newValue))

                if prop == "ActionText" or prop == "ObjectText" then
                    refreshSemanticClassification(prompt, runtimeId, "PROMPT_IDENTITY_CHANGE")
                    local owner = semanticOwnerFor(prompt)
                    if owner and owner ~= prompt then
                        local ownerId = RuntimeByInstance[owner]
                        if ownerId then
                            refreshSemanticClassification(owner, ownerId, "CHILD_PROMPT_IDENTITY_CHANGE")
                        end
                    end
                end
            end))
        end
    end

    local function monitorValueObject(obj, runtimeId)
        if not obj:IsA("ValueBase") then return end
        connectOwned(runtimeId, obj.Changed:Connect(function(value)
            if not Running then return end
            local rec = WorldObjects[runtimeId]
            if not rec or rec.removedAt then return end

            local old = rec.value
            local newValue = safeScalar(value)
            rec.value = newValue
            rec.lastSeenAt = elapsed()
            Statistics.valueChanges = Statistics.valueChanges + 1

            local shouldLog = true
            if DEVICE.Mobile and type(old) == "number" and type(newValue) == "number" then
                local t = now()
                rec._lastValueLogAt = rec._lastValueLogAt or 0
                if t - rec._lastValueLogAt < (CONFIG.NumericChangeLogInterval * (MemoryGuard.logMultiplier or 1)) then
                    shouldLog = false
                    Statistics.throttledNumericLogs = (Statistics.throttledNumericLogs or 0) + 1
                else
                    rec._lastValueLogAt = t
                end
            end

            if shouldLog then
                logLine("VALUE_CHANGED", runtimeId, safeFullName(obj), tostring(old), "->", tostring(newValue))
            end
        end))
    end

    local function monitorAttributes(obj, runtimeId)
        connectOwned(runtimeId, obj.AttributeChanged:Connect(function(attributeName)
            if not Running then return end
            local rec = WorldObjects[runtimeId]
            if not rec or rec.removedAt then return end

            local old = rec.attributes and rec.attributes[attributeName] or nil
            local newRaw = obj:GetAttribute(attributeName)
            local newValue = safeScalar(newRaw)

            rec.attributes = rec.attributes or {}
            rec.attributes[attributeName] = newValue
            rec.lastSeenAt = elapsed()
            Statistics.attributeChanges = Statistics.attributeChanges + 1

            local shouldLog = true
            if DEVICE.Mobile and type(old) == "number" and type(newValue) == "number" then
                rec._attributeLogTimes = rec._attributeLogTimes or {}
                local t = now()
                local last = rec._attributeLogTimes[attributeName] or 0
                if t - last < (CONFIG.NumericChangeLogInterval * (MemoryGuard.logMultiplier or 1)) then
                    shouldLog = false
                    Statistics.throttledNumericLogs = (Statistics.throttledNumericLogs or 0) + 1
                else
                    rec._attributeLogTimes[attributeName] = t
                end
            end

            if shouldLog then
                logLine(
                    "OBJECT_ATTRIBUTE_CHANGE",
                    runtimeId,
                    safeFullName(obj),
                    attributeName,
                    tostring(old),
                    "->",
                    tostring(newValue)
                )
            end

            if attributeName == "ToolType"
                or attributeName == "ItemType"
                or attributeName == "Category"
                or attributeName == "Type"
            then
                refreshSemanticClassification(obj, runtimeId, "EXPLICIT_TYPE_ATTRIBUTE_CHANGE")
            end
        end))
    end

    local function registerWorldObject(obj, preexisting)
        if not Running or not obj or not obj.Parent then return nil end
        if RuntimeByInstance[obj] then return RuntimeByInstance[obj] end
        if not shouldTrackObject(obj) then return nil end

        local snapshot = snapshotObject(obj)
        local runtimeId = nextObjectId()
        RuntimeByInstance[obj] = runtimeId
        WorldInstanceByRuntimeId[runtimeId] = obj

        local previous = SignatureHistory[snapshot.signature]
        local reobservedFrom = nil
        if previous and previous.removedAt then
            reobservedFrom = previous.runtimeId
            Statistics.objectsReobserved = Statistics.objectsReobserved + 1
        end

        local record = snapshot
        record.runtimeId = runtimeId
        record.firstObservedAt = elapsed()
        record.lastSeenAt = elapsed()
        record.preexistingAtObserverStart = preexisting == true
        record.observedAfterStart = preexisting ~= true
        record.firstObservedPhase = currentPhase()
        record.firstObservedPlayerNearBase = currentNearBase()
        record.firstObservedNearBase = nil
        record.reobservedFromRuntimeId = reobservedFrom
        record.reobservationCount = reobservedFrom and 1 or 0
        record.removedAt = nil
        record.lastPositionVector = getPosition(obj)
        record.lastTags = arrayCopy(record.tags)
        record.lastAttributes = shallowCopy(record.attributes)
        record.importantForMovement = classificationImportant(record.semanticCandidates) or obj:IsA("Tool") or obj:IsA("Model")
        record.periodicRefresh = record.importantForMovement or #(record.tags or {}) > 0

        if record.periodicRefresh then
            -- runtimeId only: no strong Instance reference.
            PeriodicRefreshList[#PeriodicRefreshList + 1] = {
                runtimeId = runtimeId,
            }
        end

        local resourceCandidate = false
        local okResourceCandidate, resourceCandidateResult = pcall(recordHasResourceCandidate, record)
        if okResourceCandidate then
            resourceCandidate = resourceCandidateResult == true
        else
            reportRuntimeError("RESOURCE_CANDIDATE_CHECK:" .. tostring(runtimeId), resourceCandidateResult)
        end

        if resourceCandidate then
            ResourceClusterDirty = true
        end

        WorldObjects[runtimeId] = record
        SignatureHistory[snapshot.signature] = {runtimeId = runtimeId, removedAt = nil}

        Statistics.objectsObserved = Statistics.objectsObserved + 1
        Statistics.byClass[obj.ClassName] = (Statistics.byClass[obj.ClassName] or 0) + 1
        if record.isCanonicalSemanticEntity then
            Statistics.canonicalEntities = (Statistics.canonicalEntities or 0) + 1
        end
        if preexisting then
            Statistics.objectsPreexistingAtStart = Statistics.objectsPreexistingAtStart + 1
        else
            Statistics.objectsObservedAfterStart = Statistics.objectsObservedAfterStart + 1
        end

        registerSemanticRecord(runtimeId, record.semanticCandidates, record)
        maybeUnknown(runtimeId, record)

        if reobservedFrom then
            logLine("OBJECT_REOBSERVED", runtimeId, "From=" .. tostring(reobservedFrom), obj.ClassName, obj.Name, snapshot.path)
        else
            logLine(
                "OBJECT_FIRST_OBSERVED",
                runtimeId,
                obj.ClassName,
                obj.Name,
                "PreexistingAtStart=" .. boolString(preexisting),
                "Phase=" .. tostring(record.firstObservedPhase),
                "PlayerNearBase=" .. boolString(record.firstObservedPlayerNearBase),
                "ObjectBaseRegion=" .. boolString(record.objectBaseRegionCandidate),
                snapshot.path
            )
        end

        if #record.semanticCandidates > 0 then
            local encoded = ""
            pcall(function() encoded = HttpService:JSONEncode(record.semanticCandidates) end)
            logLine("SEMANTIC_CANDIDATE", runtimeId, encoded)
        end

        if obj:IsA("ProximityPrompt") then
            local encoded = ""
            pcall(function() encoded = HttpService:JSONEncode(record.prompt or {}) end)
            logLine("PROMPT_DISCOVERED", runtimeId, snapshot.path, encoded)
            monitorPrompt(obj, runtimeId)
        end

        monitorValueObject(obj, runtimeId)
        monitorAttributes(obj, runtimeId)

        return runtimeId
    end

    local function markWorldObjectRemoved(obj)
        local runtimeId = RuntimeByInstance[obj]
        if not runtimeId then return end
        local rec = WorldObjects[runtimeId]
        if not rec or rec.removedAt then return end
        rec.removedAt = elapsed()
        rec.lastSeenAt = elapsed()
        Statistics.objectsRemoved = Statistics.objectsRemoved + 1
        local okResourceCandidate, isResource = pcall(recordHasResourceCandidate, rec)
        if okResourceCandidate and isResource then
            ResourceClusterDirty = true
        elseif not okResourceCandidate then
            reportRuntimeError("RESOURCE_REMOVE_CHECK:" .. tostring(runtimeId), isResource)
        end
        if rec.signature then
            SignatureHistory[rec.signature] = {runtimeId = runtimeId, removedAt = rec.removedAt}
        end

        -- Release observer-side references immediately when streaming removes
        -- an object. This is the most important memory-leak prevention step.
        disconnectOwned(ObjectConnectionsByRuntimeId, runtimeId)
        WorldInstanceByRuntimeId[runtimeId] = nil
        RuntimeByInstance[obj] = nil

        logLine("OBJECT_LOST_FROM_OBSERVATION", runtimeId, rec.class, rec.name, rec.path)
    end

    local function refreshWorldObject(obj, runtimeId)
        local rec = WorldObjects[runtimeId]
        if not rec or rec.removedAt or not obj.Parent then return end

        rec.lastSeenAt = elapsed()

        local previousPath = rec.path
        local currentPath = safeFullName(obj)
        rec.path = currentPath
        rec.parentPath = obj.Parent and safeFullName(obj.Parent) or nil

        if CONFIG.ReclassifyOnPathChange and previousPath ~= currentPath then
            refreshSemanticClassification(obj, runtimeId, "PATH_OR_PARENT_CHANGED")
        end

        local pos = getPosition(obj)
        local playerPos = currentPlayerPosition()
        rec.distanceFromPlayer = pos and playerPos and round(distance(pos, playerPos), 2) or nil

        if pos then
            if rec.lastPositionVector then
                local d = distance(pos, rec.lastPositionVector)
                if rec.importantForMovement and d >= CONFIG.ImportantMoveDistance then
                    Statistics.objectsMoved = Statistics.objectsMoved + 1
                    local okResourceCandidate, isResource = pcall(recordHasResourceCandidate, rec)
                    if okResourceCandidate and isResource then
                        ResourceClusterDirty = true
                    elseif not okResourceCandidate then
                        reportRuntimeError("RESOURCE_MOVE_CHECK:" .. tostring(runtimeId), isResource)
                    end
                    logLine(
                        "OBJECT_MOVED",
                        runtimeId,
                        rec.name,
                        "Distance=" .. tostring(round(d, 2)),
                        string.format("To=%.1f,%.1f,%.1f", pos.X, pos.Y, pos.Z)
                    )
                end
            end
            rec.lastPositionVector = pos
            rec.position = vectorToTable(pos)
            rec.cframe = cframeToTable(getCFrame(obj))

            local inBase, baseConfidence, baseDistance = baseRegionStatusForPosition(pos)
            rec.objectBaseRegionCandidate = inBase
            rec.objectBaseRegionConfidence = baseConfidence
            rec.objectDistanceFromLearnedBaseCenter = baseDistance
        end

        local newTags = getTags(obj)
        if not arraysEqual(newTags, rec.lastTags or {}) then
            local oldTags = rec.lastTags or {}
            rec.tags = newTags
            rec.lastTags = arrayCopy(newTags)
            local a, b = "", ""
            pcall(function() a = HttpService:JSONEncode(oldTags) end)
            pcall(function() b = HttpService:JSONEncode(newTags) end)
            logLine("OBJECT_TAGS_CHANGED", runtimeId, a, "->", b)
        end

    end

    -- ============================================================
    -- GUI DISCOVERY - PASSIVE ONLY
    -- ============================================================

    local function shouldTrackGui(obj)
        if not (obj:IsA("ScreenGui") or obj:IsA("GuiObject")) then
            return false
        end

        if MobileGui and (obj == MobileGui or obj:IsDescendantOf(MobileGui)) then
            return false
        end

        local cursor = obj
        local depth = 0
        while cursor and depth < 12 do
            if cursor.Name == "STA_STAGE1_MOBILE_CONTROL" then
                return false
            end
            cursor = cursor.Parent
            depth = depth + 1
        end

        return true
    end

    local function guiSnapshot(obj)
        local out = {
            name = obj.Name,
            class = obj.ClassName,
            path = safeFullName(obj),
            parentPath = obj.Parent and safeFullName(obj.Parent) or nil,
        }
        if obj:IsA("ScreenGui") then
            out.enabled = obj.Enabled
            out.displayOrder = obj.DisplayOrder
        end
        if obj:IsA("GuiObject") then
            out.visible = obj.Visible
            out.active = obj.Active
            out.position = udim2ToTable(obj.Position)
            out.size = udim2ToTable(obj.Size)
            out.zIndex = obj.ZIndex
            if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
                out.text = obj.Text
            end
        end
        return out
    end

    local function registerGui(obj, preexisting)
        if not Running or not obj or not obj.Parent or not shouldTrackGui(obj) then return end
        if GuiRuntimeByInstance[obj] then return end

        local runtimeId = nextGuiId()
        GuiRuntimeByInstance[obj] = runtimeId
        GuiInstanceByRuntimeId[runtimeId] = obj
        local rec = guiSnapshot(obj)
        rec.runtimeId = runtimeId
        rec.firstObservedAt = elapsed()
        rec.lastSeenAt = elapsed()
        rec.preexistingAtObserverStart = preexisting == true
        rec.observedAfterStart = preexisting ~= true
        rec.removedAt = nil
        GuiObjects[runtimeId] = rec
        Statistics.guiObserved = Statistics.guiObserved + 1

        logLine("GUI_DISCOVERED", runtimeId, rec.class, rec.path, "PreexistingAtStart=" .. boolString(preexisting))

        local function propertyWatcher(prop, key)
            connectGuiOwned(runtimeId, obj:GetPropertyChangedSignal(prop):Connect(function()
                if not Running then return end
                local r = GuiObjects[runtimeId]
                if not r or r.removedAt then return end

                local old = r[key]
                local fresh = guiSnapshot(obj)
                local newValue = fresh[key]
                r[key] = newValue
                r.lastSeenAt = elapsed()
                Statistics.guiChanges = Statistics.guiChanges + 1

                local shouldLog = true
                if DEVICE.Mobile and prop == "Text" then
                    local t = now()
                    r._lastTextLogAt = r._lastTextLogAt or 0
                    if t - r._lastTextLogAt < (CONFIG.GuiTextLogInterval * (MemoryGuard.logMultiplier or 1)) then
                        shouldLog = false
                        Statistics.throttledGuiTextLogs = (Statistics.throttledGuiTextLogs or 0) + 1
                    else
                        r._lastTextLogAt = t
                    end
                end

                if shouldLog then
                    logLine("GUI_CHANGED", runtimeId, rec.path, prop, tostring(old), "->", tostring(newValue))
                end
            end))
        end

        if obj:IsA("ScreenGui") then
            propertyWatcher("Enabled", "enabled")
        end
        if obj:IsA("GuiObject") then
            propertyWatcher("Visible", "visible")
            if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
                propertyWatcher("Text", "text")
            end
        end
    end

    local function markGuiRemoved(obj)
        local runtimeId = GuiRuntimeByInstance[obj]
        if not runtimeId then return end
        local rec = GuiObjects[runtimeId]
        if rec and not rec.removedAt then
            rec.removedAt = elapsed()
            rec.lastSeenAt = elapsed()

            disconnectOwned(GuiConnectionsByRuntimeId, runtimeId)
            GuiInstanceByRuntimeId[runtimeId] = nil
            GuiRuntimeByInstance[obj] = nil

            logLine("GUI_LOST_FROM_OBSERVATION", runtimeId, rec.path)
        end
    end

    -- ============================================================
    -- RESOURCE CLUSTER LEARNING
    -- ============================================================

    local function clusterKey(category, center)
        local g = CONFIG.ClusterGrid
        local qx = math.floor(center.X / g + 0.5)
        local qy = math.floor(center.Y / g + 0.5)
        local qz = math.floor(center.Z / g + 0.5)
        return table.concat({category, qx, qy, qz}, "|")
    end

    local function candidateHasCategory(rec, category)
        for _,c in ipairs(rec.semanticCandidates or {}) do
            if c.category == category and c.confidence >= 0.45 then return true end
        end
        return false
    end


    local function currentResourcePoints()
        local byCategory = {}
        for runtimeId, rec in pairs(WorldObjects) do
            if not rec.removedAt
                and rec.position
                and rec.isCanonicalSemanticEntity == true
                and type(rec.path) == "string"
                and string.sub(rec.path, 1, 10) == "Workspace."
            then
                local pos = Vector3.new(rec.position.x, rec.position.y, rec.position.z)
                for _,c in ipairs(rec.semanticCandidates or {}) do
                    if isResourceCategory(c.category) and c.confidence >= 0.45 then
                        byCategory[c.category] = byCategory[c.category] or {}
                        byCategory[c.category][#byCategory[c.category] + 1] = {
                            runtimeId = runtimeId,
                            position = pos,
                            confidence = c.confidence,
                            name = rec.name,
                        }
                    end
                end
            end
        end
        return byCategory
    end

    local function buildClusters(points)
        local clusters = {}
        local used = {}
        for i = 1, #points do
            if not used[i] then
                local members = {points[i]}
                used[i] = true
                local changed = true
                while changed do
                    changed = false
                    local cx, cy, cz = 0, 0, 0
                    for _,m in ipairs(members) do
                        cx = cx + m.position.X
                        cy = cy + m.position.Y
                        cz = cz + m.position.Z
                    end
                    local center = Vector3.new(cx / #members, cy / #members, cz / #members)
                    for j = 1, #points do
                        if not used[j] and distance(points[j].position, center) <= CONFIG.ClusterDistance then
                            members[#members + 1] = points[j]
                            used[j] = true
                            changed = true
                        end
                    end
                end
                local cx, cy, cz = 0, 0, 0
                for _,m in ipairs(members) do
                    cx = cx + m.position.X
                    cy = cy + m.position.Y
                    cz = cz + m.position.Z
                end
                local center = Vector3.new(cx / #members, cy / #members, cz / #members)
                local radius = 0
                for _,m in ipairs(members) do
                    radius = math.max(radius, distance(m.position, center))
                end
                clusters[#clusters + 1] = {center = center, radius = radius, members = members}
            end
        end
        return clusters
    end

    local function updateResourceClusters()
        local resourcePoints = currentResourcePoints()

        for category, points in pairs(resourcePoints) do
            local clusters = buildClusters(points)
            for _,cluster in ipairs(clusters) do
                local key = clusterKey(category, cluster.center)
                local rec = ResourceClusters[key]
                local memberIds = {}
                for _,m in ipairs(cluster.members) do memberIds[#memberIds + 1] = m.runtimeId end
                table.sort(memberIds)

                if not rec then
                    ClusterCounter = ClusterCounter + 1
                    rec = {
                        clusterId = string.format("C%05d", ClusterCounter),
                        key = key,
                        category = category,
                        firstSeenAt = elapsed(),
                        lastSeenAt = elapsed(),
                        observations = 0,
                        maxCount = 0,
                        lastCount = 0,
                        center = vectorToTable(cluster.center),
                        radius = round(cluster.radius, 2),
                        lastMembers = {},
                        observedInsideLearnedBaseRegion = 0,
                        observedOutsideLearnedBaseRegion = 0,
                        baseRegionUnknownObservations = 0,
                        centerHistory = {},
                        semanticRoleCandidate = nil,
                        semanticRoleConfidence = 0,
                    }
                    ResourceClusters[key] = rec
                    Statistics.resourceClustersCreated = Statistics.resourceClustersCreated + 1
                    logLine("RESOURCE_CLUSTER_CREATED", rec.clusterId, category, "Count=" .. tostring(#cluster.members), string.format("Center=%.1f,%.1f,%.1f", cluster.center.X, cluster.center.Y, cluster.center.Z))
                end

                rec.observations = rec.observations + 1
                rec.lastSeenAt = elapsed()
                rec.maxCount = math.max(rec.maxCount or 0, #cluster.members)
                rec.center = vectorToTable(cluster.center)
                rec.radius = round(cluster.radius, 2)
                local insideBase, baseConfidence, baseDistance =
                    baseRegionStatusForPosition(cluster.center)

                if insideBase == true then
                    rec.observedInsideLearnedBaseRegion =
                        rec.observedInsideLearnedBaseRegion + 1
                elseif insideBase == false then
                    rec.observedOutsideLearnedBaseRegion =
                        rec.observedOutsideLearnedBaseRegion + 1
                else
                    rec.baseRegionUnknownObservations =
                        rec.baseRegionUnknownObservations + 1
                end

                rec.insideLearnedBaseRegion = insideBase
                rec.baseRegionConfidence = baseConfidence
                rec.distanceFromLearnedBaseCenter = baseDistance

                rec.centerHistory[#rec.centerHistory + 1] = {
                    t = elapsed(),
                    center = vectorToTable(cluster.center),
                    count = #cluster.members,
                    insideLearnedBaseRegion = insideBase,
                    baseRegionConfidence = baseConfidence,
                }
                while #rec.centerHistory > CONFIG.MaxClusterHistory do
                    table.remove(rec.centerHistory, 1)
                end

                local knownContext =
                    rec.observedInsideLearnedBaseRegion
                    + rec.observedOutsideLearnedBaseRegion

                local insideRatio =
                    knownContext > 0
                    and (rec.observedInsideLearnedBaseRegion / knownContext)
                    or 0

                if rec.maxCount >= 3
                    and rec.observations >= 3
                    and knownContext >= 2
                    and insideRatio >= 0.65
                    and (rec.baseRegionConfidence or 0) >= 0.35
                then
                    local roleConfidence =
                        0.30
                        + math.min(0.20, rec.observations * 0.015)
                        + math.min(0.20, rec.maxCount * 0.02)
                        + math.min(0.15, insideRatio * 0.15)
                        + math.min(0.10, (rec.baseRegionConfidence or 0) * 0.10)

                    rec.semanticRoleCandidate =
                        string.gsub(category, "RESOURCE_", "")
                        .. "_STORAGE_CANDIDATE"

                    rec.semanticRoleConfidence =
                        round(math.min(0.92, roleConfidence), 3)
                end

                local changedCount = rec.lastCount ~= #cluster.members
                local changedMembers = not arraysEqual(rec.lastMembers or {}, memberIds)
                if rec.observations > 1 and (changedCount or changedMembers) then
                    Statistics.resourceClusterUpdates = Statistics.resourceClusterUpdates + 1
                    logLine(
                        "RESOURCE_CLUSTER_UPDATED",
                        rec.clusterId,
                        category,
                        "Count=" .. tostring(rec.lastCount) .. "->" .. tostring(#cluster.members),
                        "Role=" .. tostring(rec.semanticRoleCandidate),
                        "RoleConfidence=" .. tostring(rec.semanticRoleConfidence)
                    )
                end

                rec.lastCount = #cluster.members
                rec.lastMembers = memberIds
            end
        end
    end

    -- ============================================================
    -- PLAYER / ENVIRONMENT CONTEXT
    -- ============================================================

    local function updateContext()
        local phase = currentPhase()
        local nearBase = currentNearBase()
        local pos = currentPlayerPosition()
        local day, daySource = currentDay()
        local highestDay = currentHighestDayRecord()

        if CurrentContext.phase ~= nil and CurrentContext.phase ~= phase then
            logLine(
                "TIME_PHASE_CHANGE",
                tostring(CurrentContext.phase),
                "->",
                tostring(phase),
                "Day=" .. tostring(day),
                "DaySource=" .. tostring(daySource)
            )
        end

        if CurrentContext.nearBase ~= nil and CurrentContext.nearBase ~= nearBase then
            logLine(
                "PLAYER_NEAR_BASE_CHANGE",
                tostring(CurrentContext.nearBase),
                "->",
                tostring(nearBase)
            )
        end

        if CurrentContext.day ~= nil and day ~= nil and CurrentContext.day ~= day then
            logLine(
                "DAY_COUNTER_CHANGE",
                tostring(CurrentContext.day),
                "->",
                tostring(day),
                "Source=" .. tostring(daySource)
            )
        end

        if nearBase == true and pos then
            addBaseRegionSample(pos)
        end

        CurrentContext.phase = phase
        CurrentContext.nearBase = nearBase
        CurrentContext.playerPosition = vectorToTable(pos)
        CurrentContext.day = day
        CurrentContext.daySource = daySource
        CurrentContext.highestDayRecord = highestDay
    end

    -- ============================================================
    -- MEMORY BUILD / SAVE
    -- ============================================================

    local function sanitizeWorldObjects()
        local out = {}
        for id,rec in pairs(WorldObjects) do
            local copy = {}
            for k,v in pairs(rec) do
                if k ~= "lastPositionVector"
                    and k ~= "lastTags"
                    and k ~= "lastAttributes"
                    and k ~= "importantForMovement"
                    and k ~= "periodicRefresh"
                    and k ~= "_lastValueLogAt"
                    and k ~= "_attributeLogTimes"
                then
                    copy[k] = v
                end
            end
            out[id] = copy
        end
        return out
    end

    local function indexSetToArray(index)
        local out = {}
        for category, ids in pairs(index or {}) do
            out[category] = {}
            for id,_ in pairs(ids) do out[category][#out[category] + 1] = id end
            table.sort(out[category])
        end
        return out
    end

    local function idSetToArray(set)
        local out = {}
        for id,_ in pairs(set or {}) do out[#out + 1] = id end
        table.sort(out)
        return out
    end

    local JsonSanitizeStats = {
        converted = 0,
        nonFiniteNumbers = 0,
        unsupportedValues = 0,
        cycles = 0,
        keyConversions = 0,
        tableShapeConversions = 0,
        keyCollisions = 0,
        samples = {},
    }

    local function resetJsonSanitizeStats()
        JsonSanitizeStats.converted = 0
        JsonSanitizeStats.nonFiniteNumbers = 0
        JsonSanitizeStats.unsupportedValues = 0
        JsonSanitizeStats.cycles = 0
        JsonSanitizeStats.keyConversions = 0
        JsonSanitizeStats.tableShapeConversions = 0
        JsonSanitizeStats.keyCollisions = 0
        JsonSanitizeStats.samples = {}
    end

    local function recordJsonSanitize(path, kind, detail)
        JsonSanitizeStats.converted = JsonSanitizeStats.converted + 1
        if kind == "NON_FINITE" then
            JsonSanitizeStats.nonFiniteNumbers = JsonSanitizeStats.nonFiniteNumbers + 1
        elseif kind == "CYCLE" then
            JsonSanitizeStats.cycles = JsonSanitizeStats.cycles + 1
        elseif kind == "KEY" then
            JsonSanitizeStats.keyConversions = JsonSanitizeStats.keyConversions + 1
        elseif kind == "TABLE_SHAPE" then
            JsonSanitizeStats.tableShapeConversions = JsonSanitizeStats.tableShapeConversions + 1
        elseif kind == "KEY_COLLISION" then
            JsonSanitizeStats.keyCollisions = JsonSanitizeStats.keyCollisions + 1
        else
            JsonSanitizeStats.unsupportedValues = JsonSanitizeStats.unsupportedValues + 1
        end
        if #JsonSanitizeStats.samples < 25 then
            JsonSanitizeStats.samples[#JsonSanitizeStats.samples + 1] = {
                path = tostring(path),
                kind = tostring(kind),
                detail = tostring(detail),
            }
        end
    end

    local function isFiniteNumber(v)
        return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
    end

    local function isDenseArrayTable(t)
        local count = 0
        local maxIndex = 0

        for k,_ in pairs(t) do
            if type(k) ~= "number" then
                return false, 0
            end
            if k < 1 or k % 1 ~= 0 then
                return false, 0
            end
            count = count + 1
            if k > maxIndex then maxIndex = k end
        end

        if count == 0 then
            return false, 0
        end

        if maxIndex ~= count then
            return false, maxIndex
        end

        for i = 1, maxIndex do
            if rawget(t, i) == nil then
                return false, maxIndex
            end
        end

        return true, maxIndex
    end

    local function jsonObjectKey(k)
        local kt = type(k)

        if kt == "string" then
            return k
        elseif kt == "number" then
            -- Prefix numeric dictionary keys so 1 and "1" cannot collide.
            if k == k and k ~= math.huge and k ~= -math.huge then
                return "#NUM:" .. tostring(k)
            end
            return "#NUM:<NON_FINITE>"
        elseif kt == "boolean" then
            return "#BOOL:" .. tostring(k)
        end

        local tv = typeof(k)
        if tv == "Instance" then
            return "#INSTANCE:" .. safeFullName(k)
        end

        return "#KEY:" .. tostring(tv) .. ":" .. tostring(k)
    end

    local function jsonSafe(value, path, seen)
        path = path or "$"
        seen = seen or {}

        local tv = typeof(value)

        if tv == "nil" or tv == "boolean" or tv == "string" then
            return value
        end

        if tv == "number" then
            if isFiniteNumber(value) then return value end

            local replacement
            if value ~= value then
                replacement = "<NON_FINITE:NaN>"
            elseif value == math.huge then
                replacement = "<NON_FINITE:+INF>"
            else
                replacement = "<NON_FINITE:-INF>"
            end

            recordJsonSanitize(path, "NON_FINITE", replacement)
            return replacement
        end

        if tv == "Vector3" then
            recordJsonSanitize(path, "ROBLOX_TYPE", "Vector3")
            return {
                x = jsonSafe(value.X, path .. ".x", seen),
                y = jsonSafe(value.Y, path .. ".y", seen),
                z = jsonSafe(value.Z, path .. ".z", seen),
            }
        elseif tv == "Vector2" then
            recordJsonSanitize(path, "ROBLOX_TYPE", "Vector2")
            return {
                x = jsonSafe(value.X, path .. ".x", seen),
                y = jsonSafe(value.Y, path .. ".y", seen),
            }
        elseif tv == "CFrame" then
            recordJsonSanitize(path, "ROBLOX_TYPE", "CFrame")
            local components = {value:GetComponents()}
            local out = {}
            for i,v in ipairs(components) do
                out[i] = jsonSafe(v, path .. "[" .. tostring(i) .. "]", seen)
            end
            return out
        elseif tv == "Color3" then
            recordJsonSanitize(path, "ROBLOX_TYPE", "Color3")
            return {
                r = jsonSafe(value.R, path .. ".r", seen),
                g = jsonSafe(value.G, path .. ".g", seen),
                b = jsonSafe(value.B, path .. ".b", seen),
            }
        elseif tv == "UDim" then
            recordJsonSanitize(path, "ROBLOX_TYPE", "UDim")
            return {
                scale = jsonSafe(value.Scale, path .. ".scale", seen),
                offset = jsonSafe(value.Offset, path .. ".offset", seen),
            }
        elseif tv == "UDim2" then
            recordJsonSanitize(path, "ROBLOX_TYPE", "UDim2")
            return {
                xScale = jsonSafe(value.X.Scale, path .. ".xScale", seen),
                xOffset = jsonSafe(value.X.Offset, path .. ".xOffset", seen),
                yScale = jsonSafe(value.Y.Scale, path .. ".yScale", seen),
                yOffset = jsonSafe(value.Y.Offset, path .. ".yOffset", seen),
            }
        elseif tv == "BrickColor" or tv == "EnumItem" or tv == "NumberRange"
            or tv == "NumberSequence" or tv == "ColorSequence"
            or tv == "Rect" or tv == "Ray"
        then
            recordJsonSanitize(path, "ROBLOX_TYPE", tv)
            return tostring(value)
        elseif tv == "Instance" then
            recordJsonSanitize(path, "ROBLOX_TYPE", "Instance")
            return {
                instancePath = safeFullName(value),
                class = tostring(value.ClassName),
                name = tostring(value.Name),
            }
        end

        if type(value) == "table" then
            if seen[value] then
                recordJsonSanitize(path, "CYCLE", "cyclic table reference")
                return "<CYCLE>"
            end

            seen[value] = true

            local denseArray, arrayLength = isDenseArrayTable(value)

            if denseArray then
                local out = {}
                for i = 1, arrayLength do
                    out[i] = jsonSafe(value[i], path .. "[" .. tostring(i) .. "]", seen)
                end
                seen[value] = nil
                return out
            end

            -- JSON objects must have string keys. Any sparse/mixed/numeric
            -- dictionary is normalized into a pure string-key object.
            local out = {}
            local hadNonStringKey = false
            local keyCount = 0

            for k,v in pairs(value) do
                keyCount = keyCount + 1
                local safeKey = jsonObjectKey(k)

                if type(k) ~= "string" then
                    hadNonStringKey = true
                    recordJsonSanitize(
                        path,
                        "KEY",
                        "converted key type=" .. type(k) .. " -> " .. safeKey
                    )
                end

                local originalSafeKey = safeKey
                local suffix = 1
                while out[safeKey] ~= nil do
                    suffix = suffix + 1
                    safeKey = originalSafeKey .. "#DUP" .. tostring(suffix)
                end

                if safeKey ~= originalSafeKey then
                    recordJsonSanitize(
                        path,
                        "KEY_COLLISION",
                        originalSafeKey .. " -> " .. safeKey
                    )
                end

                local childPath = path .. "." .. safeKey
                out[safeKey] = jsonSafe(v, childPath, seen)
            end

            if hadNonStringKey then
                recordJsonSanitize(
                    path,
                    "TABLE_SHAPE",
                    "normalized dictionary keys; entries=" .. tostring(keyCount)
                )
            end

            seen[value] = nil
            return out
        end

        recordJsonSanitize(path, "UNSUPPORTED", tv .. "/" .. type(value))
        return "<UNSUPPORTED:" .. tostring(tv) .. ">"
    end


    -- Pure-Lua fallback encoder.
    -- It only receives values after jsonSafe(), so it encodes primitives,
    -- dense arrays and string-key objects.
    local function unicodeEscape(codepoint)
        if codepoint <= 0xFFFF then
            return string.format("\\u%04X", codepoint)
        end

        local cp = codepoint - 0x10000
        local high = 0xD800 + math.floor(cp / 0x400)
        local low = 0xDC00 + (cp % 0x400)
        return string.format("\\u%04X\\u%04X", high, low)
    end

    local function jsonEscapeString(s)
        s = tostring(s)
        local out = {'"'}
        local i = 1
        local len = #s

        while i <= len do
            local b1 = string.byte(s, i)

            if b1 < 0x80 then
                if b1 == 0x22 then
                    out[#out + 1] = '\\"'
                elseif b1 == 0x5C then
                    out[#out + 1] = "\\\\"
                elseif b1 == 0x08 then
                    out[#out + 1] = "\\b"
                elseif b1 == 0x0C then
                    out[#out + 1] = "\\f"
                elseif b1 == 0x0A then
                    out[#out + 1] = "\\n"
                elseif b1 == 0x0D then
                    out[#out + 1] = "\\r"
                elseif b1 == 0x09 then
                    out[#out + 1] = "\\t"
                elseif b1 < 0x20 then
                    out[#out + 1] = string.format("\\u%04X", b1)
                else
                    out[#out + 1] = string.char(b1)
                end
                i = i + 1
            else
                local cp = nil
                local consumed = 1

                if b1 >= 0xC2 and b1 <= 0xDF and i + 1 <= len then
                    local b2 = string.byte(s, i + 1)
                    if b2 >= 0x80 and b2 <= 0xBF then
                        cp = (b1 - 0xC0) * 0x40 + (b2 - 0x80)
                        consumed = 2
                    end
                elseif b1 >= 0xE0 and b1 <= 0xEF and i + 2 <= len then
                    local b2 = string.byte(s, i + 1)
                    local b3 = string.byte(s, i + 2)
                    local validB2 =
                        b2 >= 0x80 and b2 <= 0xBF
                        and not (b1 == 0xE0 and b2 < 0xA0)
                        and not (b1 == 0xED and b2 > 0x9F)

                    if validB2 and b3 >= 0x80 and b3 <= 0xBF then
                        cp =
                            (b1 - 0xE0) * 0x1000
                            + (b2 - 0x80) * 0x40
                            + (b3 - 0x80)
                        consumed = 3
                    end
                elseif b1 >= 0xF0 and b1 <= 0xF4 and i + 3 <= len then
                    local b2 = string.byte(s, i + 1)
                    local b3 = string.byte(s, i + 2)
                    local b4 = string.byte(s, i + 3)
                    local validB2 =
                        b2 >= 0x80 and b2 <= 0xBF
                        and not (b1 == 0xF0 and b2 < 0x90)
                        and not (b1 == 0xF4 and b2 > 0x8F)

                    if validB2
                        and b3 >= 0x80 and b3 <= 0xBF
                        and b4 >= 0x80 and b4 <= 0xBF
                    then
                        cp =
                            (b1 - 0xF0) * 0x40000
                            + (b2 - 0x80) * 0x1000
                            + (b3 - 0x80) * 0x40
                            + (b4 - 0x80)
                        consumed = 4
                    end
                end

                if cp then
                    out[#out + 1] = unicodeEscape(cp)
                    i = i + consumed
                else
                    out[#out + 1] = "\\uFFFD"
                    Statistics.invalidUtf8BytesReplaced =
                        (Statistics.invalidUtf8BytesReplaced or 0) + 1
                    i = i + 1
                end
            end
        end

        out[#out + 1] = '"'
        return table.concat(out)
    end

    local function customJsonEncode(value, seen)
        seen = seen or {}

        local tv = type(value)

        if tv == "nil" then
            return "null"
        elseif tv == "boolean" then
            return value and "true" or "false"
        elseif tv == "number" then
            if not isFiniteNumber(value) then
                return jsonEscapeString("<NON_FINITE>")
            end
            return tostring(value)
        elseif tv == "string" then
            return jsonEscapeString(value)
        elseif tv ~= "table" then
            return jsonEscapeString("<UNSUPPORTED:" .. tv .. ">")
        end

        if seen[value] then
            return jsonEscapeString("<CYCLE>")
        end
        seen[value] = true

        local denseArray, arrayLength = isDenseArrayTable(value)
        local parts = {}

        if denseArray then
            for i = 1, arrayLength do
                parts[#parts + 1] = customJsonEncode(value[i], seen)
            end
            seen[value] = nil
            return "[" .. table.concat(parts, ",") .. "]"
        end

        -- jsonSafe() guarantees dictionary keys are strings here.
        local keys = {}
        for k,_ in pairs(value) do
            keys[#keys + 1] = tostring(k)
        end
        table.sort(keys)

        for _,k in ipairs(keys) do
            parts[#parts + 1] =
                jsonEscapeString(k)
                .. ":"
                .. customJsonEncode(value[k], seen)
        end

        seen[value] = nil
        return "{" .. table.concat(parts, ",") .. "}"
    end

    local function encodeSanitizedPayload(safePayload, purpose)
        local encoded = nil
        local encoderUsed = nil

        if not EXECUTOR.forceCustomJson then
            local okNative, nativeOrErr = pcall(function()
                return HttpService:JSONEncode(safePayload)
            end)

            if okNative and type(nativeOrErr) == "string" then
                encoded = nativeOrErr
                encoderUsed = "HttpService.JSONEncode"
            else
                addExecutorWarning(
                    "Native JSON rejected sanitized payload: "
                    .. tostring(nativeOrErr)
                )
            end
        end

        if not encoded then
            local okCustom, customOrErr = pcall(function()
                return customJsonEncode(safePayload, {})
            end)

            if not okCustom or type(customOrErr) ~= "string" then
                return false, nil, nil,
                    "CUSTOM_JSON_ENCODER | " .. tostring(customOrErr)
            end

            encoded = customOrErr
            encoderUsed = "CUSTOM_JSON_ENCODER"

            if CONFIG.ValidateEveryCustomJsonSave
                and type(HttpService.JSONDecode) == "function"
            then
                local okDecode, decodeErr = pcall(function()
                    HttpService:JSONDecode(encoded)
                end)

                if not okDecode then
                    return false, nil, nil,
                        "CUSTOM_JSON_VALIDATION | " .. tostring(decodeErr)
                end
            end
        end

        return true, encoded, encoderUsed, nil
    end

    local function writeVerifiedFile(path, content)
        if not canWrite then
            return false, "writefile unavailable"
        end

        local okWrite, writeErr = pcall(function()
            writefile(path, content)
        end)

        if not okWrite then
            return false, "WRITEFILE | " .. tostring(writeErr)
        end

        if type(isfile) == "function" then
            local okExists, exists = pcall(function()
                return isfile(path)
            end)
            if not okExists or exists ~= true then
                return false, "ISFILE_VERIFY | " .. tostring(exists)
            end
        end

        if type(readfile) == "function" then
            local okRead, readBack = pcall(function()
                return readfile(path)
            end)

            if not okRead then
                return false, "READFILE_VERIFY | " .. tostring(readBack)
            end

            if type(readBack) ~= "string" then
                return false, "READFILE_VERIFY_TYPE | " .. type(readBack)
            end

            if #readBack ~= #content then
                return false,
                    "READFILE_VERIFY_SIZE | expected="
                    .. tostring(#content)
                    .. " actual="
                    .. tostring(#readBack)
            end
        end

        return true, "verified bytes=" .. tostring(#content)
    end

    local function buildMemory()
        return {
            schema = SCHEMA,
            version = VERSION,
            stage = 1,
            totalStages = 8,
            mode = "PASSIVE_READ_ONLY",
            sessionUnix = SessionUnix,
            sessionDuration = elapsed(),
            logFile = LOG_FILE,
            memoryFile = MEMORY_FILE,
            player = {
                userId = LocalPlayer.UserId,
                name = LocalPlayer.Name,
            },
            executorProfile = EXECUTOR,
            targetedGuiState = TargetedGuiState,
            currentContext = CurrentContext,
            statistics = Statistics,
            worldObjects = sanitizeWorldObjects(),
            semanticCandidates = SemanticCandidates,
            resourceClusters = ResourceClusters,
            archivedWorldEntities = ArchivedWorldEntities,
            memoryGuard = MemoryGuard,
            baseRegionModel = BaseRegionModel,
            baseInfrastructure = indexSetToArray(BaseInfrastructure),
            worldInfrastructure = indexSetToArray(WorldInfrastructure),
            lootContainers = indexSetToArray(LootContainers),
            interactables = idSetToArray(Interactables),
            unknownObjects = idSetToArray(UnknownObjects),
            guiObjects = GuiObjects,
            semanticRules = {
                descendantAddedMeans = "FIRST_OBSERVED_NOT_CONFIRMED_SPAWN",
                classificationMeans = "CANDIDATE_NOT_PROOF",
                storageClustersMean = "LOCATION_CANDIDATE_NOT_CONFIRMED_STORAGE",
                objectBaseRegionMeans = "SPATIAL_CANDIDATE_FROM_LEARNED_NEARBASE_REGION",
                firstObservedPlayerNearBaseMeans = "PLAYER_CONTEXT_NOT_OBJECT_LOCATION",
                canonicalEntityRule = "RESOURCE_LOOT_INFRA_CATEGORIES_ASSIGNED_TO_CANONICAL_ENTITY_ONLY",
                dayRule = "TopUI.DayCounter_PRIMARY_HighestDay_FALLBACK_ONLY",
                memoryGuardRule = "OBSERVER_ONLY_THROTTLE_AND_RETENTION_NEVER_GAME_CONTROL",
                archivedEntityRule = "COMPACT_HISTORY_FOR_PRUNED_SEMANTICALLY_USEFUL_REMOVED_OBJECTS",
                executorCompatibilityRule = "AUTO_PROFILE_POTASSIUM_XENO_AND_GENERIC_API_COMPATIBLE_EXECUTORS",
                jsonIntegrityRule = "XENO_OR_UNSAFE_NATIVE_JSON_FORCES_CUSTOM_ENCODER",
                coreGuiRule = "PLAYERGUI_ONLY_NO_COREGUI_LOCALE_MODULE_TRAVERSAL",
            },
        }
    end

    local function saveMemory()
        if not canWrite then
            local msg = "writefile unavailable or SaveToFile disabled"
            logLine("MEMORY_SAVE_FAIL", msg)
            warn("[STA Stage 1 v1.1.7] MEMORY_SAVE_FAIL | " .. msg)
            return false
        end

        local payload = buildMemory()
        resetJsonSanitizeStats()
        local safePayload = jsonSafe(payload, "$", {})

        local okEncode, encoded, encoderUsed, encodeErr =
            encodeSanitizedPayload(safePayload, "FULL_MEMORY")

        if not okEncode then
            local msg = tostring(encodeErr)
            logLine("MEMORY_SAVE_FAIL", msg)
            warn("[STA Stage 1 v1.1.7] MEMORY_SAVE_FAIL | " .. msg)
            return false
        end

        print(
            "[STA Stage 1 v1.1.7] JSON_ENCODER_USED"
            .. " | " .. tostring(encoderUsed)
            .. " | Executor=" .. tostring(EXECUTOR.display)
        )

        if JsonSanitizeStats.converted > 0 then
            logLine(
                "JSON_SANITIZE_SUMMARY",
                "Converted=" .. tostring(JsonSanitizeStats.converted),
                "NonFinite=" .. tostring(JsonSanitizeStats.nonFiniteNumbers),
                "Unsupported=" .. tostring(JsonSanitizeStats.unsupportedValues),
                "Cycles=" .. tostring(JsonSanitizeStats.cycles),
                "KeyConversions=" .. tostring(JsonSanitizeStats.keyConversions),
                "TableShapes=" .. tostring(JsonSanitizeStats.tableShapeConversions),
                "KeyCollisions=" .. tostring(JsonSanitizeStats.keyCollisions)
            )
        end

        local okWrite, verifyDetail =
            writeVerifiedFile(MEMORY_FILE, encoded)

        if not okWrite then
            logLine("MEMORY_SAVE_FAIL", MEMORY_FILE, tostring(verifyDetail))
            warn(
                "[STA Stage 1 v1.1.7] MEMORY_SAVE_FAIL"
                .. " | " .. MEMORY_FILE
                .. " | " .. tostring(verifyDetail)
            )
            return false
        end

        logLine(
            "MEMORY_SAVED",
            MEMORY_FILE,
            "Bytes=" .. tostring(#encoded),
            "Encoder=" .. tostring(encoderUsed),
            "Executor=" .. tostring(EXECUTOR.display),
            tostring(verifyDetail)
        )

        print(
            "[STA Stage 1 v1.1.7] MEMORY_SAVE_OK"
            .. " | " .. MEMORY_FILE
            .. " | Bytes=" .. tostring(#encoded)
            .. " | Encoder=" .. tostring(encoderUsed)
            .. " | Executor=" .. tostring(EXECUTOR.display)
        )

        return true
    end

    local function saveInitialCheckpoint()
        if not canWrite then
            return false
        end

        local checkpoint = {
            schema = SCHEMA,
            version = VERSION,
            stage = 1,
            checkpoint = "INITIAL_SCAN_COMPLETE",
            fullMemorySnapshot = false,
            note = "Full memory is written on DELETE or 30-minute autosave",
            sessionUnix = SessionUnix,
            sessionDuration = elapsed(),
            logFile = LOG_FILE,
            memoryFile = MEMORY_FILE,
            executorProfile = EXECUTOR,
            device = DEVICE,
            targetedGuiState = TargetedGuiState,
            currentContext = CurrentContext,
            statistics = Statistics,
            memoryGuard = MemoryGuard,
            baseRegionModel = BaseRegionModel,
        }

        resetJsonSanitizeStats()
        local safeCheckpoint = jsonSafe(checkpoint, "$", {})

        local okEncode, encoded, encoderUsed, encodeErr =
            encodeSanitizedPayload(safeCheckpoint, "INITIAL_CHECKPOINT")

        if not okEncode then
            logLine(
                "INITIAL_CHECKPOINT_FAIL",
                tostring(encodeErr)
            )
            return false
        end

        local okWrite, verifyDetail =
            writeVerifiedFile(MEMORY_FILE, encoded)

        if not okWrite then
            logLine(
                "INITIAL_CHECKPOINT_FAIL",
                tostring(verifyDetail)
            )
            return false
        end

        logLine(
            "INITIAL_CHECKPOINT_SAVED",
            MEMORY_FILE,
            "Bytes=" .. tostring(#encoded),
            "Encoder=" .. tostring(encoderUsed),
            "Executor=" .. tostring(EXECUTOR.display)
        )

        print(
            "[STA Stage 1 v1.1.7] INITIAL_CHECKPOINT_OK"
            .. " | " .. MEMORY_FILE
            .. " | Bytes=" .. tostring(#encoded)
            .. " | Encoder=" .. tostring(encoderUsed)
        )

        return true
    end

    -- ============================================================
    -- MEMORY GUARD
    -- ============================================================

    local function readClientMemoryMb()
        local okStats, statsValue = pcall(function()
            return StatsService:GetTotalMemoryUsageMb()
        end)
        if okStats and type(statsValue) == "number" and statsValue > 0 then
            return statsValue, "Stats:GetTotalMemoryUsageMb"
        end

        if type(collectgarbage) == "function" then
            local ok, kb = pcall(collectgarbage, "count")
            if ok and type(kb) == "number" and kb > 0 then
                return kb / 1024, "collectgarbage(count)_LUA_ONLY"
            end
        end

        if type(gcinfo) == "function" then
            local ok, kb = pcall(gcinfo)
            if ok and type(kb) == "number" and kb > 0 then
                return kb / 1024, "gcinfo_LUA_ONLY"
            end
        end

        return nil, "UNAVAILABLE"
    end

    local function archiveSemanticRecord(runtimeId, rec)
        if not rec then return end

        local important =
            rec.isCanonicalSemanticEntity == true
            or classificationImportant(rec.semanticCandidates)
            or rec.class == "ProximityPrompt"
            or rec.class == "DragDetector"
            or rec.class == "ClickDetector"

        if not important then return end

        local key = rec.signature or runtimeId
        if not ArchivedWorldEntities[key] then
            ArchivedWorldOrder[#ArchivedWorldOrder + 1] = key
        end

        ArchivedWorldEntities[key] = {
            runtimeId = runtimeId,
            signature = rec.signature,
            class = rec.class,
            name = rec.name,
            path = rec.path,
            parentPath = rec.parentPath,
            position = rec.position,
            firstObservedAt = rec.firstObservedAt,
            lastSeenAt = rec.lastSeenAt,
            removedAt = rec.removedAt,
            firstObservedPhase = rec.firstObservedPhase,
            semanticCandidates = rec.semanticCandidates,
            prompt = rec.prompt,
            value = rec.value,
            semanticOwnerPath = rec.semanticOwnerPath,
            isCanonicalSemanticEntity = rec.isCanonicalSemanticEntity,
            objectBaseRegionCandidate = rec.objectBaseRegionCandidate,
            objectBaseRegionConfidence = rec.objectBaseRegionConfidence,
        }

        MemoryGuard.semanticArchivesCreated =
            (MemoryGuard.semanticArchivesCreated or 0) + 1
        Statistics.memorySemanticArchivesCreated =
            (Statistics.memorySemanticArchivesCreated or 0) + 1

        while #ArchivedWorldOrder > CONFIG.MaxArchivedSemanticEntities do
            local oldestKey = table.remove(ArchivedWorldOrder, 1)
            ArchivedWorldEntities[oldestKey] = nil
        end
    end

    local function removeIdFromSemanticIndexes(runtimeId, candidates)
        for _,c in ipairs(candidates or {}) do
            if BaseInfrastructure[c.category] then
                BaseInfrastructure[c.category][runtimeId] = nil
            end
            if WorldInfrastructure[c.category] then
                WorldInfrastructure[c.category][runtimeId] = nil
            end
            if LootContainers[c.category] then
                LootContainers[c.category][runtimeId] = nil
            end
        end

        Interactables[runtimeId] = nil
        UnknownObjects[runtimeId] = nil
        BaseRegionModel.anchorIds[runtimeId] = nil
    end

    local function pruneRemovedWorldRecords(ageSeconds, maxCount)
        local t = elapsed()
        local candidates = {}

        for runtimeId,rec in pairs(WorldObjects) do
            if rec.removedAt and (t - rec.removedAt) >= ageSeconds then
                candidates[#candidates + 1] = {
                    runtimeId = runtimeId,
                    removedAt = rec.removedAt,
                }
            end
        end

        table.sort(candidates, function(a, b)
            return (a.removedAt or 0) < (b.removedAt or 0)
        end)

        local removed = 0
        for i = 1, math.min(maxCount, #candidates) do
            local runtimeId = candidates[i].runtimeId
            local rec = WorldObjects[runtimeId]

            if rec and rec.removedAt then
                archiveSemanticRecord(runtimeId, rec)
                removeIdFromSemanticIndexes(runtimeId, rec.semanticCandidates)

                SemanticCandidates[runtimeId] = nil
                WorldObjects[runtimeId] = nil
                WorldInstanceByRuntimeId[runtimeId] = nil
                ObjectConnectionsByRuntimeId[runtimeId] = nil
                removed = removed + 1
            end
        end

        if removed > 0 then
            MemoryGuard.worldRecordsPruned =
                (MemoryGuard.worldRecordsPruned or 0) + removed
            Statistics.memoryWorldRecordsPruned =
                (Statistics.memoryWorldRecordsPruned or 0) + removed
        end

        return removed
    end

    local function pruneRemovedGuiRecords(ageSeconds, maxCount)
        local t = elapsed()
        local candidates = {}

        for runtimeId,rec in pairs(GuiObjects) do
            if rec.removedAt and (t - rec.removedAt) >= ageSeconds then
                candidates[#candidates + 1] = {
                    runtimeId = runtimeId,
                    removedAt = rec.removedAt,
                }
            end
        end

        table.sort(candidates, function(a, b)
            return (a.removedAt or 0) < (b.removedAt or 0)
        end)

        local removed = 0
        for i = 1, math.min(maxCount, #candidates) do
            local runtimeId = candidates[i].runtimeId
            local rec = GuiObjects[runtimeId]
            if rec and rec.removedAt then
                GuiObjects[runtimeId] = nil
                GuiInstanceByRuntimeId[runtimeId] = nil
                GuiConnectionsByRuntimeId[runtimeId] = nil
                removed = removed + 1
            end
        end

        if removed > 0 then
            MemoryGuard.guiRecordsPruned =
                (MemoryGuard.guiRecordsPruned or 0) + removed
            Statistics.memoryGuiRecordsPruned =
                (Statistics.memoryGuiRecordsPruned or 0) + removed
        end

        return removed
    end

    local function compactPeriodicRefreshList()
        local new = {}

        for _,item in ipairs(PeriodicRefreshList) do
            if item and item.runtimeId then
                local rec = WorldObjects[item.runtimeId]
                local obj = WorldInstanceByRuntimeId[item.runtimeId]

                if rec and not rec.removedAt and rec.periodicRefresh and obj and obj.Parent then
                    new[#new + 1] = {runtimeId = item.runtimeId}
                else
                    MemoryGuard.periodicRefreshEntriesDropped =
                        (MemoryGuard.periodicRefreshEntriesDropped or 0) + 1
                end
            end
        end

        PeriodicRefreshList = new
        PeriodicRefreshIndex = math.min(PeriodicRefreshIndex, math.max(1, #new))
    end

    local function trimHistoriesForMemory(level)
        local clusterLimit = CONFIG.MaxClusterHistory
        local baseSampleLimit = CONFIG.BaseRegionMaxSamples

        if level == "ELEVATED" then
            clusterLimit = math.min(clusterLimit, 20)
            baseSampleLimit = math.min(baseSampleLimit, 120)
        elseif level == "HIGH" then
            clusterLimit = math.min(clusterLimit, 10)
            baseSampleLimit = math.min(baseSampleLimit, 80)
        elseif level == "CRITICAL" then
            clusterLimit = math.min(clusterLimit, 5)
            baseSampleLimit = math.min(baseSampleLimit, 40)
        end

        for _,cluster in pairs(ResourceClusters) do
            local history = cluster.centerHistory
            if type(history) == "table" then
                while #history > clusterLimit do
                    table.remove(history, 1)
                end
            end
        end

        while #BaseRegionModel.recentSamples > baseSampleLimit do
            table.remove(BaseRegionModel.recentSamples, 1)
        end
    end

    local function memoryLevelFor(totalMb, baselineMb)
        if type(totalMb) ~= "number" then return "UNKNOWN" end

        local baseline = baselineMb or totalMb
        local delta = math.max(0, totalMb - baseline)

        if totalMb >= CONFIG.MemoryCriticalAbsoluteMb
            or delta >= CONFIG.MemoryCriticalDeltaMb
        then
            return "CRITICAL"
        end

        if totalMb >= CONFIG.MemoryHighAbsoluteMb
            or delta >= CONFIG.MemoryHighDeltaMb
        then
            return "HIGH"
        end

        if totalMb >= CONFIG.MemoryWarnAbsoluteMb
            or delta >= CONFIG.MemoryWarnDeltaMb
        then
            return "ELEVATED"
        end

        return "NORMAL"
    end

    local function applyMemoryLevel(level)
        if level == "CRITICAL" then
            MemoryGuard.workFactor = 0.12
            MemoryGuard.logMultiplier = 6.0
            MemoryGuard.clusterMultiplier = 8.0
        elseif level == "HIGH" then
            MemoryGuard.workFactor = 0.30
            MemoryGuard.logMultiplier = 3.5
            MemoryGuard.clusterMultiplier = 4.0
        elseif level == "ELEVATED" then
            MemoryGuard.workFactor = 0.65
            MemoryGuard.logMultiplier = 1.75
            MemoryGuard.clusterMultiplier = 2.0
        else
            MemoryGuard.workFactor = 1.0
            MemoryGuard.logMultiplier = 1.0
            MemoryGuard.clusterMultiplier = 1.0
        end
    end

    local function runMemoryPrune(reason, forceCritical)
        local level = forceCritical and "CRITICAL" or MemoryGuard.level
        local worldAge, guiAge, limit

        if level == "CRITICAL" then
            worldAge = CONFIG.MemoryCriticalWorldRetention
            guiAge = CONFIG.MemoryCriticalGuiRetention
            limit = CONFIG.MemoryCriticalPruneLimit
        elseif level == "HIGH" then
            worldAge = CONFIG.MemoryHighWorldRetention
            guiAge = CONFIG.MemoryHighGuiRetention
            limit = CONFIG.MemoryHighPruneLimit
        elseif level == "ELEVATED" then
            worldAge = CONFIG.MemoryElevatedWorldRetention
            guiAge = CONFIG.MemoryElevatedGuiRetention
            limit = CONFIG.MemoryElevatedPruneLimit
        else
            return 0, 0
        end

        flushLog()

        local worldPruned = pruneRemovedWorldRecords(worldAge, limit)
        local guiPruned =
            pruneRemovedGuiRecords(guiAge, math.max(200, math.floor(limit / 2)))

        compactPeriodicRefreshList()
        trimHistoriesForMemory(level)

        if level == "CRITICAL" and type(collectgarbage) == "function" then
            local ok = pcall(collectgarbage, "collect")
            if ok then
                MemoryGuard.emergencyCollections =
                    (MemoryGuard.emergencyCollections or 0) + 1
            end
        end

        if worldPruned > 0 or guiPruned > 0 then
            logLine(
                "MEMORY_GUARD_PRUNE",
                "Reason=" .. tostring(reason),
                "Level=" .. tostring(level),
                "World=" .. tostring(worldPruned),
                "GUI=" .. tostring(guiPruned)
            )

            print(
                "[STA Stage 1 v1.1.7] MEMORY_GUARD_PRUNE"
                .. " | Level=" .. tostring(level)
                .. " | World=" .. tostring(worldPruned)
                .. " | GUI=" .. tostring(guiPruned)
            )
        end

        return worldPruned, guiPruned
    end

    local function updateMemoryGuard(force)
        if not MemoryGuard.enabled then return end

        local t = now()
        if not force
            and (t - MemoryGuard.lastCheckAt) < CONFIG.MemoryCheckInterval
        then
            return
        end
        MemoryGuard.lastCheckAt = t

        local totalMb, source = readClientMemoryMb()
        MemoryGuard.source = source

        if type(totalMb) ~= "number" then
            return
        end

        MemoryGuard.totalMb = round(totalMb, 1)
        MemoryGuard.peakMb = math.max(MemoryGuard.peakMb or 0, totalMb)

        if MemoryGuard.baselineMb == nil or totalMb < MemoryGuard.baselineMb then
            MemoryGuard.baselineMb = totalMb
        end

        MemoryGuard.deltaMb =
            math.max(0, totalMb - (MemoryGuard.baselineMb or totalMb))

        local newLevel = memoryLevelFor(totalMb, MemoryGuard.baselineMb)

        if newLevel ~= MemoryGuard.level then
            local oldLevel = MemoryGuard.level
            MemoryGuard.level = newLevel
            MemoryGuard.transitions = (MemoryGuard.transitions or 0) + 1
            Statistics.memoryGuardTransitions =
                (Statistics.memoryGuardTransitions or 0) + 1

            applyMemoryLevel(newLevel)

            logLine(
                "MEMORY_GUARD_LEVEL_CHANGE",
                tostring(oldLevel),
                "->",
                tostring(newLevel),
                "MemoryMb=" .. tostring(round(totalMb, 1)),
                "BaselineMb=" .. tostring(round(MemoryGuard.baselineMb, 1)),
                "DeltaMb=" .. tostring(round(MemoryGuard.deltaMb, 1)),
                "Source=" .. tostring(source)
            )

            print(
                "[STA Stage 1 v1.1.7] MEMORY_GUARD"
                .. " | " .. tostring(oldLevel) .. " -> " .. tostring(newLevel)
                .. " | Memory=" .. tostring(round(totalMb, 1)) .. " MB"
                .. " | Delta=" .. tostring(round(MemoryGuard.deltaMb, 1)) .. " MB"
            )
        else
            applyMemoryLevel(newLevel)
        end

        if newLevel ~= "NORMAL"
            and (force
                or (t - MemoryGuard.lastPruneAt) >= CONFIG.MemoryPruneInterval)
        then
            MemoryGuard.lastPruneAt = t
            runMemoryPrune("PERIODIC_PRESSURE", false)
        end
    end

    local function currentAdaptiveFactor()
        local fpsFactor = 1.0

        if DEVICE.Mobile then
            if FpsEma <= CONFIG.CriticalFpsThreshold then
                fpsFactor = 0.25
            elseif FpsEma <= CONFIG.LowFpsThreshold then
                fpsFactor = 0.50
            end
        else
            if FpsEma <= CONFIG.CriticalFpsThreshold then
                fpsFactor = 0.50
            elseif FpsEma <= CONFIG.LowFpsThreshold then
                fpsFactor = 0.75
            end
        end

        return math.max(
            0.08,
            fpsFactor * (MemoryGuard.workFactor or 1.0)
        )
    end

    local function processDynamicQueues()
        local factor = currentAdaptiveFactor()
        local maxWorld = math.max(
            1,
            math.floor(CONFIG.DynamicWorldPerFrame * factor)
        )

        local maxGui = 0
        if EXECUTOR.guiMode == "FULL_PLAYERGUI_BUDGETED" then
            maxGui = math.max(
                1,
                math.floor(CONFIG.DynamicGuiPerFrame * factor)
            )
        end
        local budgetSeconds = (CONFIG.DynamicBudgetMs * factor) / 1000
        local started = safeClock()

        local processedWorld = 0
        while DynamicWorldHead <= #DynamicWorldQueue and processedWorld < maxWorld do
            if safeClock() - started >= budgetSeconds then break end

            local obj = DynamicWorldQueue[DynamicWorldHead]
            DynamicWorldQueue[DynamicWorldHead] = nil
            DynamicWorldHead = DynamicWorldHead + 1

            if obj then
                DynamicWorldQueued[obj] = nil
                if Running and obj.Parent then
                    local ok, err = pcall(registerWorldObject, obj, false)
                    if not ok then
                        reportRuntimeError("DYNAMIC_WORLD_QUEUE", err)
                    end
                end
            end

            processedWorld = processedWorld + 1
            Statistics.dynamicWorldProcessed = (Statistics.dynamicWorldProcessed or 0) + 1
        end

        local processedGui = 0
        while DynamicGuiHead <= #DynamicGuiQueue and processedGui < maxGui do
            if safeClock() - started >= budgetSeconds then break end

            local obj = DynamicGuiQueue[DynamicGuiHead]
            DynamicGuiQueue[DynamicGuiHead] = nil
            DynamicGuiHead = DynamicGuiHead + 1

            if obj then
                DynamicGuiQueued[obj] = nil
                if Running and obj.Parent then
                    local ok, err = pcall(registerGui, obj, false)
                    if not ok then
                        reportRuntimeError("DYNAMIC_GUI_QUEUE", err)
                    end
                end
            end

            processedGui = processedGui + 1
            Statistics.dynamicGuiProcessed = (Statistics.dynamicGuiProcessed or 0) + 1
        end

        DynamicWorldQueue, DynamicWorldHead = compactQueue(DynamicWorldQueue, DynamicWorldHead)
        DynamicGuiQueue, DynamicGuiHead = compactQueue(DynamicGuiQueue, DynamicGuiHead)
    end

    local function processPeriodicRefreshBudget()
        local count = #PeriodicRefreshList
        if count == 0 then return end

        local factor = currentAdaptiveFactor()
        local maxObjects = math.max(1, math.floor(CONFIG.RefreshObjectsPerFrame * factor))
        local budgetSeconds = (CONFIG.RefreshBudgetMs * factor) / 1000
        local started = safeClock()
        local processed = 0
        local checked = 0

        while processed < maxObjects and checked < count do
            if safeClock() - started >= budgetSeconds then break end

            if PeriodicRefreshIndex > count then
                PeriodicRefreshIndex = 1
            end

            local item = PeriodicRefreshList[PeriodicRefreshIndex]
            PeriodicRefreshIndex = PeriodicRefreshIndex + 1
            checked = checked + 1

            if item and item.runtimeId then
                local obj = WorldInstanceByRuntimeId[item.runtimeId]
                local rec = WorldObjects[item.runtimeId]

                if obj and obj.Parent and rec and not rec.removedAt and rec.periodicRefresh then
                    local ok, err = pcall(refreshWorldObject, obj, item.runtimeId)
                    if not ok then
                        reportRuntimeError("BUDGETED_REFRESH:" .. tostring(item.runtimeId), err)
                    end
                    processed = processed + 1
                end
            end
        end
    end


    -- ============================================================
    -- SELF-CONTAINED INITIAL SCANS
    -- No dependency on globals left by older script versions.
    -- ============================================================

    local function yieldInitialScan(processed)
        if processed % CONFIG.InitialScanBatch ~= 0 then
            return
        end

        if RunService and RunService.Heartbeat then
            RunService.Heartbeat:Wait()
        else
            safeWait(CONFIG.InitialScanYield)
        end
    end

    local function scanWorkspaceInitial()
        local queue = {Workspace}
        local head = 1
        local processed = 0
        local registered = 0

        while Running and head <= #queue do
            local parent = queue[head]
            queue[head] = nil
            head = head + 1

            if parent then
                local okChildren, children = pcall(function()
                    return parent:GetChildren()
                end)

                if okChildren and type(children) == "table" then
                    for _,child in ipairs(children) do
                        queue[#queue + 1] = child
                        processed = processed + 1

                        if shouldTrackObject(child) and not RuntimeByInstance[child] then
                            local okRegister, registerErr =
                                pcall(registerWorldObject, child, true)

                            if okRegister then
                                registered = registered + 1
                            else
                                reportRuntimeError(
                                    "INITIAL_WORKSPACE_OBJECT",
                                    registerErr
                                )
                            end
                        end

                        yieldInitialScan(processed)
                    end
                end
            end
        end

        logLine(
            "INITIAL_WORKSPACE_SCAN_COMPLETE",
            "Visited=" .. tostring(processed),
            "Registered=" .. tostring(registered)
        )

        return registered
    end

    local function pollTargetedGuiState(forceLog)
        local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if not playerGui then
            return false
        end

        local topUI = playerGui:FindFirstChild("TopUI")
        local dayCounter = topUI and topUI:FindFirstChild("DayCounter") or nil

        if dayCounter then
            local okText, text = pcall(function()
                return dayCounter.Text
            end)

            if okText and type(text) == "string" then
                local oldText = TargetedGuiState.dayCounterText
                TargetedGuiState.dayCounterText = text
                TargetedGuiState.dayCounterPath = safeFullName(dayCounter)
                TargetedGuiState.observations =
                    (TargetedGuiState.observations or 0) + 1
                TargetedGuiState.lastObservedAt = elapsed()

                if oldText ~= nil and oldText ~= text then
                    TargetedGuiState.changes =
                        (TargetedGuiState.changes or 0) + 1

                    logLine(
                        "TARGETED_GUI_CHANGE",
                        "TopUI.DayCounter",
                        tostring(oldText),
                        "->",
                        tostring(text)
                    )
                elseif forceLog then
                    logLine(
                        "TARGETED_GUI_OBSERVED",
                        "TopUI.DayCounter",
                        tostring(text)
                    )
                end
            end
        end

        return true
    end

    local function scanGuiInitial()
        if EXECUTOR.guiMode == "TARGETED_STATE_ONLY" then
            pollTargetedGuiState(true)

            print(
                "[STA Stage 1 v1.1.7] INITIAL_GUI_SCAN"
                .. " | Mode=TARGETED_STATE_ONLY"
                .. " | Executor=" .. tostring(EXECUTOR.display)
            )

            logLine(
                "GUI_SCAN_MODE",
                "TARGETED_STATE_ONLY",
                "Executor=" .. tostring(EXECUTOR.display),
                "Reason=AVOID_FULL_PLAYERGUI_TRAVERSAL_AND_WATCHER_STORM"
            )

            return 0
        end

        local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if not playerGui then
            return 0
        end

        local queue = {playerGui}
        local head = 1
        local processed = 0
        local registered = 0

        while Running and head <= #queue do
            local parent = queue[head]
            queue[head] = nil
            head = head + 1

            if parent then
                local okChildren, children = pcall(function()
                    return parent:GetChildren()
                end)

                if okChildren and type(children) == "table" then
                    for _,child in ipairs(children) do
                        queue[#queue + 1] = child
                        processed = processed + 1

                        if shouldTrackGui(child)
                            and not GuiRuntimeByInstance[child]
                        then
                            local okRegister, registerErr =
                                pcall(registerGui, child, true)

                            if okRegister then
                                registered = registered + 1
                            else
                                reportRuntimeError(
                                    "INITIAL_GUI_OBJECT",
                                    registerErr
                                )
                            end
                        end

                        yieldInitialScan(processed)
                    end
                end
            end
        end

        logLine(
            "INITIAL_GUI_SCAN_COMPLETE",
            "Mode=FULL_PLAYERGUI_BUDGETED",
            "Visited=" .. tostring(processed),
            "Registered=" .. tostring(registered)
        )

        return registered
    end

    local function connectDynamicDiscovery()
        connect(Workspace.DescendantAdded:Connect(function(obj)
            if not Running then return end
            enqueueWorldObject(obj)
        end))

        connect(Workspace.DescendantRemoving:Connect(function(obj)
            if not Running then return end
            DynamicWorldQueued[obj] = nil
            markWorldObjectRemoved(obj)
        end))

        if EXECUTOR.guiMode == "FULL_PLAYERGUI_BUDGETED" then
            local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
            if playerGui then
                connect(playerGui.DescendantAdded:Connect(function(obj)
                    if not Running then return end
                    enqueueGuiObject(obj)
                end))

                connect(playerGui.DescendantRemoving:Connect(function(obj)
                    if not Running then return end
                    DynamicGuiQueued[obj] = nil
                    markGuiRemoved(obj)
                end))
            end
        else
            logLine(
                "GUI_DYNAMIC_DISCOVERY_DISABLED",
                "Mode=" .. tostring(EXECUTOR.guiMode),
                "Executor=" .. tostring(EXECUTOR.display)
            )
        end
    end

    local function connectCharacterContext()
        if CharacterConnection then
            pcall(function() CharacterConnection:Disconnect() end)
            CharacterConnection = nil
        end
        CharacterConnection = LocalPlayer.CharacterAdded:Connect(function()
            safeWait(0.5)
            if Running then
                updateContext()
                logLine("PLAYER_CHARACTER_REOBSERVED", safeFullName(LocalPlayer.Character))
            end
        end)
    end


    -- Forward declarations for touch callbacks.
    -- These must exist before createMobileControls() is defined.
    local startObserver
    local stopObserver

    -- ============================================================
    -- MOBILE TOUCH CONTROLS
    -- Local UI only. It does not interact with the game world.
    -- ============================================================

    local function updateMobileControlVisuals()
        if not MobileGui or not MobileGui.Parent then return end

        if MobileStatusLabel then
            if Running then
                MobileStatusLabel.Text = "STAGE 1: RUNNING"
            else
                MobileStatusLabel.Text = "STAGE 1: IDLE"
            end
        end

        if MobileStartButton then
            MobileStartButton.Text = Running and "RUNNING" or "START"
            MobileStartButton.AutoButtonColor = not Running
            MobileStartButton.Active = not Running
        end

        if MobileSaveButton then
            MobileSaveButton.Text = Running and "SAVE NOW" or "SAVE"
            MobileSaveButton.Active = true
        end

        if MobileStopButton then
            MobileStopButton.Text = Running and "STOP + SAVE" or "STOPPED"
            MobileStopButton.AutoButtonColor = Running
            MobileStopButton.Active = Running
        end
    end

    local function destroyOldMobileGui()
        if MobileUIConnection then
            pcall(function() MobileUIConnection:Disconnect() end)
            MobileUIConnection = nil
        end

        if MobileGui then
            pcall(function() MobileGui:Destroy() end)
            MobileGui = nil
        end

        local playerGui = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if playerGui then
            local old = playerGui:FindFirstChild("STA_STAGE1_MOBILE_CONTROL")
            if old then
                pcall(function() old:Destroy() end)
            end
        end
    end

    local function createMobileControls()
        if not DEVICE.TouchEnabled then
            return false, "TouchEnabled=false"
        end

        local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if not playerGui then
            return false, "PlayerGui unavailable"
        end

        destroyOldMobileGui()

        local gui = Instance.new("ScreenGui")
        gui.Name = "STA_STAGE1_MOBILE_CONTROL"
        gui.ResetOnSpawn = false
        gui.IgnoreGuiInset = false
        gui.DisplayOrder = 999999
        gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        gui.Parent = playerGui
        MobileGui = gui

        local panel = Instance.new("Frame")
        panel.Name = "Panel"
        panel.AnchorPoint = Vector2.new(1, 0)
        panel.Position = UDim2.new(1, -12, 0, 86)
        panel.Size = UDim2.fromOffset(184, 188)
        panel.BackgroundTransparency = 0.12
        panel.BorderSizePixel = 0
        panel.Active = true
        panel.Parent = gui

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 12)
        corner.Parent = panel

        local title = Instance.new("TextLabel")
        title.Name = "Title"
        title.BackgroundTransparency = 1
        title.Position = UDim2.fromOffset(8, 6)
        title.Size = UDim2.new(1, -44, 0, 24)
        title.Font = Enum.Font.GothamBold
        title.TextSize = 14
        title.TextWrapped = true
        title.Text = "STA AI - STAGE 1"
        title.TextColor3 = Color3.new(1, 1, 1)
        title.Parent = panel

        local collapse = Instance.new("TextButton")
        collapse.Name = "Collapse"
        collapse.AnchorPoint = Vector2.new(1, 0)
        collapse.Position = UDim2.new(1, -6, 0, 5)
        collapse.Size = UDim2.fromOffset(30, 26)
        collapse.Font = Enum.Font.GothamBold
        collapse.TextSize = 18
        collapse.Text = "-"
        collapse.Parent = panel
        local collapseCorner = Instance.new("UICorner")
        collapseCorner.CornerRadius = UDim.new(0, 8)
        collapseCorner.Parent = collapse

        local status = Instance.new("TextLabel")
        status.Name = "Status"
        status.BackgroundTransparency = 1
        status.Position = UDim2.fromOffset(8, 34)
        status.Size = UDim2.new(1, -16, 0, 22)
        status.Font = Enum.Font.Gotham
        status.TextSize = 12
        status.Text = "STAGE 1: IDLE"
        status.TextColor3 = Color3.new(1, 1, 1)
        status.Parent = panel
        MobileStatusLabel = status

        local body = Instance.new("Frame")
        body.Name = "Body"
        body.BackgroundTransparency = 1
        body.Position = UDim2.fromOffset(7, 60)
        body.Size = UDim2.new(1, -14, 1, -67)
        body.Parent = panel

        local layout = Instance.new("UIListLayout")
        layout.FillDirection = Enum.FillDirection.Vertical
        layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        layout.VerticalAlignment = Enum.VerticalAlignment.Top
        layout.Padding = UDim.new(0, 7)
        layout.Parent = body

        local function makeButton(name, text)
            local b = Instance.new("TextButton")
            b.Name = name
            b.Size = UDim2.new(1, 0, 0, 34)
            b.Font = Enum.Font.GothamBold
            b.TextSize = 13
            b.Text = text
            b.TextWrapped = true
            b.Parent = body
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 9)
            c.Parent = b
            return b
        end

        MobileStartButton = makeButton("Start", "START")
        MobileSaveButton = makeButton("Save", "SAVE NOW")
        MobileStopButton = makeButton("Stop", "STOP + SAVE")

        MobileStartButton.Activated:Connect(function()
            if Running then return end
            print("[STA Stage 1 v1.1.7] MOBILE_INPUT | START")
            local ok, err = pcall(startObserver)
            if not ok then reportRuntimeError("MOBILE_START", err) end
            updateMobileControlVisuals()
        end)

        MobileSaveButton.Activated:Connect(function()
            print("[STA Stage 1 v1.1.7] MOBILE_INPUT | SAVE_NOW")
            local ok, result = pcall(saveMemory)
            if not ok then
                reportRuntimeError("MOBILE_SAVE", result)
            elseif result then
                print("[STA Stage 1 v1.1.7] MOBILE_SAVE_OK")
            else
                warn("[STA Stage 1 v1.1.7] MOBILE_SAVE_NOT_VERIFIED")
            end
            updateMobileControlVisuals()
        end)

        MobileStopButton.Activated:Connect(function()
            if not Running then return end
            print("[STA Stage 1 v1.1.7] MOBILE_INPUT | STOP_SAVE")
            local ok, err = pcall(stopObserver)
            if not ok then reportRuntimeError("MOBILE_STOP", err) end
            updateMobileControlVisuals()
        end)

        local expanded = true
        collapse.Activated:Connect(function()
            expanded = not expanded
            body.Visible = expanded
            status.Visible = expanded
            collapse.Text = expanded and "-" or "+"
            panel.Size = expanded and UDim2.fromOffset(184, 188) or UDim2.fromOffset(184, 38)
        end)

        -- Touch dragging for the panel.
        local dragging = false
        local dragStart = nil
        local startPos = nil
        local dragInput = nil

        panel.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Touch
                or input.UserInputType == Enum.UserInputType.MouseButton1
            then
                dragging = true
                dragStart = input.Position
                startPos = panel.Position
            end
        end)

        panel.InputChanged:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Touch
                or input.UserInputType == Enum.UserInputType.MouseMovement
            then
                dragInput = input
            end
        end)

        MobileUIConnection = UserInputService.InputChanged:Connect(function(input)
            if dragging and input == dragInput and dragStart and startPos then
                local delta = input.Position - dragStart
                panel.Position = UDim2.new(
                    startPos.X.Scale,
                    startPos.X.Offset + delta.X,
                    startPos.Y.Scale,
                    startPos.Y.Offset + delta.Y
                )
            end
        end)

        UserInputService.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Touch
                or input.UserInputType == Enum.UserInputType.MouseButton1
            then
                dragging = false
                dragInput = nil
            end
        end)

        updateMobileControlVisuals()
        print("[STA Stage 1 v1.1.7] MOBILE_UI_READY")
        return true, "OK"
    end

    -- ============================================================
    -- START / STOP
    -- ============================================================

    startObserver = function()
        if Running then
            print("[STA Stage 1 v1.1.7] Observer is already running.")
            return
        end

        print("[STA Stage 1 v1.1.7] MODULE_START | EXECUTOR_PREFLIGHT")
        print(
            "[STA Stage 1 v1.1.7] EXECUTOR_PROFILE"
            .. " | Name=" .. tostring(EXECUTOR.display)
            .. " | Family=" .. tostring(EXECUTOR.family)
            .. " | JsonMode=" .. tostring(EXECUTOR.jsonMode)
        )
        local preflight = {
            {"Players", Players ~= nil},
            {"Workspace", Workspace ~= nil},
            {"RunService", RunService ~= nil},
            {"UserInputService", UserInputService ~= nil},
            {"HttpService", HttpService ~= nil},
            {"CollectionService", CollectionService ~= nil},
            {"Lighting", Lighting ~= nil},
            {"LocalPlayer", LocalPlayer ~= nil},
            {"task.spawn", type(TASK) == "table" and type(TASK.spawn) == "function"},
            {"task.wait", type(TASK) == "table" and type(TASK.wait) == "function"},
            {"JSONEncode", HttpService and type(HttpService.JSONEncode) == "function"},
            {"writefile", type(writefile) == "function"},
            {"readfile", type(readfile) == "function"},
            {"appendfile", type(appendfile) == "function"},
            {"isfile", type(isfile) == "function"},
            {"Stats memory", EXECUTOR.statsMemory == true},
        }
        local preflightFails = 0
        for _, item in ipairs(preflight) do
            local name, ok = item[1], item[2]
            if ok then
                print("[STA Stage 1 v1.1.7] PREFLIGHT_PASS | " .. tostring(name))
            else
                preflightFails = preflightFails + 1
                warn("[STA Stage 1 v1.1.7] PREFLIGHT_WARN | " .. tostring(name))
            end
        end
        print(
            "[STA Stage 1 v1.1.7] MODULE_OK | EXECUTOR_PREFLIGHT"
            .. " | Warnings=" .. tostring(preflightFails)
        )

        local function checkpoint(name)
            print("[STA Stage 1 v1.1.7] START_CHECKPOINT | " .. tostring(name))
        end

        local function cleanupPartialStart()
            Running = false
            if MainHeartbeatConnection then
                pcall(function() MainHeartbeatConnection:Disconnect() end)
                MainHeartbeatConnection = nil
            end
            if CharacterConnection then
                pcall(function() CharacterConnection:Disconnect() end)
                CharacterConnection = nil
            end
            pcall(disconnectAll)
        end

        local function startupBody()
            checkpoint("01_SESSION_STATE")
            Running = true
            SessionStartClock = now()
            SessionUnix = safeUnixTime()
            LOG_FILE = string.format("STA_STAGE1_WORLD_V117_%d.log", SessionUnix)
            MEMORY_FILE = string.format("STA_STAGE1_WORLD_MEMORY_V117_%d.json", SessionUnix)

            checkpoint("02_RESET_MEMORY")
            LogBuffer = {}
            Connections = {}
            ObjectCounter = 0
            GuiCounter = 0
            ClusterCounter = 0
            RuntimeByInstance = setmetatable({}, {__mode = "k"})
            GuiRuntimeByInstance = setmetatable({}, {__mode = "k"})
            WorldInstanceByRuntimeId = setmetatable({}, {__mode = "v"})
            GuiInstanceByRuntimeId = setmetatable({}, {__mode = "v"})
            ObjectConnectionsByRuntimeId = {}
            GuiConnectionsByRuntimeId = {}
            WorldObjects = {}
            GuiObjects = {}
            SemanticCandidates = {}
            ResourceClusters = {}
            BaseInfrastructure = {}
            WorldInfrastructure = {}
            LootContainers = {}
            Interactables = {}
            UnknownObjects = {}
            SignatureHistory = {}
            ArchivedWorldEntities = {}
            ArchivedWorldOrder = {}

            MemoryGuard = {
                enabled = CONFIG.MemoryGuardEnabled,
                level = "NORMAL",
                totalMb = nil,
                source = "UNKNOWN",
                baselineMb = nil,
                peakMb = 0,
                deltaMb = 0,
                workFactor = 1.0,
                logMultiplier = 1.0,
                clusterMultiplier = 1.0,
                lastCheckAt = 0,
                lastPruneAt = 0,
                transitions = 0,
                worldRecordsPruned = 0,
                guiRecordsPruned = 0,
                semanticArchivesCreated = 0,
                ownedConnectionsDisconnected = 0,
                periodicRefreshEntriesDropped = 0,
                emergencyCollections = 0,
            }

            CurrentContext = {
                phase=nil,
                nearBase=nil,
                playerPosition=nil,
                day=nil,
                daySource=nil,
                highestDayRecord=nil,
            }

            TargetedGuiState = {
                mode = EXECUTOR.guiMode,
                dayCounterPath = nil,
                dayCounterText = nil,
                observations = 0,
                changes = 0,
                lastObservedAt = nil,
            }
            Statistics = {
                objectsObserved = 0,
                objectsPreexistingAtStart = 0,
                objectsObservedAfterStart = 0,
                objectsRemoved = 0,
                objectsReobserved = 0,
                objectsMoved = 0,
                attributeChanges = 0,
                valueChanges = 0,
                promptDiscovered = 0,
                promptChanges = 0,
                guiObserved = 0,
                guiChanges = 0,
                semanticCandidates = 0,
                resourceClustersCreated = 0,
                resourceClusterUpdates = 0,

                -- Performance/streaming counters must also be reset here.
                dynamicWorldQueued = 0,
                dynamicWorldProcessed = 0,
                dynamicGuiQueued = 0,
                dynamicGuiProcessed = 0,
                streamingBurstPeak = 0,
                throttledNumericLogs = 0,
                throttledGuiTextLogs = 0,
                semanticReclassifications = 0,
                canonicalEntities = 0,
                baseRegionSamples = 0,
                dynamicWorldDuplicateSkips = 0,
                dynamicGuiDuplicateSkips = 0,
                invalidUtf8BytesReplaced = 0,
                memoryGuardTransitions = 0,
                memoryWorldRecordsPruned = 0,
                memoryGuiRecordsPruned = 0,
                memorySemanticArchivesCreated = 0,
                memoryOwnedConnectionsDisconnected = 0,

                byClass = {},
                byCategory = {},
            }

            checkpoint("03_PREPARE_FILES")
            if canWrite then
                pcall(function() writefile(LOG_FILE, "") end)
            end

            checkpoint("04_INITIAL_LOG")
            logLine("SECTION", "STA TRUE AI STAGE 1 SEMANTIC WORLD OBSERVER STARTED")
            logLine("VERSION", VERSION)
            logLine("FILES", LOG_FILE, MEMORY_FILE)
            logLine("MODE", "PASSIVE_READ_ONLY", "DescendantAdded=FIRST_OBSERVED_NOT_SPAWN")
            logLine(
                "EXECUTOR_PROFILE",
                "Name=" .. tostring(EXECUTOR.display),
                "Family=" .. tostring(EXECUTOR.family),
                "JsonMode=" .. tostring(EXECUTOR.jsonMode),
                "GuiMode=" .. tostring(EXECUTOR.guiMode),
                "VectorJSON=" .. tostring(EXECUTOR.nativeJsonVectorBehavior),
                "SparseJSON=" .. tostring(EXECUTOR.nativeJsonSparseBehavior)
            )
            logLine("COREGUI_POLICY", "DO_NOT_SCAN_COREGUI_MODULES")
            logLine("PERFORMANCE_COUNTER_SCHEMA", "v1.1.7", "NIL_SAFE=true")

            checkpoint("05_CONTEXT")
            local okContext = protectedStage("START_UPDATE_CONTEXT", updateContext)

            checkpoint("06_DYNAMIC_DISCOVERY")
            local okDiscovery = protectedStage("START_CONNECT_DYNAMIC_DISCOVERY", connectDynamicDiscovery)

            checkpoint("07_CHARACTER_CONTEXT")
            local okCharacter = protectedStage("START_CONNECT_CHARACTER_CONTEXT", connectCharacterContext)

            if not okContext or not okDiscovery or not okCharacter then
                reportRuntimeError("STARTUP_PARTIAL", "One or more startup sub-stages failed; continuing with available observers.")
            end

            checkpoint("08_INITIAL_SCAN_THREAD")
            print("[STA Stage 1 v1.1.7] MODULE_START | INITIAL_SCAN_THREAD")
            local spawnOk, spawnErr = pcall(function()
                safeSpawn(function()
                    protectedStage("INITIAL_WORKSPACE_SCAN", scanWorkspaceInitial)
                    protectedStage("INITIAL_GUI_SCAN", scanGuiInitial)
                    protectedStage("INITIAL_RESOURCE_CLUSTER_SCAN", updateResourceClusters)
                    if CONFIG.InitialFullMemorySave then
                        protectedStage("INITIAL_MEMORY_SAVE", saveMemory)
                    else
                        protectedStage(
                            "INITIAL_LIGHTWEIGHT_CHECKPOINT",
                            saveInitialCheckpoint
                        )
                    end
                    print("[STA Stage 1 v1.1.7] MODULE_OK | INITIAL_SCAN_THREAD")
                end)
            end)
            if not spawnOk then
                reportRuntimeError("MODULE_FAIL:INITIAL_SCAN_THREAD", spawnErr)
            end

            checkpoint("09_TIMERS")
            LastObjectStateScan = now()
            LastClusterScan = now()
            LastTargetedGuiPoll = now()
            LastContextScan = now()
            LastAutosave = now()
            LastConsoleStatus = now()

            DynamicWorldQueue = {}
            DynamicWorldHead = 1
            DynamicWorldQueued = setmetatable({}, {__mode = "k"})
            DynamicGuiQueue = {}
            DynamicGuiHead = 1
            DynamicGuiQueued = setmetatable({}, {__mode = "k"})
            PeriodicRefreshIndex = 1
            ResourceClusterDirty = true
            LastClusterVerification = 0
            FpsEma = 60
            LastHeartbeatAt = nil
            StreamingBurstPeak = 0

            BaseRegionModel = {
                sampleCount = 0,
                recentSamples = {},
                center = nil,
                observedRadius = 0,
                effectiveRadius = 0,
                confidence = 0,
                lastUpdatedAt = nil,
                anchorIds = {},
            }

            CurrentContext = {
                phase = nil,
                nearBase = nil,
                playerPosition = nil,
                day = nil,
                daySource = nil,
                highestDayRecord = nil,
            }

            updateMemoryGuard(true)

            checkpoint("10_HEARTBEAT_CONNECT")
            local okHeartbeat, heartbeatOrErr = pcall(function()
                return RunService.Heartbeat:Connect(function()
                    if not Running then return end
                    local okTick, tickErr = pcall(function()
                        local t = now()

                        -- FPS EMA is used only to reduce observer workload.
                        if LastHeartbeatAt then
                            local dt = t - LastHeartbeatAt
                            if dt > 0 and dt < 1 then
                                local fps = math.min(240, 1 / dt)
                                FpsEma = (FpsEma * 0.92) + (fps * 0.08)
                            end
                        end
                        LastHeartbeatAt = t

                        updateMemoryGuard(false)

                        -- Process only a small amount of newly-streamed content
                        -- each frame. This prevents a newly rendered map region
                        -- from becoming one giant synchronous scan.
                        processDynamicQueues()

                        if t - LastObjectStateScan >= CONFIG.ObjectStateInterval then
                            LastObjectStateScan = t
                            processPeriodicRefreshBudget()
                        end

                        local effectiveClusterInterval =
                            CONFIG.ClusterInterval
                            * (MemoryGuard.clusterMultiplier or 1)

                        if t - LastClusterScan >= effectiveClusterInterval then
                            local mustVerify = (t - LastClusterVerification) >= CONFIG.ClusterVerifyInterval
                            if ResourceClusterDirty or mustVerify then
                                LastClusterScan = t
                                LastClusterVerification = t
                                ResourceClusterDirty = false
                                protectedStage("PERIODIC_RESOURCE_CLUSTER_SCAN", updateResourceClusters)
                            else
                                LastClusterScan = t
                            end
                        end

                        if t - LastContextScan >= CONFIG.PlayerContextInterval then
                            LastContextScan = t
                            protectedStage(
                                "PERIODIC_UPDATE_CONTEXT",
                                updateContext
                            )
                        end

                        if EXECUTOR.guiMode == "TARGETED_STATE_ONLY"
                            and (t - LastTargetedGuiPoll)
                                >= CONFIG.TargetedGuiPollInterval
                        then
                            LastTargetedGuiPoll = t
                            local okGuiPoll, guiPollErr =
                                pcall(pollTargetedGuiState, false)

                            if not okGuiPoll then
                                reportRuntimeError(
                                    "TARGETED_GUI_POLL",
                                    guiPollErr
                                )
                            end
                        end

                        if t - LastAutosave >= CONFIG.AutoSaveInterval then
                            LastAutosave = t

                            if MemoryGuard.level == "HIGH" then
                                runMemoryPrune("PRE_AUTOSAVE_HIGH", false)
                            elseif MemoryGuard.level == "CRITICAL" then
                                runMemoryPrune("PRE_AUTOSAVE_CRITICAL", true)
                            end

                            protectedStage("PERIODIC_MEMORY_SAVE", saveMemory)
                            updateMemoryGuard(true)
                        end

                        if t - LastConsoleStatus >= CONFIG.ConsoleStatusInterval then
                            LastConsoleStatus = t
                            print(
                                "[STA Stage 1 v1.1.7] STATUS"
                                .. " | Runtime=" .. tostring(math.floor(elapsed()))
                                .. "s | Objects=" .. tostring(Statistics.objectsObserved)
                                .. " | Semantic=" .. tostring(Statistics.semanticCandidates)
                                .. " | Prompts=" .. tostring(Statistics.promptDiscovered)
                                .. " | GUI=" .. tostring(Statistics.guiObserved)
                                .. " | GuiMode=" .. tostring(EXECUTOR.guiMode)
                                .. " | Clusters=" .. tostring(Statistics.resourceClustersCreated)
                                .. " | FPS~" .. tostring(math.floor(FpsEma + 0.5))
                                .. " | WorldQueue=" .. tostring(math.max(0, #DynamicWorldQueue - DynamicWorldHead + 1))
                                .. " | GuiQueue=" .. tostring(math.max(0, #DynamicGuiQueue - DynamicGuiHead + 1))
                                .. " | BurstPeak=" .. tostring(Statistics.streamingBurstPeak or 0)
                                .. " | Reclass=" .. tostring(Statistics.semanticReclassifications or 0)
                                .. " | BaseSamples=" .. tostring(BaseRegionModel.sampleCount or 0)
                                .. " | Day=" .. tostring(CurrentContext.day)
                                .. " | DaySrc=" .. tostring(CurrentContext.daySource)
                                .. " | Mem=" .. tostring(MemoryGuard.totalMb or "?") .. "MB"
                                .. " | MemLevel=" .. tostring(MemoryGuard.level)
                                .. " | MemPeak=" .. tostring(round(MemoryGuard.peakMb or 0, 1)) .. "MB"
                                .. " | PrunedW=" .. tostring(MemoryGuard.worldRecordsPruned or 0)
                                .. " | PrunedG=" .. tostring(MemoryGuard.guiRecordsPruned or 0)
                                .. " | ThrottledLogs="
                                .. tostring(
                                    (Statistics.throttledNumericLogs or 0)
                                    + (Statistics.throttledGuiTextLogs or 0)
                                )
                            )
                        end
                    end)
                    if not okTick then
                        reportRuntimeError("HEARTBEAT_TICK", tickErr)
                    end
                end)
            end)
            if not okHeartbeat then
                error("HEARTBEAT_CONNECT_FAILED | " .. tostring(heartbeatOrErr))
            end
            MainHeartbeatConnection = heartbeatOrErr

            checkpoint("11_STARTED")
            updateMobileControlVisuals()
            print("============================================================")
            print(" STA TRUE AI - STAGE 1 / 8")
            print(" SEMANTIC WORLD OBSERVER v1.1.7")
            print(" PASSIVE / READ-ONLY")
            print(" DELETE = STOP + SAVE")
            print("============================================================")
        end

        local ok, err = pcall(startupBody)
        if not ok then
            reportRuntimeError("START_OBSERVER_FATAL", err)
            cleanupPartialStart()
            print("[STA Stage 1 v1.1.7] START FAILED - send the START_CHECKPOINT + ERROR lines.")
            return
        end
    end

    stopObserver = function()
        if not Running then
            print("[STA Stage 1 v1.1.7] Observer is not running.")
            return
        end

        logLine("SECTION", "STA TRUE AI STAGE 1 FINISHING")
        updateContext()
        updateResourceClusters()

        logLine(
            "DISCOVERY_SUMMARY",
            "Objects=" .. tostring(Statistics.objectsObserved),
            "Preexisting=" .. tostring(Statistics.objectsPreexistingAtStart),
            "ObservedAfterStart=" .. tostring(Statistics.objectsObservedAfterStart),
            "Removed=" .. tostring(Statistics.objectsRemoved),
            "Reobserved=" .. tostring(Statistics.objectsReobserved),
            "Prompts=" .. tostring(Statistics.promptDiscovered),
            "GUI=" .. tostring(Statistics.guiObserved),
            "Clusters=" .. tostring(Statistics.resourceClustersCreated)
        )
        logLine("SESSION_DURATION", tostring(elapsed()))

        local memorySaved = saveMemory()
        flushLog()

        Running = false

        if MainHeartbeatConnection then
            pcall(function() MainHeartbeatConnection:Disconnect() end)
            MainHeartbeatConnection = nil
        end
        if CharacterConnection then
            pcall(function() CharacterConnection:Disconnect() end)
            CharacterConnection = nil
        end
        disconnectAll()

        updateMobileControlVisuals()
        print("[STA Stage 1 v1.1.7] STOPPED")
        print("[STA Stage 1 v1.1.7] LOG: " .. LOG_FILE)
        if memorySaved then
            print("[STA Stage 1 v1.1.7] MEMORY_SAVE_VERIFIED: " .. MEMORY_FILE)
        else
            warn("[STA Stage 1 v1.1.7] MEMORY_NOT_VERIFIED: " .. MEMORY_FILE)
        end
    end

    -- ============================================================
    -- MOBILE CALLBACK BINDING SELF-TEST
    -- ============================================================

    do
        local startType = type(startObserver)
        local stopType = type(stopObserver)

        if startType == "function" and stopType == "function" then
            print(
                "[STA Stage 1 v1.1.7] MOBILE_CALLBACK_BINDING_OK"
                .. " | startObserver=" .. startType
                .. " | stopObserver=" .. stopType
            )
        else
            warn(
                "[STA Stage 1 v1.1.7] MOBILE_CALLBACK_BINDING_FAIL"
                .. " | startObserver=" .. startType
                .. " | stopObserver=" .. stopType
            )
        end
    end

    -- ============================================================
    -- EXPORTED READ-ONLY INSPECTION HELPERS
    -- ============================================================

    ENV.STA_STAGE1_START = startObserver
    ENV.STA_STAGE1_STOP = stopObserver
    ENV.STA_STAGE1_WORLD_OBJECTS = function() return WorldObjects end
    ENV.STA_STAGE1_GUI_OBJECTS = function() return GuiObjects end
    ENV.STA_STAGE1_SEMANTIC_CANDIDATES = function() return SemanticCandidates end
    ENV.STA_STAGE1_RESOURCE_CLUSTERS = function() return ResourceClusters end
    ENV.STA_STAGE1_MEMORY_GUARD = function() return MemoryGuard end
    ENV.STA_STAGE1_ARCHIVED_ENTITIES = function() return ArchivedWorldEntities end
    ENV.STA_STAGE1_BASE_INFRASTRUCTURE = function() return BaseInfrastructure end
    ENV.STA_STAGE1_LOOT_CONTAINERS = function() return LootContainers end
    ENV.STA_STAGE1_STATISTICS = function() return Statistics end
    ENV.STA_STAGE1_SAVE = saveMemory
    ENV.STA_STAGE1_DEVICE = function() return DEVICE end
    ENV.STA_STAGE1_EXECUTOR_PROFILE = function() return EXECUTOR end
    ENV.STA_STAGE1_TARGETED_GUI_STATE =
        function() return TargetedGuiState end

    print("[STA Stage 1 v1.1.7] BOOTSTRAP_OK")

    if ENV.STA_STAGE1_CONTROL_CONNECTION then
        pcall(function() ENV.STA_STAGE1_CONTROL_CONNECTION:Disconnect() end)
    end

    do
        print("[STA Stage 1 v1.1.7] MODULE_START | CONTROL_BINDING")
        local okControl, connOrErr = pcall(function()
            return UserInputService.InputBegan:Connect(function(input)
                if input.KeyCode == Enum.KeyCode.Insert then
                    print("[STA Stage 1 v1.1.7] INPUT | INSERT")
                    local ok, err = pcall(startObserver)
                    if not ok then reportRuntimeError("CONTROL_INSERT", err) end
                elseif input.KeyCode == Enum.KeyCode.Delete then
                    print("[STA Stage 1 v1.1.7] INPUT | DELETE")
                    local ok, err = pcall(stopObserver)
                    if not ok then reportRuntimeError("CONTROL_DELETE", err) end
                end
            end)
        end)

        if okControl and connOrErr then
            ControlConnection = connOrErr
            ENV.STA_STAGE1_CONTROL_CONNECTION = ControlConnection
            print("[STA Stage 1 v1.1.7] MODULE_OK | CONTROL_BINDING")
        else
            reportRuntimeError("MODULE_FAIL:CONTROL_BINDING", connOrErr)
        end
    end

    if DEVICE.TouchEnabled then
        print("[STA Stage 1 v1.1.7] MODULE_START | MOBILE_TOUCH_UI")
        local okMobile, mobileResult, mobileDetail = pcall(createMobileControls)
        if okMobile and mobileResult then
            print("[STA Stage 1 v1.1.7] MODULE_OK | MOBILE_TOUCH_UI")
        else
            reportRuntimeError(
                "MODULE_FAIL:MOBILE_TOUCH_UI",
                okMobile and tostring(mobileDetail) or tostring(mobileResult)
            )
        end
    else
        print("[STA Stage 1 v1.1.7] MOBILE_TOUCH_UI | SKIPPED | TouchEnabled=false")
    end

    print("============================================================")
    print(" STA TRUE AI PROJECT - STAGE 1 / 8")
    print(" SEMANTIC WORLD OBSERVER v1.1.7 UNIVERSAL EXECUTOR")
    print(
        " EXECUTOR | " .. tostring(EXECUTOR.display)
        .. " | Family=" .. tostring(EXECUTOR.family)
        .. " | JSON=" .. tostring(EXECUTOR.jsonMode)
        .. " | GUI=" .. tostring(EXECUTOR.guiMode)
    )
    print(" DEVICE | Platform=" .. tostring(DEVICE.Platform)
        .. " | Touch=" .. tostring(DEVICE.TouchEnabled)
        .. " | Keyboard=" .. tostring(DEVICE.KeyboardEnabled)
        .. " | MobileProfile=" .. tostring(DEVICE.Mobile))
    print(" DESKTOP: INSERT = START | DELETE = STOP + SAVE")
    print(" MOBILE: use on-screen START / SAVE NOW / STOP + SAVE")
    print(" AUTOSAVE = EVERY 30 MINUTES")
    print(" MOBILE PERFORMANCE = ADAPTIVE FRAME-BUDGETED SCANNING")
    print(" SEMANTIC ACCURACY = CANONICAL ENTITIES + STREAMING RECLASSIFICATION")
    print(" MEMORY GUARD = ADAPTIVE THROTTLE + STREAMED-OBJECT RELEASE")
    print(" COREGUI POLICY = NEVER SCAN/REQUIRE ROBLOX LOCALE MODULES")
    print(" XENO GUI POLICY = TARGETED STATE ONLY / NO FULL PLAYERGUI WATCHERS")
    print(" INITIAL SAVE = LIGHTWEIGHT CHECKPOINT; FULL SAVE ON DELETE/30MIN")
    print("============================================================")

    if CONFIG.AutoStart then
        startObserver()
    end

    print("[STA Stage 1 v1.1.7] MODULE_OK | TOP_LEVEL_INIT")
end, __STA_STAGE1_FATAL_HANDLER)

if not __STA_STAGE1_TOP_OK then
    print("[STA Stage 1 v1.1.7] ABORTED_DURING_TOP_LEVEL_INIT")
end
