--[[
    STA TRUE AI PROJECT
    STAGE 1 / 8 - SEMANTIC WORLD OBSERVER v1.0.9 - POTASSIUM HARDENED

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


print("[STA Stage 1 v1.0.9] FILE_ENTRY_OK")

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
        warn("[STA Stage 1 v1.0.9] TOP_LEVEL_FATAL | " .. message)
    else
        print("[STA Stage 1 v1.0.9] TOP_LEVEL_FATAL | " .. message)
    end
    return message
end

local __STA_STAGE1_TOP_OK, __STA_STAGE1_TOP_ERR = xpcall(function()
    print("[STA Stage 1 v1.0.9] MODULE_START | TOP_LEVEL_INIT")
    local Players = game:GetService("Players")
    local Workspace = game:GetService("Workspace")
    local UserInputService = game:GetService("UserInputService")
    local RunService = game:GetService("RunService")
    local HttpService = game:GetService("HttpService")
    local CollectionService = game:GetService("CollectionService")
    local Lighting = game:GetService("Lighting")

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

    local VERSION = "Stage1-v1.0.9"
    local SCHEMA = "STA True AI - Semantic World Observer Stage 1 v1.0.9"

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
        CONFIG.InitialScanBatch = 120
        CONFIG.InitialScanYield = 0.035
        CONFIG.ObjectStateInterval = 1.25
        CONFIG.ClusterInterval = 4.0
        CONFIG.PlayerContextInterval = 0.75
        CONFIG.LogFlushSize = 120
    end

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

    local function reportRuntimeError(stage, err)
        local msg = "[STA Stage 1 v1.0.9 ERROR] " .. tostring(stage) .. " | " .. tostring(err)
        if type(warn) == "function" then
            warn(msg)
        else
            print(msg)
        end
    end

    local function protectedStage(stage, fn)
        local stageName = tostring(stage)
        local quiet = string.sub(stageName, 1, 9) == "PERIODIC_"

        if not quiet then
            print("[STA Stage 1 v1.0.9] MODULE_START | " .. stageName)
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
                "[STA Stage 1 v1.0.9] MODULE_OK | "
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

    local LOG_FILE = string.format("STA_STAGE1_WORLD_V109_%d.log", SessionUnix)
    local MEMORY_FILE = string.format("STA_STAGE1_WORLD_MEMORY_V109_%d.json", SessionUnix)

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

    local WorldObjects = {}
    local GuiObjects = {}
    local SemanticCandidates = {}
    local ResourceClusters = {}
    local BaseInfrastructure = {}
    local LootContainers = {}
    local Interactables = {}
    local UnknownObjects = {}
    local SignatureHistory = {}

    local LastObjectStateScan = 0
    local LastClusterScan = 0
    local LastContextScan = 0
    local LastAutosave = 0
    local LastConsoleStatus = 0

    local CurrentContext = {
        phase = nil,
        nearBase = nil,
        playerPosition = nil,
        day = nil,
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

    local function currentDay()
        local v = LocalPlayer:GetAttribute("HighestDay")
        if v ~= nil then return v end
        return nil
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

    local function logLine(kind, ...)
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

    local function disconnectAll()
        for _,conn in ipairs(Connections) do
            pcall(function() conn:Disconnect() end)
        end
        Connections = {}
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

    local function objectTextBlob(obj)
        local parts = {obj.Name, obj.ClassName}
        local attrs = getAttributes(obj)
        for k,v in pairs(attrs) do
            parts[#parts + 1] = tostring(k)
            if type(v) ~= "table" then parts[#parts + 1] = tostring(v) end
        end
        if obj:IsA("ProximityPrompt") then
            parts[#parts + 1] = obj.ActionText
            parts[#parts + 1] = obj.ObjectText
        end
        return normalizeText(table.concat(parts, " ")), attrs
    end

    local function classifyObject(obj)
        local candidates = {}
        local blob, attrs = objectTextBlob(obj)

        -- Loot containers: name-based hints.
        if containsText(blob, "supply drop crate") or (containsText(blob, "supply drop") and containsText(blob, "crate")) then
            addCandidate(candidates, "LOOT_SUPPLY_DROP_CRATE", 0.82, "NAME_OR_TEXT_HINT")
        end
        if containsText(blob, "emerald chest") then
            addCandidate(candidates, "LOOT_EMERALD_CHEST", 0.82, "NAME_OR_TEXT_HINT")
        end
        if containsText(blob, "default chest") or containsText(blob, "defult chest") then
            addCandidate(candidates, "LOOT_DEFAULT_CHEST", 0.80, "NAME_OR_TEXT_HINT")
        elseif containsText(blob, "chest") then
            addCandidate(candidates, "LOOT_CHEST_UNKNOWN_TYPE", 0.45, "GENERIC_CHEST_NAME_HINT")
        elseif containsText(blob, "crate") then
            addCandidate(candidates, "LOOT_CRATE_UNKNOWN_TYPE", 0.42, "GENERIC_CRATE_NAME_HINT")
        end

        -- Base infrastructure candidates.
        if containsText(blob, "fuel pump") then
            addCandidate(candidates, "INFRA_FUEL_PUMP", 0.82, "NAME_OR_TEXT_HINT")
        end
        if containsText(blob, "generator") then
            addCandidate(candidates, "INFRA_GENERATOR", 0.80, "NAME_OR_TEXT_HINT")
        end
        if containsText(blob, "healpad") or containsText(blob, "heal pad") then
            addCandidate(candidates, "INFRA_HEALPAD", 0.82, "NAME_OR_TEXT_HINT")
        end
        if (containsText(blob, "ammo") and containsText(blob, "craft")) or containsText(blob, "ammo bench") then
            addCandidate(candidates, "INFRA_AMMO_CRAFT", 0.84, "NAME_OR_TEXT_HINT")
        elseif containsText(blob, "craft") or containsText(blob, "workbench") then
            addCandidate(candidates, "INFRA_CRAFT", 0.66, "NAME_OR_TEXT_HINT")
        end

        -- Stronger attribute-driven resource hints when the game exposes them.
        local toolType = normalizeText(attrs.ToolType or attrs.ItemType or attrs.Category or attrs.Type or "")
        if toolType ~= "" then
            if containsText(toolType, "medical") then
                addCandidate(candidates, "RESOURCE_MEDICAL", 0.90, "EXPLICIT_TYPE_ATTRIBUTE")
            end
            if containsText(toolType, "food") then
                addCandidate(candidates, "RESOURCE_FOOD", 0.90, "EXPLICIT_TYPE_ATTRIBUTE")
            end
            if containsText(toolType, "fuel") then
                addCandidate(candidates, "RESOURCE_FUEL", 0.90, "EXPLICIT_TYPE_ATTRIBUTE")
            end
            if containsText(toolType, "ammo") or containsText(toolType, "ammunition") then
                addCandidate(candidates, "RESOURCE_AMMO", 0.90, "EXPLICIT_TYPE_ATTRIBUTE")
            end
            if containsText(toolType, "gun") or containsText(toolType, "melee") or containsText(toolType, "weapon") or containsText(toolType, "throwable") then
                addCandidate(candidates, "RESOURCE_WEAPON", 0.88, "EXPLICIT_TYPE_ATTRIBUTE")
            end
            if containsText(toolType, "scrap") then
                addCandidate(candidates, "RESOURCE_SCRAP", 0.90, "EXPLICIT_TYPE_ATTRIBUTE")
            end
        end

        -- Lower-confidence name hints. These remain candidates only.
        if containsText(blob, "fuel") or containsText(blob, "gas can") or containsText(blob, "gasoline") then
            if not containsText(blob, "fuel pump") then
                addCandidate(candidates, "RESOURCE_FUEL", 0.55, "NAME_HINT")
            end
        end
        if containsText(blob, "scrap") then
            addCandidate(candidates, "RESOURCE_SCRAP", 0.60, "NAME_HINT")
        end
        if containsText(blob, "ammo") or containsText(blob, "ammunition") then
            if not containsText(blob, "craft") then
                addCandidate(candidates, "RESOURCE_AMMO", 0.55, "NAME_HINT")
            end
        end
        if containsText(blob, "bandage") or containsText(blob, "medkit") or containsText(blob, "medical") then
            addCandidate(candidates, "RESOURCE_MEDICAL", 0.60, "NAME_HINT")
        end
        if containsText(blob, "food") or containsText(blob, "apple") or containsText(blob, "carrot") or containsText(blob, "bread") or containsText(blob, "meat") or containsText(blob, "canned") then
            addCandidate(candidates, "RESOURCE_FOOD", 0.52, "NAME_HINT")
        end

        if obj:IsA("Tool") then
            if toolType == "" then
                addCandidate(candidates, "RESOURCE_PORTABLE_ITEM_UNKNOWN", 0.30, "TOOL_CLASS")
            end
        end

        if obj:IsA("ProximityPrompt") then
            addCandidate(candidates, "INTERACTABLE_PROMPT", 0.98, "PROXIMITY_PROMPT_CLASS")
        end
        if obj:IsA("ClickDetector") then
            addCandidate(candidates, "INTERACTABLE_CLICK", 0.98, "CLICK_DETECTOR_CLASS")
        end

        return candidates
    end

    local function isResourceCategory(category)
        return string.sub(category or "", 1, 9) == "RESOURCE_"
    end

    local function isInfrastructureCategory(category)
        return string.sub(category or "", 1, 6) == "INFRA_"
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
    -- OBJECT SNAPSHOT / IDENTITY
    -- ============================================================

    local function shouldTrackObject(obj)
        if not obj or obj == game then return false end
        if obj:IsA("Terrain") then return true end
        if obj:IsA("Model") or obj:IsA("BasePart") or obj:IsA("Tool") or obj:IsA("Attachment") then return true end
        if obj:IsA("ProximityPrompt") or obj:IsA("ClickDetector") then return true end
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

        return {
            name = obj.Name,
            class = obj.ClassName,
            path = safeFullName(obj),
            parentPath = obj.Parent and safeFullName(obj.Parent) or nil,
            position = vectorToTable(pos),
            cframe = cframeToTable(cf),
            size = vectorToTable(size),
            distanceFromPlayer = pos and playerPos and round(distance(pos, playerPos), 2) or nil,
            attributes = attrs,
            tags = tags,
            directChildren = childrenSummary(obj),
            childCount = #obj:GetChildren(),
            descendantCount = #obj:GetDescendants(),
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

    local function registerSemanticRecord(runtimeId, candidates)
        if not candidates or #candidates == 0 then return end
        SemanticCandidates[runtimeId] = candidates
        for _,c in ipairs(candidates) do
            Statistics.semanticCandidates = Statistics.semanticCandidates + 1
            Statistics.byCategory[c.category] = (Statistics.byCategory[c.category] or 0) + 1
            if isInfrastructureCategory(c.category) then
                BaseInfrastructure[c.category] = BaseInfrastructure[c.category] or {}
                BaseInfrastructure[c.category][runtimeId] = true
            elseif isLootCategory(c.category) then
                LootContainers[c.category] = LootContainers[c.category] or {}
                LootContainers[c.category][runtimeId] = true
            end
            if c.category == "INTERACTABLE_PROMPT" or c.category == "INTERACTABLE_CLICK" then
                Interactables[runtimeId] = true
            end
        end
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
            connect(prompt:GetPropertyChangedSignal(prop):Connect(function()
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
            end))
        end
    end

    local function monitorValueObject(obj, runtimeId)
        if not obj:IsA("ValueBase") then return end
        connect(obj.Changed:Connect(function(value)
            if not Running then return end
            local rec = WorldObjects[runtimeId]
            if not rec or rec.removedAt then return end
            local old = rec.value
            local newValue = safeScalar(value)
            rec.value = newValue
            rec.lastSeenAt = elapsed()
            Statistics.valueChanges = Statistics.valueChanges + 1
            logLine("VALUE_CHANGED", runtimeId, safeFullName(obj), tostring(old), "->", tostring(newValue))
        end))
    end

    local function monitorAttributes(obj, runtimeId)
        connect(obj.AttributeChanged:Connect(function(attributeName)
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
            logLine("OBJECT_ATTRIBUTE_CHANGE", runtimeId, safeFullName(obj), attributeName, tostring(old), "->", tostring(newValue))
        end))
    end

    local function registerWorldObject(obj, preexisting)
        if not Running or not obj or not obj.Parent then return nil end
        if RuntimeByInstance[obj] then return RuntimeByInstance[obj] end
        if not shouldTrackObject(obj) then return nil end

        local snapshot = snapshotObject(obj)
        local runtimeId = nextObjectId()
        RuntimeByInstance[obj] = runtimeId

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
        record.firstObservedNearBase = currentNearBase()
        record.reobservedFromRuntimeId = reobservedFrom
        record.reobservationCount = reobservedFrom and 1 or 0
        record.removedAt = nil
        record.lastPositionVector = getPosition(obj)
        record.lastTags = arrayCopy(record.tags)
        record.lastAttributes = shallowCopy(record.attributes)
        record.importantForMovement = classificationImportant(record.semanticCandidates) or obj:IsA("Tool") or obj:IsA("Model")
        record.periodicRefresh = record.importantForMovement or #(record.tags or {}) > 0

        WorldObjects[runtimeId] = record
        SignatureHistory[snapshot.signature] = {runtimeId = runtimeId, removedAt = nil}

        Statistics.objectsObserved = Statistics.objectsObserved + 1
        Statistics.byClass[obj.ClassName] = (Statistics.byClass[obj.ClassName] or 0) + 1
        if preexisting then
            Statistics.objectsPreexistingAtStart = Statistics.objectsPreexistingAtStart + 1
        else
            Statistics.objectsObservedAfterStart = Statistics.objectsObservedAfterStart + 1
        end

        registerSemanticRecord(runtimeId, record.semanticCandidates)
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
                "NearBase=" .. boolString(record.firstObservedNearBase),
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
        if rec.signature then
            SignatureHistory[rec.signature] = {runtimeId = runtimeId, removedAt = rec.removedAt}
        end
        logLine("OBJECT_LOST_FROM_OBSERVATION", runtimeId, rec.class, rec.name, rec.path)
    end

    local function refreshWorldObject(obj, runtimeId)
        local rec = WorldObjects[runtimeId]
        if not rec or rec.removedAt or not obj.Parent then return end

        rec.lastSeenAt = elapsed()
        rec.path = safeFullName(obj)
        rec.parentPath = obj.Parent and safeFullName(obj.Parent) or nil

        local pos = getPosition(obj)
        local playerPos = currentPlayerPosition()
        rec.distanceFromPlayer = pos and playerPos and round(distance(pos, playerPos), 2) or nil

        if pos then
            if rec.lastPositionVector then
                local d = distance(pos, rec.lastPositionVector)
                if rec.importantForMovement and d >= CONFIG.ImportantMoveDistance then
                    Statistics.objectsMoved = Statistics.objectsMoved + 1
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
        return obj:IsA("ScreenGui") or obj:IsA("GuiObject")
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
            connect(obj:GetPropertyChangedSignal(prop):Connect(function()
                if not Running then return end
                local r = GuiObjects[runtimeId]
                if not r or r.removedAt then return end
                local old = r[key]
                local fresh = guiSnapshot(obj)
                local newValue = fresh[key]
                r[key] = newValue
                r.lastSeenAt = elapsed()
                Statistics.guiChanges = Statistics.guiChanges + 1
                logLine("GUI_CHANGED", runtimeId, rec.path, prop, tostring(old), "->", tostring(newValue))
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
            if not rec.removedAt and rec.position then
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
        local nearBaseNow = currentNearBase()

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
                        observedWhilePlayerNearBase = 0,
                        observedWhilePlayerAwayFromBase = 0,
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
                if nearBaseNow == true then
                    rec.observedWhilePlayerNearBase = rec.observedWhilePlayerNearBase + 1
                elseif nearBaseNow == false then
                    rec.observedWhilePlayerAwayFromBase = rec.observedWhilePlayerAwayFromBase + 1
                end

                rec.centerHistory[#rec.centerHistory + 1] = {
                    t = elapsed(),
                    center = vectorToTable(cluster.center),
                    count = #cluster.members,
                    playerNearBase = nearBaseNow,
                }
                while #rec.centerHistory > CONFIG.MaxClusterHistory do
                    table.remove(rec.centerHistory, 1)
                end

                local totalContext = rec.observedWhilePlayerNearBase + rec.observedWhilePlayerAwayFromBase
                local nearRatio = totalContext > 0 and (rec.observedWhilePlayerNearBase / totalContext) or 0
                if rec.maxCount >= 3 and rec.observations >= 3 and nearRatio >= 0.65 then
                    local baseConfidence = 0.35 + math.min(0.25, rec.observations * 0.015) + math.min(0.20, rec.maxCount * 0.02) + math.min(0.15, nearRatio * 0.15)
                    rec.semanticRoleCandidate = string.gsub(category, "RESOURCE_", "") .. "_STORAGE_CANDIDATE"
                    rec.semanticRoleConfidence = round(math.min(0.94, baseConfidence), 3)
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
        local day = currentDay()

        if CurrentContext.phase ~= nil and CurrentContext.phase ~= phase then
            logLine("TIME_PHASE_CHANGE", tostring(CurrentContext.phase), "->", tostring(phase), "Day=" .. tostring(day))
        end
        if CurrentContext.nearBase ~= nil and CurrentContext.nearBase ~= nearBase then
            logLine("PLAYER_NEAR_BASE_CHANGE", tostring(CurrentContext.nearBase), "->", tostring(nearBase))
        end

        CurrentContext.phase = phase
        CurrentContext.nearBase = nearBase
        CurrentContext.playerPosition = vectorToTable(pos)
        CurrentContext.day = day
    end

    -- ============================================================
    -- MEMORY BUILD / SAVE
    -- ============================================================

    local function sanitizeWorldObjects()
        local out = {}
        for id,rec in pairs(WorldObjects) do
            local copy = {}
            for k,v in pairs(rec) do
                if k ~= "lastPositionVector" and k ~= "lastTags" and k ~= "lastAttributes" and k ~= "importantForMovement" and k ~= "periodicRefresh" then
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
    local function jsonEscapeString(s)
        s = tostring(s)
        s = string.gsub(s, "\\", "\\\\")
        s = string.gsub(s, '"', '\\"')
        s = string.gsub(s, "\b", "\\b")
        s = string.gsub(s, "\f", "\\f")
        s = string.gsub(s, "\n", "\\n")
        s = string.gsub(s, "\r", "\\r")
        s = string.gsub(s, "\t", "\\t")

        -- Escape other ASCII control characters.
        s = string.gsub(s, "[%z\1-\31]", function(c)
            return string.format("\\u%04X", string.byte(c))
        end)

        return '"' .. s .. '"'
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
            currentContext = CurrentContext,
            statistics = Statistics,
            worldObjects = sanitizeWorldObjects(),
            semanticCandidates = SemanticCandidates,
            resourceClusters = ResourceClusters,
            baseInfrastructure = indexSetToArray(BaseInfrastructure),
            lootContainers = indexSetToArray(LootContainers),
            interactables = idSetToArray(Interactables),
            unknownObjects = idSetToArray(UnknownObjects),
            guiObjects = GuiObjects,
            semanticRules = {
                descendantAddedMeans = "FIRST_OBSERVED_NOT_CONFIRMED_SPAWN",
                classificationMeans = "CANDIDATE_NOT_PROOF",
                storageClustersMean = "LOCATION_CANDIDATE_NOT_CONFIRMED_STORAGE",
            },
        }
    end

    local function saveMemory()
        if not canWrite then
            local msg = "writefile unavailable or SaveToFile disabled"
            logLine("MEMORY_SAVE_FAIL", msg)
            warn("[STA Stage 1 v1.0.9] MEMORY_SAVE_FAIL | " .. msg)
            return false
        end

        local payload = buildMemory()
        resetJsonSanitizeStats()
        local safePayload = jsonSafe(payload, "$", {})

        local encoded = nil
        local encoderUsed = nil

        local okEncode, encodedOrErr = pcall(function()
            return HttpService:JSONEncode(safePayload)
        end)

        if okEncode and type(encodedOrErr) == "string" then
            encoded = encodedOrErr
            encoderUsed = "HttpService.JSONEncode"
        else
            local httpErr = tostring(encodedOrErr)
            warn(
                "[STA Stage 1 v1.0.9] JSON_HTTP_ENCODER_REJECTED"
                .. " | " .. httpErr
                .. " | Trying CUSTOM_JSON_ENCODER"
            )
            logLine("JSON_HTTP_ENCODER_REJECTED", httpErr)

            local okCustom, customOrErr = pcall(function()
                return customJsonEncode(safePayload, {})
            end)

            if okCustom and type(customOrErr) == "string" then
                encoded = customOrErr
                encoderUsed = "CUSTOM_JSON_ENCODER"
                print(
                    "[STA Stage 1 v1.0.9] JSON_CUSTOM_ENCODER_OK"
                    .. " | Bytes=" .. tostring(#encoded)
                )

                -- Validate the fallback output when JSONDecode is available.
                if type(HttpService.JSONDecode) == "function" then
                    local okDecode, decodeErr = pcall(function()
                        HttpService:JSONDecode(encoded)
                    end)
                    if okDecode then
                        print("[STA Stage 1 v1.0.9] JSON_CUSTOM_VALIDATION_OK")
                    else
                        local msg = "CUSTOM_JSON_VALIDATION | " .. tostring(decodeErr)
                        logLine("MEMORY_SAVE_FAIL", msg)
                        warn("[STA Stage 1 v1.0.9] MEMORY_SAVE_FAIL | " .. msg)
                        return false
                    end
                end
            else
                local msg =
                    "BOTH_JSON_ENCODERS_FAILED"
                    .. " | HTTP=" .. httpErr
                    .. " | CUSTOM=" .. tostring(customOrErr)

                logLine("MEMORY_SAVE_FAIL", msg)
                warn("[STA Stage 1 v1.0.9] MEMORY_SAVE_FAIL | " .. msg)

                for i,sample in ipairs(JsonSanitizeStats.samples) do
                    warn(
                        "[STA Stage 1 v1.0.9] JSON_SANITIZE_SAMPLE | #" .. tostring(i)
                        .. " | Path=" .. tostring(sample.path)
                        .. " | Kind=" .. tostring(sample.kind)
                        .. " | Detail=" .. tostring(sample.detail)
                    )
                end
                return false
            end
        end

        print("[STA Stage 1 v1.0.9] JSON_ENCODER_USED | " .. tostring(encoderUsed))

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
            print(
                "[STA Stage 1 v1.0.9] JSON_SANITIZE_SUMMARY"
                .. " | Converted=" .. tostring(JsonSanitizeStats.converted)
                .. " | NonFinite=" .. tostring(JsonSanitizeStats.nonFiniteNumbers)
                .. " | Unsupported=" .. tostring(JsonSanitizeStats.unsupportedValues)
                .. " | Cycles=" .. tostring(JsonSanitizeStats.cycles)
                .. " | KeyConversions=" .. tostring(JsonSanitizeStats.keyConversions)
                .. " | TableShapes=" .. tostring(JsonSanitizeStats.tableShapeConversions)
                .. " | KeyCollisions=" .. tostring(JsonSanitizeStats.keyCollisions)
            )
            for i,sample in ipairs(JsonSanitizeStats.samples) do
                print(
                    "[STA Stage 1 v1.0.9] JSON_SANITIZE_SAMPLE | #" .. tostring(i)
                    .. " | Path=" .. tostring(sample.path)
                    .. " | Kind=" .. tostring(sample.kind)
                    .. " | Detail=" .. tostring(sample.detail)
                )
            end
        end
        local okWrite, writeErr = pcall(function()
            writefile(MEMORY_FILE, encoded)
        end)

        if not okWrite then
            local msg = "WRITEFILE | " .. tostring(writeErr)
            logLine("MEMORY_SAVE_FAIL", msg)
            warn("[STA Stage 1 v1.0.9] MEMORY_SAVE_FAIL | " .. msg)
            return false
        end

        local verified = true
        local verifyDetail = "writefile returned successfully"

        if type(isfile) == "function" then
            local okIsFile, exists = pcall(function()
                return isfile(MEMORY_FILE)
            end)
            if not okIsFile or exists ~= true then
                verified = false
                verifyDetail = "isfile verification failed: " .. tostring(exists)
            end
        end

        if verified and type(readfile) == "function" then
            local okRead, readBack = pcall(function()
                return readfile(MEMORY_FILE)
            end)
            if not okRead then
                verified = false
                verifyDetail = "readfile verification failed: " .. tostring(readBack)
            elseif type(readBack) ~= "string" then
                verified = false
                verifyDetail = "readfile returned " .. type(readBack)
            elseif #readBack ~= #encoded then
                verified = false
                verifyDetail = "size mismatch expected=" .. tostring(#encoded) .. " actual=" .. tostring(#readBack)
            else
                verifyDetail = "verified bytes=" .. tostring(#readBack)
            end
        end

        if verified then
            logLine("MEMORY_SAVED", MEMORY_FILE, "Bytes=" .. tostring(#encoded), "Encoder=" .. tostring(encoderUsed), verifyDetail)
            print("[STA Stage 1 v1.0.9] MEMORY_SAVE_OK | " .. MEMORY_FILE .. " | Bytes=" .. tostring(#encoded) .. " | Encoder=" .. tostring(encoderUsed))
            return true
        end

        logLine("MEMORY_SAVE_FAIL", MEMORY_FILE, verifyDetail)
        warn("[STA Stage 1 v1.0.9] MEMORY_SAVE_FAIL | " .. MEMORY_FILE .. " | " .. verifyDetail)
        return false
    end

    -- ============================================================
    -- INITIAL SCANS / DYNAMIC DISCOVERY
    -- ============================================================

    local function scanWorkspaceInitial()
        local initial = Workspace:GetDescendants()
        logLine("INITIAL_SCAN_BEGIN", "WorkspaceDescendants=" .. tostring(#initial))
        for i,obj in ipairs(initial) do
            if Running then
                registerWorldObject(obj, true)
                if i % CONFIG.InitialScanBatch == 0 then
                    safeWait(CONFIG.InitialScanYield)
                end
            end
        end
        logLine("INITIAL_SCAN_END", "Tracked=" .. tostring(Statistics.objectsObserved))
    end

    local function scanGuiInitial()
        local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if not playerGui then return end
        local initial = playerGui:GetDescendants()
        for i,obj in ipairs(initial) do
            if Running then
                registerGui(obj, true)
                if i % CONFIG.InitialScanBatch == 0 then safeWait(CONFIG.InitialScanYield) end
            end
        end
    end

    local function connectDynamicDiscovery()
        connect(Workspace.DescendantAdded:Connect(function(obj)
            if not Running then return end
            safeDefer(function()
                if Running and obj.Parent then
                    registerWorldObject(obj, false)
                end
            end)
        end))

        connect(Workspace.DescendantRemoving:Connect(function(obj)
            if not Running then return end
            markWorldObjectRemoved(obj)
        end))

        local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if playerGui then
            connect(playerGui.DescendantAdded:Connect(function(obj)
                if not Running then return end
                safeDefer(function()
                    if Running and obj.Parent then registerGui(obj, false) end
                end)
            end))
            connect(playerGui.DescendantRemoving:Connect(function(obj)
                if not Running then return end
                markGuiRemoved(obj)
            end))
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
            print("[STA Stage 1 v1.0.9] MOBILE_INPUT | START")
            local ok, err = pcall(startObserver)
            if not ok then reportRuntimeError("MOBILE_START", err) end
            updateMobileControlVisuals()
        end)

        MobileSaveButton.Activated:Connect(function()
            print("[STA Stage 1 v1.0.9] MOBILE_INPUT | SAVE_NOW")
            local ok, result = pcall(saveMemory)
            if not ok then
                reportRuntimeError("MOBILE_SAVE", result)
            elseif result then
                print("[STA Stage 1 v1.0.9] MOBILE_SAVE_OK")
            else
                warn("[STA Stage 1 v1.0.9] MOBILE_SAVE_NOT_VERIFIED")
            end
            updateMobileControlVisuals()
        end)

        MobileStopButton.Activated:Connect(function()
            if not Running then return end
            print("[STA Stage 1 v1.0.9] MOBILE_INPUT | STOP_SAVE")
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
        print("[STA Stage 1 v1.0.9] MOBILE_UI_READY")
        return true, "OK"
    end

    -- ============================================================
    -- START / STOP
    -- ============================================================

    startObserver = function()
        if Running then
            print("[STA Stage 1 v1.0.9] Observer is already running.")
            return
        end

        print("[STA Stage 1 v1.0.9] MODULE_START | POTASSIUM_PREFLIGHT")
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
            {"appendfile", type(appendfile) == "function"},
        }
        local preflightFails = 0
        for _, item in ipairs(preflight) do
            local name, ok = item[1], item[2]
            if ok then
                print("[STA Stage 1 v1.0.9] PREFLIGHT_PASS | " .. tostring(name))
            else
                preflightFails = preflightFails + 1
                warn("[STA Stage 1 v1.0.9] PREFLIGHT_WARN | " .. tostring(name))
            end
        end
        print("[STA Stage 1 v1.0.9] MODULE_OK | POTASSIUM_PREFLIGHT | Warnings=" .. tostring(preflightFails))

        local function checkpoint(name)
            print("[STA Stage 1 v1.0.9] START_CHECKPOINT | " .. tostring(name))
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
            LOG_FILE = string.format("STA_STAGE1_WORLD_V109_%d.log", SessionUnix)
            MEMORY_FILE = string.format("STA_STAGE1_WORLD_MEMORY_V109_%d.json", SessionUnix)

            checkpoint("02_RESET_MEMORY")
            LogBuffer = {}
            Connections = {}
            ObjectCounter = 0
            GuiCounter = 0
            ClusterCounter = 0
            RuntimeByInstance = setmetatable({}, {__mode = "k"})
            GuiRuntimeByInstance = setmetatable({}, {__mode = "k"})
            WorldObjects = {}
            GuiObjects = {}
            SemanticCandidates = {}
            ResourceClusters = {}
            BaseInfrastructure = {}
            LootContainers = {}
            Interactables = {}
            UnknownObjects = {}
            SignatureHistory = {}
            CurrentContext = {phase=nil, nearBase=nil, playerPosition=nil, day=nil}
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
            print("[STA Stage 1 v1.0.9] MODULE_START | INITIAL_SCAN_THREAD")
            local spawnOk, spawnErr = pcall(function()
                safeSpawn(function()
                    protectedStage("INITIAL_WORKSPACE_SCAN", scanWorkspaceInitial)
                    protectedStage("INITIAL_GUI_SCAN", scanGuiInitial)
                    protectedStage("INITIAL_RESOURCE_CLUSTER_SCAN", updateResourceClusters)
                    protectedStage("INITIAL_MEMORY_SAVE", saveMemory)
                    print("[STA Stage 1 v1.0.9] MODULE_OK | INITIAL_SCAN_THREAD")
                end)
            end)
            if not spawnOk then
                reportRuntimeError("MODULE_FAIL:INITIAL_SCAN_THREAD", spawnErr)
            end

            checkpoint("09_TIMERS")
            LastObjectStateScan = now()
            LastClusterScan = now()
            LastContextScan = now()
            LastAutosave = now()
            LastConsoleStatus = now()

            checkpoint("10_HEARTBEAT_CONNECT")
            local okHeartbeat, heartbeatOrErr = pcall(function()
                return RunService.Heartbeat:Connect(function()
                    if not Running then return end
                    local okTick, tickErr = pcall(function()
                        local t = now()

                        if t - LastObjectStateScan >= CONFIG.ObjectStateInterval then
                            LastObjectStateScan = t
                            for obj,runtimeId in pairs(RuntimeByInstance) do
                                if obj and obj.Parent then
                                    local rec = WorldObjects[runtimeId]
                                    if rec and rec.periodicRefresh then
                                        local okRefresh, refreshErr = pcall(refreshWorldObject, obj, runtimeId)
                                        if not okRefresh then
                                            reportRuntimeError("PERIODIC_OBJECT_REFRESH:" .. tostring(runtimeId), refreshErr)
                                        end
                                    end
                                end
                            end
                        end

                        if t - LastClusterScan >= CONFIG.ClusterInterval then
                            LastClusterScan = t
                            protectedStage("PERIODIC_RESOURCE_CLUSTER_SCAN", updateResourceClusters)
                        end

                        if t - LastContextScan >= CONFIG.PlayerContextInterval then
                            LastContextScan = t
                            protectedStage("PERIODIC_UPDATE_CONTEXT", updateContext)
                        end

                        if t - LastAutosave >= CONFIG.AutoSaveInterval then
                            LastAutosave = t
                            protectedStage("PERIODIC_MEMORY_SAVE", saveMemory)
                        end

                        if t - LastConsoleStatus >= CONFIG.ConsoleStatusInterval then
                            LastConsoleStatus = t
                            print(
                                "[STA Stage 1 v1.0.9] STATUS"
                                .. " | Runtime=" .. tostring(math.floor(elapsed()))
                                .. "s | Objects=" .. tostring(Statistics.objectsObserved)
                                .. " | Semantic=" .. tostring(Statistics.semanticCandidates)
                                .. " | Prompts=" .. tostring(Statistics.promptDiscovered)
                                .. " | GUI=" .. tostring(Statistics.guiObserved)
                                .. " | Clusters=" .. tostring(Statistics.resourceClustersCreated)
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
            print(" SEMANTIC WORLD OBSERVER v1.0.9")
            print(" PASSIVE / READ-ONLY")
            print(" DELETE = STOP + SAVE")
            print("============================================================")
        end

        local ok, err = pcall(startupBody)
        if not ok then
            reportRuntimeError("START_OBSERVER_FATAL", err)
            cleanupPartialStart()
            print("[STA Stage 1 v1.0.9] START FAILED - send the START_CHECKPOINT + ERROR lines.")
            return
        end
    end

    stopObserver = function()
        if not Running then
            print("[STA Stage 1 v1.0.9] Observer is not running.")
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
        print("[STA Stage 1 v1.0.9] STOPPED")
        print("[STA Stage 1 v1.0.9] LOG: " .. LOG_FILE)
        if memorySaved then
            print("[STA Stage 1 v1.0.9] MEMORY_SAVE_VERIFIED: " .. MEMORY_FILE)
        else
            warn("[STA Stage 1 v1.0.9] MEMORY_NOT_VERIFIED: " .. MEMORY_FILE)
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
                "[STA Stage 1 v1.0.9] MOBILE_CALLBACK_BINDING_OK"
                .. " | startObserver=" .. startType
                .. " | stopObserver=" .. stopType
            )
        else
            warn(
                "[STA Stage 1 v1.0.9] MOBILE_CALLBACK_BINDING_FAIL"
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
    ENV.STA_STAGE1_BASE_INFRASTRUCTURE = function() return BaseInfrastructure end
    ENV.STA_STAGE1_LOOT_CONTAINERS = function() return LootContainers end
    ENV.STA_STAGE1_STATISTICS = function() return Statistics end
    ENV.STA_STAGE1_SAVE = saveMemory
    ENV.STA_STAGE1_DEVICE = function() return DEVICE end

    print("[STA Stage 1 v1.0.9] BOOTSTRAP_OK")

    if ENV.STA_STAGE1_CONTROL_CONNECTION then
        pcall(function() ENV.STA_STAGE1_CONTROL_CONNECTION:Disconnect() end)
    end

    do
        print("[STA Stage 1 v1.0.9] MODULE_START | CONTROL_BINDING")
        local okControl, connOrErr = pcall(function()
            return UserInputService.InputBegan:Connect(function(input)
                if input.KeyCode == Enum.KeyCode.Insert then
                    print("[STA Stage 1 v1.0.9] INPUT | INSERT")
                    local ok, err = pcall(startObserver)
                    if not ok then reportRuntimeError("CONTROL_INSERT", err) end
                elseif input.KeyCode == Enum.KeyCode.Delete then
                    print("[STA Stage 1 v1.0.9] INPUT | DELETE")
                    local ok, err = pcall(stopObserver)
                    if not ok then reportRuntimeError("CONTROL_DELETE", err) end
                end
            end)
        end)

        if okControl and connOrErr then
            ControlConnection = connOrErr
            ENV.STA_STAGE1_CONTROL_CONNECTION = ControlConnection
            print("[STA Stage 1 v1.0.9] MODULE_OK | CONTROL_BINDING")
        else
            reportRuntimeError("MODULE_FAIL:CONTROL_BINDING", connOrErr)
        end
    end

    if DEVICE.TouchEnabled then
        print("[STA Stage 1 v1.0.9] MODULE_START | MOBILE_TOUCH_UI")
        local okMobile, mobileResult, mobileDetail = pcall(createMobileControls)
        if okMobile and mobileResult then
            print("[STA Stage 1 v1.0.9] MODULE_OK | MOBILE_TOUCH_UI")
        else
            reportRuntimeError(
                "MODULE_FAIL:MOBILE_TOUCH_UI",
                okMobile and tostring(mobileDetail) or tostring(mobileResult)
            )
        end
    else
        print("[STA Stage 1 v1.0.9] MOBILE_TOUCH_UI | SKIPPED | TouchEnabled=false")
    end

    print("============================================================")
    print(" STA TRUE AI PROJECT - STAGE 1 / 8")
    print(" SEMANTIC WORLD OBSERVER v1.0.9 UNIVERSAL")
    print(" DEVICE | Platform=" .. tostring(DEVICE.Platform)
        .. " | Touch=" .. tostring(DEVICE.TouchEnabled)
        .. " | Keyboard=" .. tostring(DEVICE.KeyboardEnabled)
        .. " | MobileProfile=" .. tostring(DEVICE.Mobile))
    print(" DESKTOP: INSERT = START | DELETE = STOP + SAVE")
    print(" MOBILE: use on-screen START / SAVE NOW / STOP + SAVE")
    print(" AUTOSAVE = EVERY 30 MINUTES")
    print("============================================================")

    if CONFIG.AutoStart then
        startObserver()
    end

    print("[STA Stage 1 v1.0.9] MODULE_OK | TOP_LEVEL_INIT")
end, __STA_STAGE1_FATAL_HANDLER)

if not __STA_STAGE1_TOP_OK then
    print("[STA Stage 1 v1.0.9] ABORTED_DURING_TOP_LEVEL_INIT")
end
