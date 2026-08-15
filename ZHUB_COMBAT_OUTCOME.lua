--[[
ZHUB COMBAT OUTCOME CORRELATOR v2.2 — UNIVERSAL MOBILE + DESKTOP / TARGET AWARE / AUTOSAVE

Purpose:
  Passive correlation of NATURAL client combat traffic with NPC Humanoid health
  changes so the future ZHUB Intelligence Core can learn real weapon outcomes.

Hard boundaries:
  * Generated server calls: 0
  * No attributes/upvalues/callback results are modified
  * No movement modification
  * No protected/authorization bypass
  * Original game calls are forwarded unchanged before any Instance inspection

Important:
  Do NOT run the broad Deep Scanner at the same time. Previous testing showed
  hook/listener interference between simultaneous broad scanners.

Controls:
  DESKTOP: F7 = manual checkpoint | RightShift = show/hide HUD
  TOUCH/MOBILE: on-screen SAVE NOW / STOP + SAVE / collapse controls

Autosave:
  every 150 seconds on desktop and mobile

Mobile policy:
  * Touch UI is enabled whenever TouchEnabled=true.
  * A touchscreen laptop is not treated as a low-power mobile device when a
    keyboard is present.
  * Mobile HUD refresh is slightly gentler; combat evidence collection is the
    same event-driven model as desktop.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

local LP = Players.LocalPlayer
local PG = LP:WaitForChild("PlayerGui")
local ENV = type(getgenv) == "function" and getgenv() or _G

local OLD_KEY = "ZHUB_COMBAT_OUTCOME_CORRELATOR_v2_1"
local KEY = "ZHUB_COMBAT_OUTCOME_CORRELATOR_v2_2"
local BROKER_KEY = "ZHUB_PASSIVE_NAMECALL_BROKER_v1"

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

-- Match the established Stage-1 policy: a touchscreen Windows laptop should
-- receive touch controls, but should not be classified as a low-power phone.
DEVICE.Mobile = DEVICE.TouchEnabled and not DEVICE.KeyboardEnabled

-- Clean either the previous v2.1 session or an already-running v2.2 session
-- before installing this observer, preventing duplicate passive listeners.
if type(ENV[OLD_KEY]) == "table" and type(ENV[OLD_KEY].Cleanup) == "function" then
    pcall(ENV[OLD_KEY].Cleanup)
end
if type(ENV[KEY]) == "table" and type(ENV[KEY].Cleanup) == "function" then
    pcall(ENV[KEY].Cleanup)
end

local C = {
    Running = true,
    TraceEnabled = true,
    StartedClock = os.clock(),
    AutoSaveSeconds = 150,
    Connections = {},
    Gui = nil,
    Device = DEVICE,
    LastSaveStatus = "NOT SAVED YET",

    NextCallId = 0,
    NextHealthId = 0,
    NextCorrelationId = 0,
    NextBurstId = 0,

    Calls = {},
    HealthChanges = {},
    Correlations = {},
    Bursts = {},
    TargetHealth = {},
    WatchedHumanoids = {},
    WeaponStats = {},

    Limits = {
        Calls = 12000,
        HealthChanges = 12000,
        Correlations = 8000,
        Bursts = 2500,
        SamplesPerWeapon = 250,
    },

    Stats = {
        Calls = 0,
        DamageCandidateCalls = 0,
        HealthChanges = 0,
        DamageChanges = 0,
        HealingChanges = 0,
        Correlations = 0,
        Kills = 0,
        ProjectileHits = 0,
        HitTargets = 0,
        ShootCalls = 0,
        SwingCalls = 0,
        Autosaves = 0,
        ManualSaves = 0,
    },
}
ENV[KEY] = C

local function safeSpawn(fn, ...)
    local args = table.pack(...)
    if type(task) == "table" and type(task.defer) == "function" then
        task.defer(function()
            local ok, err = pcall(fn, table.unpack(args, 1, args.n))
            if not ok then
                warn("[ZHUB COMBAT v2.2] deferred error:", tostring(err))
            end
        end)
    else
        coroutine.wrap(function()
            local ok, err = pcall(fn, table.unpack(args, 1, args.n))
            if not ok then
                warn("[ZHUB COMBAT v2.2] deferred error:", tostring(err))
            end
        end)()
    end
end

local function safeWait(seconds)
    if type(task) == "table" and type(task.wait) == "function" then
        return task.wait(seconds)
    end
    return wait(seconds)
end

local function track(connection)
    if typeof(connection) == "RBXScriptConnection" then
        table.insert(C.Connections, connection)
    end
    return connection
end

local function relTime(clockValue)
    return clockValue - C.StartedClock
end

local function now()
    return relTime(os.clock())
end

local function pathOf(instance)
    if typeof(instance) ~= "Instance" then
        return tostring(instance)
    end
    local ok, value = pcall(function()
        return instance:GetFullName()
    end)
    if ok then
        return value
    end
    local okName, name = pcall(function()
        return instance.Name
    end)
    return okName and name or "<Instance>"
end

local function simpleAttributes(instance)
    local out = {}
    if typeof(instance) ~= "Instance" then
        return out
    end
    pcall(function()
        for key, value in pairs(instance:GetAttributes()) do
            local t = typeof(value)
            if t == "string" or t == "boolean" or t == "number" then
                out[key] = value
            end
        end
    end)
    return out
end

local function snap(value, depth, seen)
    depth = depth or 0
    seen = seen or {}

    local t = typeof(value)
    if t == "nil" then
        return { type = "nil" }
    end
    if t == "string" or t == "boolean" or t == "number" then
        return value
    end
    if t == "Vector3" then
        return { type = "Vector3", x = value.X, y = value.Y, z = value.Z }
    end
    if t == "Vector2" then
        return { type = "Vector2", x = value.X, y = value.Y }
    end
    if t == "CFrame" then
        local p = value.Position
        return { type = "CFrame", x = p.X, y = p.Y, z = p.Z }
    end
    if t == "Instance" then
        local className = "Instance"
        local name = "?"
        pcall(function() className = value.ClassName end)
        pcall(function() name = value.Name end)
        return {
            type = "Instance",
            class = className,
            name = name,
            path = pathOf(value),
            attrs = simpleAttributes(value),
        }
    end
    if t == "table" then
        if seen[value] then
            return { type = "table", cycle = true }
        end
        if depth >= 5 then
            return { type = "table", maxDepth = true }
        end

        seen[value] = true
        local out = { type = "table", count = 0, entries = {} }
        local count = 0
        for key, item in pairs(value) do
            count = count + 1
            out.count = count
            if count > 100 then
                out.truncated = true
                break
            end
            out.entries[tostring(key)] = snap(item, depth + 1, seen)
        end
        seen[value] = nil
        return out
    end

    return { type = t, text = tostring(value) }
end

local function packSnap(pack)
    local out = { n = pack.n or 0, values = {} }
    local count = math.min(pack.n or 0, 12)
    for i = 1, count do
        out.values[tostring(i)] = snap(pack[i], 0, {})
    end
    if (pack.n or 0) > count then
        out.truncated = true
    end
    return out
end

local function trimArray(array, maxCount)
    while #array > maxCount do
        table.remove(array, 1)
    end
end

local function classifyCall(remotePath)
    local lower = string.lower(remotePath or "")

    if string.find(lower, "projectilehit", 1, true) then
        return "PROJECTILE_HIT", true, 100
    end
    if string.find(lower, "hittargets", 1, true) then
        return "HIT_TARGETS", true, 98
    end
    if string.find(lower, "detonate", 1, true) then
        return "DETONATE", true, 92
    end
    if string.find(lower, "shoot", 1, true) then
        return "SHOOT", true, 78
    end
    if string.find(lower, "swing", 1, true) then
        return "SWING", true, 68
    end
    if string.find(lower, "throwremote", 1, true) then
        return "THROW", false, 25
    end
    if string.find(lower, "quickdraw", 1, true) then
        return "QUICKDRAW", false, 20
    end
    if string.find(lower, "chargeremote", 1, true) then
        return "CHARGE_REMOTE", false, 15
    end
    if string.find(lower, "reload", 1, true) then
        return "RELOAD", false, 5
    end
    if string.find(lower, "syncammo", 1, true) then
        return "SYNC_AMMO", false, 5
    end
    if string.find(lower, "counter", 1, true) then
        return "COUNTER", false, 10
    end
    if string.find(lower, "charge", 1, true) then
        return "CHARGE", false, 10
    end
    if string.find(lower, "power", 1, true) then
        return "POWER", false, 10
    end

    return nil, false, 0
end

local function modelForInstance(instance)
    if typeof(instance) ~= "Instance" then
        return nil
    end

    if instance:IsA("Humanoid") then
        return instance.Parent
    end
    if instance:IsA("Model") then
        return instance
    end

    local ok, model = pcall(function()
        return instance:FindFirstAncestorOfClass("Model")
    end)
    return ok and model or nil
end

local function collectTargetHints(value, hints, seenHints, depth, seenTables)
    depth = depth or 0
    seenTables = seenTables or {}
    if depth > 4 then
        return
    end

    local t = typeof(value)
    if t == "Instance" then
        local instancePath = pathOf(value)
        local model = modelForInstance(value)
        local modelPath = model and pathOf(model) or nil

        local key = modelPath or instancePath
        if key and not seenHints[key] then
            seenHints[key] = true
            hints[#hints + 1] = {
                path = instancePath,
                modelPath = modelPath,
                class = value.ClassName,
                name = value.Name,
            }
        end
        return
    end

    if t ~= "table" then
        return
    end
    if seenTables[value] then
        return
    end
    seenTables[value] = true

    local count = 0
    for key, item in pairs(value) do
        count = count + 1
        if count > 80 then
            break
        end
        collectTargetHints(key, hints, seenHints, depth + 1, seenTables)
        collectTargetHints(item, hints, seenHints, depth + 1, seenTables)
    end

    seenTables[value] = nil
end

local function targetHintsFromPack(pack)
    local hints = {}
    local seenHints = {}
    local seenTables = {}
    local count = math.min(pack.n or 0, 12)
    for i = 1, count do
        collectTargetHints(pack[i], hints, seenHints, 0, seenTables)
    end
    return hints
end

local function remoteWeaponKey(remote, callKind)
    if typeof(remote) == "Instance" then
        local remotePathLower = string.lower(pathOf(remote))
        if string.find(remotePathLower, "quickdraw", 1, true) then
            return "ABILITY:Quickdraw", nil
        end


        local ok, tool = pcall(function()
            return remote:FindFirstAncestorOfClass("Tool")
        end)
        if ok and tool then
            return tool.Name, pathOf(tool)
        end
    end

    if callKind == "QUICKDRAW" then
        return "ABILITY:Quickdraw", nil
    end

    local char = LP.Character
    if char then
        local tool = char:FindFirstChildOfClass("Tool")
        if tool then
            return tool.Name, pathOf(tool)
        end
    end

    return "UNKNOWN", nil
end

local function playerState()
    local char = LP.Character
    if not char then
        return {}
    end

    local root = char:FindFirstChild("HumanoidRootPart")
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    local tool = char:FindFirstChildOfClass("Tool")

    local state = {
        hp = humanoid and humanoid.Health or nil,
        tool = tool and tool.Name or nil,
    }

    if root then
        state.pos = { x = root.Position.X, y = root.Position.Y, z = root.Position.Z }
        state.vel = {
            x = root.AssemblyLinearVelocity.X,
            y = root.AssemblyLinearVelocity.Y,
            z = root.AssemblyLinearVelocity.Z,
        }
    end

    return state
end

local function targetSnapshot(humanoid)
    local model = humanoid and humanoid.Parent or nil
    local root = nil
    if model and model:IsA("Model") then
        root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
    end

    local out = {
        target = model and pathOf(model) or "?",
        targetName = model and model.Name or "?",
        humanoidPath = humanoid and pathOf(humanoid) or "?",
        health = humanoid and humanoid.Health or nil,
        maxHealth = humanoid and humanoid.MaxHealth or nil,
        humanoidAttrs = humanoid and simpleAttributes(humanoid) or {},
        modelAttrs = model and simpleAttributes(model) or {},
    }

    if root then
        out.pos = { x = root.Position.X, y = root.Position.Y, z = root.Position.Z }
    end

    return out
end

local function getWeaponStats(key)
    key = key or "UNKNOWN"
    local stats = C.WeaponStats[key]
    if not stats then
        stats = {
            weapon = key,
            protocolCalls = 0,
            shootCalls = 0,
            projectileHitCalls = 0,
            hitTargetsCalls = 0,
            correlatedHits = 0,
            totalDamage = 0,
            minDamage = nil,
            maxDamage = nil,
            kills = 0,
            targets = {},
            samples = {},
        }
        C.WeaponStats[key] = stats
    end
    return stats
end

local function addWeaponCall(call)
    local stats = getWeaponStats(call.weaponKey)
    stats.protocolCalls = stats.protocolCalls + 1

    if call.kind == "SHOOT" then
        stats.shootCalls = stats.shootCalls + 1
    elseif call.kind == "PROJECTILE_HIT" then
        stats.projectileHitCalls = stats.projectileHitCalls + 1
    elseif call.kind == "HIT_TARGETS" then
        stats.hitTargetsCalls = stats.hitTargetsCalls + 1
    end
end

local function createOrExtendBurst(call)
    if not call.damageCandidate then
        return nil
    end

    local previous = C.Bursts[#C.Bursts]
    local burst = nil

    if previous
        and previous.weapon == call.weaponKey
        and call.tStart - previous.endTime <= 1.0 then
        burst = previous
    else
        C.NextBurstId = C.NextBurstId + 1
        burst = {
            id = C.NextBurstId,
            weapon = call.weaponKey,
            startTime = call.tStart,
            endTime = call.tEnd,
            callIds = {},
            damage = 0,
            hits = 0,
            kills = 0,
            targets = {},
        }
        C.Bursts[#C.Bursts + 1] = burst
        trimArray(C.Bursts, C.Limits.Bursts)
    end

    burst.endTime = math.max(burst.endTime or call.tEnd, call.tEnd)
    burst.callIds[#burst.callIds + 1] = call.id
    call.burstId = burst.id
    return burst
end

local function findBurstById(id)
    if not id then
        return nil
    end
    for i = #C.Bursts, 1, -1 do
        if C.Bursts[i].id == id then
            return C.Bursts[i]
        end
    end
    return nil
end

local function targetHintScore(call, healthChange)
    local targetPath = healthChange.target
    if type(targetPath) ~= "string" then
        return 0, false
    end

    for _, hint in ipairs(call.targetHints or {}) do
        local modelPath = hint.modelPath
        local instancePath = hint.path

        if modelPath == targetPath then
            return 60, true
        end
        if instancePath == targetPath then
            return 55, true
        end
        if type(instancePath) == "string"
            and string.sub(instancePath, 1, #targetPath + 1) == targetPath .. "." then
            return 50, true
        end
        if type(modelPath) == "string"
            and string.sub(modelPath, 1, #targetPath + 1) == targetPath .. "." then
            return 50, true
        end
    end

    return 0, false
end

local function scoreCandidate(call, healthChange)
    if not call.damageCandidate then
        return nil
    end
    if healthChange.delta >= 0 then
        return nil
    end

    local dt = healthChange.t - call.tStart
    if dt < -0.08 or dt > 1.35 then
        return nil
    end

    local score = call.priority or 0
    local hintScore, targetMatched = targetHintScore(call, healthChange)
    score = score + hintScore

    -- Prefer causal-looking short delays but keep a wider window for InvokeServer.
    if dt >= 0 and dt <= 0.20 then
        score = score + 28
    elseif dt <= 0.55 then
        score = score + 20
    elseif dt <= 0.90 then
        score = score + 10
    else
        score = score + 2
    end

    -- A ProjectileHit/HitTargets with an explicit matching target is strongest.
    if targetMatched and (call.kind == "PROJECTILE_HIT" or call.kind == "HIT_TARGETS") then
        score = score + 35
    end

    return score, dt, targetMatched
end

local function updateOutcomeLearning(call, healthChange, correlation)
    local damage = math.max(0, -(healthChange.delta or 0))
    if damage <= 0 then
        return
    end

    local stats = getWeaponStats(call.weaponKey)
    stats.correlatedHits = stats.correlatedHits + 1
    stats.totalDamage = stats.totalDamage + damage
    stats.minDamage = stats.minDamage and math.min(stats.minDamage, damage) or damage
    stats.maxDamage = stats.maxDamage and math.max(stats.maxDamage, damage) or damage
    stats.targets[healthChange.target or "?"] = true

    local killed = (healthChange.new or math.huge) <= 0
    if killed then
        stats.kills = stats.kills + 1
        C.Stats.Kills = C.Stats.Kills + 1
    end

    stats.samples[#stats.samples + 1] = {
        t = healthChange.t,
        damage = damage,
        target = healthChange.target,
        callId = call.id,
        callKind = call.kind,
        deltaT = correlation.deltaT,
        targetMatched = correlation.targetMatched,
        killed = killed,
    }
    trimArray(stats.samples, C.Limits.SamplesPerWeapon)

    local burst = findBurstById(call.burstId)
    if burst then
        burst.damage = burst.damage + damage
        burst.hits = burst.hits + 1
        if killed then
            burst.kills = burst.kills + 1
        end
        burst.targets[healthChange.target or "?"] = true
        burst.endTime = math.max(burst.endTime or healthChange.t, healthChange.t)
    end
end

local function attachCorrelation(call, healthChange, score, dt, targetMatched)
    if healthChange.correlationId then
        return nil
    end

    C.NextCorrelationId = C.NextCorrelationId + 1
    local correlation = {
        id = C.NextCorrelationId,
        t = healthChange.t,
        callId = call.id,
        healthId = healthChange.id,
        weapon = call.weaponKey,
        callKind = call.kind,
        remotePath = call.path,
        target = healthChange.target,
        oldHealth = healthChange.old,
        newHealth = healthChange.new,
        damage = math.max(0, -(healthChange.delta or 0)),
        deltaT = dt,
        score = score,
        targetMatched = targetMatched,
        burstId = call.burstId,
    }

    healthChange.correlationId = correlation.id
    call.correlatedHealthIds = call.correlatedHealthIds or {}
    call.correlatedHealthIds[#call.correlatedHealthIds + 1] = healthChange.id

    C.Correlations[#C.Correlations + 1] = correlation
    C.Stats.Correlations = C.Stats.Correlations + 1
    trimArray(C.Correlations, C.Limits.Correlations)

    updateOutcomeLearning(call, healthChange, correlation)
    return correlation
end

local function correlateHealth(healthChange)
    if healthChange.correlationId or healthChange.delta >= 0 then
        return false
    end

    local bestCall = nil
    local bestScore = nil
    local bestDt = nil
    local bestTargetMatched = false

    for i = #C.Calls, math.max(1, #C.Calls - 120), -1 do
        local call = C.Calls[i]
        local roughDt = healthChange.t - call.tStart
        if roughDt > 1.35 then
            break
        end

        local score, dt, targetMatched = scoreCandidate(call, healthChange)
        if score and (not bestScore or score > bestScore) then
            bestCall = call
            bestScore = score
            bestDt = dt
            bestTargetMatched = targetMatched
        end
    end

    if bestCall then
        attachCorrelation(bestCall, healthChange, bestScore, bestDt, bestTargetMatched)
        return true
    end
    return false
end

local function reconcileForCall(call)
    if not call.damageCandidate then
        return
    end

    -- Handles the InvokeServer case where HealthChanged may fire while the
    -- original call is still waiting for its return value.
    for i = #C.HealthChanges, math.max(1, #C.HealthChanges - 100), -1 do
        local healthChange = C.HealthChanges[i]
        if not healthChange.correlationId and healthChange.delta < 0 then
            local dt = healthChange.t - call.tStart
            if dt >= -0.08 and dt <= 1.35 then
                correlateHealth(healthChange)
            elseif dt < -0.08 then
                break
            end
        end
    end
end

local function isPlayerHumanoid(humanoid)
    local model = humanoid and humanoid.Parent or nil
    if not model then
        return false
    end
    local ok, player = pcall(function()
        return Players:GetPlayerFromCharacter(model)
    end)
    return ok and player ~= nil
end

local function watchHumanoid(humanoid)
    if not humanoid or not humanoid:IsA("Humanoid") then
        return
    end
    if C.WatchedHumanoids[humanoid] then
        return
    end
    if isPlayerHumanoid(humanoid) then
        return
    end

    local model = humanoid.Parent
    if not model then
        return
    end

    C.WatchedHumanoids[humanoid] = true
    C.TargetHealth[humanoid] = humanoid.Health

    track(humanoid.HealthChanged:Connect(function(newHealth)
        if not C.Running then
            return
        end

        local oldHealth = C.TargetHealth[humanoid]
        C.TargetHealth[humanoid] = newHealth

        if oldHealth == nil or oldHealth == newHealth then
            return
        end

        C.NextHealthId = C.NextHealthId + 1
        local target = targetSnapshot(humanoid)
        local rec = {
            id = C.NextHealthId,
            t = now(),
            target = target.target,
            targetName = target.targetName,
            humanoidPath = target.humanoidPath,
            old = oldHealth,
            new = newHealth,
            delta = newHealth - oldHealth,
            maxHealth = target.maxHealth,
            pos = target.pos,
            humanoidAttrs = target.humanoidAttrs,
            modelAttrs = target.modelAttrs,
        }

        C.HealthChanges[#C.HealthChanges + 1] = rec
        C.Stats.HealthChanges = C.Stats.HealthChanges + 1
        if rec.delta < 0 then
            C.Stats.DamageChanges = C.Stats.DamageChanges + 1
        else
            C.Stats.HealingChanges = C.Stats.HealingChanges + 1
        end
        trimArray(C.HealthChanges, C.Limits.HealthChanges)

        if rec.delta < 0 then
            correlateHealth(rec)
        end
    end))

    track(humanoid.AncestryChanged:Connect(function(_, parent)
        if parent == nil then
            C.TargetHealth[humanoid] = nil
            C.WatchedHumanoids[humanoid] = nil
        end
    end))
end

local function initialHumanoidScan()
    local descendants = Workspace:GetDescendants()
    local processed = 0
    for _, item in ipairs(descendants) do
        if item:IsA("Humanoid") then
            watchHumanoid(item)
        end
        processed = processed + 1
        if processed % 500 == 0 then
            safeWait()
        end
    end
end

local function processNaturalCall(remote, method, args, results, startedClock, finishedClock)
    if not C.Running or not C.TraceEnabled then
        return
    end
    if typeof(remote) ~= "Instance" then
        return
    end

    local remotePath = pathOf(remote)
    local kind, damageCandidate, priority = classifyCall(remotePath)
    if not kind then
        return
    end

    C.NextCallId = C.NextCallId + 1
    local weaponKey, toolPath = remoteWeaponKey(remote, kind)
    local rec = {
        id = C.NextCallId,
        tStart = relTime(startedClock),
        tEnd = relTime(finishedClock),
        duration = math.max(0, finishedClock - startedClock),
        path = remotePath,
        class = remote.ClassName,
        method = method,
        kind = kind,
        damageCandidate = damageCandidate,
        priority = priority,
        weaponKey = weaponKey,
        toolPath = toolPath,
        targetHints = targetHintsFromPack(args),
        args = packSnap(args),
        results = packSnap(results),
        player = playerState(),
        correlatedHealthIds = {},
    }

    C.Calls[#C.Calls + 1] = rec
    C.Stats.Calls = C.Stats.Calls + 1
    if damageCandidate then
        C.Stats.DamageCandidateCalls = C.Stats.DamageCandidateCalls + 1
    end
    if kind == "PROJECTILE_HIT" then
        C.Stats.ProjectileHits = C.Stats.ProjectileHits + 1
    elseif kind == "HIT_TARGETS" then
        C.Stats.HitTargets = C.Stats.HitTargets + 1
    elseif kind == "SHOOT" then
        C.Stats.ShootCalls = C.Stats.ShootCalls + 1
    elseif kind == "SWING" then
        C.Stats.SwingCalls = C.Stats.SwingCalls + 1
    end

    addWeaponCall(rec)
    createOrExtendBurst(rec)
    trimArray(C.Calls, C.Limits.Calls)
    reconcileForCall(rec)
end

local function ensurePassiveBroker()
    local broker = ENV[BROKER_KEY]
    if type(broker) ~= "table" then
        broker = {
            Installed = false,
            Listeners = {},
            Old = nil,
        }
        ENV[BROKER_KEY] = broker
    end

    if broker.Installed then
        return broker, true, "existing broker"
    end

    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
        return broker, false, "hookmetamethod/getnamecallmethod unavailable"
    end

    local wrap = type(newcclosure) == "function" and newcclosure or function(fn)
        return fn
    end

    local old
    local ok, err = pcall(function()
        old = hookmetamethod(game, "__namecall", wrap(function(self, ...)
            local method = getnamecallmethod()
            local capture = method == "FireServer" or method == "InvokeServer"
            local startedClock = capture and os.clock() or nil
            local args = capture and table.pack(...) or nil

            -- Critical rule: forward the exact natural call unchanged first.
            local results = table.pack(old(self, ...))
            local finishedClock = capture and os.clock() or nil

            if capture then
                for listenerId, listener in pairs(broker.Listeners) do
                    if type(listener) == "function" then
                        safeSpawn(listener, self, method, args, results, startedClock, finishedClock)
                    else
                        broker.Listeners[listenerId] = nil
                    end
                end
            end

            return table.unpack(results, 1, results.n)
        end))
    end)

    if not ok or not old then
        return broker, false, tostring(err or "hook install failed")
    end

    broker.Old = old
    broker.Installed = true
    return broker, true, "installed"
end

local function serializableWeaponStats()
    local out = {}
    for key, stats in pairs(C.WeaponStats) do
        local targetCount = 0
        for _ in pairs(stats.targets or {}) do
            targetCount = targetCount + 1
        end

        local avgDamage = 0
        if (stats.correlatedHits or 0) > 0 then
            avgDamage = (stats.totalDamage or 0) / stats.correlatedHits
        end

        out[key] = {
            weapon = stats.weapon,
            protocolCalls = stats.protocolCalls,
            shootCalls = stats.shootCalls,
            projectileHitCalls = stats.projectileHitCalls,
            hitTargetsCalls = stats.hitTargetsCalls,
            correlatedHits = stats.correlatedHits,
            totalDamage = stats.totalDamage,
            averageDamage = avgDamage,
            minDamage = stats.minDamage,
            maxDamage = stats.maxDamage,
            kills = stats.kills,
            uniqueTargets = targetCount,
            samples = stats.samples,
        }
    end
    return out
end

local function burstSummary()
    local out = {}
    for _, burst in ipairs(C.Bursts) do
        local duration = math.max(0.001, (burst.endTime or burst.startTime) - burst.startTime)
        local targetCount = 0
        for _ in pairs(burst.targets or {}) do
            targetCount = targetCount + 1
        end
        out[#out + 1] = {
            id = burst.id,
            weapon = burst.weapon,
            startTime = burst.startTime,
            endTime = burst.endTime,
            duration = duration,
            damage = burst.damage,
            hits = burst.hits,
            kills = burst.kills,
            uniqueTargets = targetCount,
            observedDps = burst.damage / duration,
            callIds = burst.callIds,
        }
    end
    return out
end

local function unmatchedDamageCount()
    local count = 0
    for _, change in ipairs(C.HealthChanges) do
        if change.delta < 0 and not change.correlationId then
            count = count + 1
        end
    end
    return count
end

local function jsonWrite(path, value)
    local okEncode, encoded = pcall(function()
        return HttpService:JSONEncode(value)
    end)
    if not okEncode then
        return false, "JSONEncode failed: " .. tostring(encoded)
    end

    local okWrite, err = pcall(function()
        writefile(path, encoded)
    end)
    if not okWrite then
        return false, "writefile failed: " .. tostring(err)
    end
    return true
end

local function save(reason)
    if type(writefile) ~= "function" then
        return false, "writefile unavailable"
    end

    local stamp = os.date("%Y%m%d_%H%M%S")
    local suffix = reason == "AUTO" and "_AUTO" or "_MANUAL"
    local base = "ZHUB_COMBAT_OUTCOME_V21_"
        .. tostring(game.PlaceId)
        .. "_"
        .. stamp
        .. suffix

    local weaponStats = serializableWeaponStats()
    local bursts = burstSummary()
    local unmatched = unmatchedDamageCount()

    local statsSnapshot = {}
    for key, value in pairs(C.Stats) do
        statsSnapshot[key] = value
    end
    statsSnapshot.UnmatchedDamageChanges = unmatched

    local data = {
        schema = "ZHUB_COMBAT_OUTCOME_CORRELATOR_v2.1",
        placeId = game.PlaceId,
        jobId = game.JobId,
        player = LP.Name,
        seconds = now(),
        boundaries = {
            generatedServerCalls = 0,
            authBypass = 0,
            stateMutation = 0,
            movementModification = 0,
        },
        stats = statsSnapshot,
        calls = C.Calls,
        healthChanges = C.HealthChanges,
        correlations = C.Correlations,
        weaponStats = weaponStats,
        bursts = bursts,
    }

    local ok1, err1 = jsonWrite(base .. "_DATA.json", data)
    if not ok1 then
        return false, err1
    end
    local ok2, err2 = jsonWrite(base .. "_CORRELATIONS.json", C.Correlations)
    if not ok2 then
        return false, err2
    end
    local ok3, err3 = jsonWrite(base .. "_WEAPON_STATS.json", weaponStats)
    if not ok3 then
        return false, err3
    end
    local ok4, err4 = jsonWrite(base .. "_BURSTS.json", bursts)
    if not ok4 then
        return false, err4
    end

    local reportLines = {
        "ZHUB COMBAT OUTCOME CORRELATOR v2.1",
        "====================================",
        "Seconds: " .. string.format("%.2f", now()),
        "Relevant natural calls: " .. tostring(C.Stats.Calls),
        "Damage-candidate calls: " .. tostring(C.Stats.DamageCandidateCalls),
        "NPC health changes: " .. tostring(C.Stats.HealthChanges),
        "Damage changes: " .. tostring(C.Stats.DamageChanges),
        "Healing/regen changes: " .. tostring(C.Stats.HealingChanges),
        "Correlations: " .. tostring(C.Stats.Correlations),
        "Unmatched damage changes: " .. tostring(unmatched),
        "ProjectileHit calls: " .. tostring(C.Stats.ProjectileHits),
        "HitTargets calls: " .. tostring(C.Stats.HitTargets),
        "Shoot calls: " .. tostring(C.Stats.ShootCalls),
        "Swing calls: " .. tostring(C.Stats.SwingCalls),
        "Kills attributed: " .. tostring(C.Stats.Kills),
        "Autosaves completed before this save: " .. tostring(C.Stats.Autosaves),
        "Generated server calls: 0",
        "",
        "WEAPON SUMMARY",
        "--------------",
    }

    local names = {}
    for name in pairs(weaponStats) do
        names[#names + 1] = name
    end
    table.sort(names)

    for _, name in ipairs(names) do
        local s = weaponStats[name]
        reportLines[#reportLines + 1] = string.format(
            "%s | calls=%d shoots=%d projectileHit=%d hitTargets=%d correlatedHits=%d totalDamage=%.2f avgDamage=%.2f min=%s max=%s kills=%d targets=%d",
            tostring(name),
            s.protocolCalls or 0,
            s.shootCalls or 0,
            s.projectileHitCalls or 0,
            s.hitTargetsCalls or 0,
            s.correlatedHits or 0,
            s.totalDamage or 0,
            s.averageDamage or 0,
            tostring(s.minDamage),
            tostring(s.maxDamage),
            s.kills or 0,
            s.uniqueTargets or 0
        )
    end

    local okReport, reportErr = pcall(function()
        writefile(base .. "_REPORT.txt", table.concat(reportLines, "\n"))
    end)
    if not okReport then
        return false, "report write failed: " .. tostring(reportErr)
    end

    if reason == "AUTO" then
        C.Stats.Autosaves = C.Stats.Autosaves + 1
    else
        C.Stats.ManualSaves = C.Stats.ManualSaves + 1
    end

    C.LastSaveStatus = tostring(reason) .. " SAVE OK @ " .. string.format("%.1fs", now())
    return true, base
end

local function makeGui()
    local existing = PG:FindFirstChild(KEY)
    if existing then
        existing:Destroy()
    end

    local gui = Instance.new("ScreenGui")
    gui.Name = KEY
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = false
    gui.DisplayOrder = 999999
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = PG
    C.Gui = gui

    local frame = Instance.new("Frame")
    frame.Name = "Panel"
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.BackgroundColor3 = Color3.fromRGB(13, 17, 23)

    if DEVICE.TouchEnabled then
        frame.AnchorPoint = Vector2.new(1, 0)
        frame.Position = UDim2.new(1, -12, 0, 86)
        frame.Size = UDim2.fromOffset(330, 214)
    else
        frame.Position = UDim2.new(0, 20, 0, 100)
        frame.Size = UDim2.fromOffset(500, 155)
    end
    frame.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = frame

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Position = UDim2.fromOffset(10, 7)
    title.Size = UDim2.new(1, DEVICE.TouchEnabled and -52 or -20, 0, 22)
    title.TextColor3 = Color3.new(1, 1, 1)
    title.Font = Enum.Font.GothamBold
    title.TextSize = DEVICE.TouchEnabled and 12 or 13
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "ZHUB COMBAT OUTCOME v2.2"
    title.Parent = frame

    local collapse = nil
    if DEVICE.TouchEnabled then
        collapse = Instance.new("TextButton")
        collapse.Name = "Collapse"
        collapse.AnchorPoint = Vector2.new(1, 0)
        collapse.Position = UDim2.new(1, -6, 0, 5)
        collapse.Size = UDim2.fromOffset(34, 28)
        collapse.Font = Enum.Font.GothamBold
        collapse.TextSize = 18
        collapse.Text = "-"
        collapse.Parent = frame
        local collapseCorner = Instance.new("UICorner")
        collapseCorner.CornerRadius = UDim.new(0, 8)
        collapseCorner.Parent = collapse
    end

    local label = Instance.new("TextLabel")
    label.Name = "Status"
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(10, 33)
    label.Size = UDim2.new(1, -20, 0, DEVICE.TouchEnabled and 112 or 112)
    label.TextColor3 = Color3.new(1, 1, 1)
    label.Font = Enum.Font.Code
    label.TextSize = DEVICE.TouchEnabled and 10 or 11
    label.TextWrapped = false
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Top
    label.Parent = frame

    local buttonRow = nil
    local saveButton = nil
    local stopButton = nil

    if DEVICE.TouchEnabled then
        buttonRow = Instance.new("Frame")
        buttonRow.Name = "TouchControls"
        buttonRow.BackgroundTransparency = 1
        buttonRow.Position = UDim2.new(0, 8, 1, -55)
        buttonRow.Size = UDim2.new(1, -16, 0, 45)
        buttonRow.Parent = frame

        local layout = Instance.new("UIListLayout")
        layout.FillDirection = Enum.FillDirection.Horizontal
        layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        layout.VerticalAlignment = Enum.VerticalAlignment.Center
        layout.Padding = UDim.new(0, 8)
        layout.Parent = buttonRow

        local function makeTouchButton(name, text)
            local b = Instance.new("TextButton")
            b.Name = name
            b.Size = UDim2.new(0.5, -4, 1, 0)
            b.Font = Enum.Font.GothamBold
            b.TextSize = 12
            b.TextWrapped = true
            b.Text = text
            b.Parent = buttonRow
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 9)
            c.Parent = b
            return b
        end

        saveButton = makeTouchButton("SaveNow", "SAVE NOW")
        stopButton = makeTouchButton("StopSave", "STOP + SAVE")

        saveButton.Activated:Connect(function()
            if not C.Running then return end
            saveButton.Text = "SAVING..."
            local ok, result = save("MANUAL")
            if ok then
                print("[ZHUB COMBAT v2.2] MOBILE SAVE OK:", result)
                saveButton.Text = "SAVED"
            else
                C.LastSaveStatus = "MANUAL SAVE FAILED"
                warn("[ZHUB COMBAT v2.2] MOBILE SAVE FAILED:", tostring(result))
                saveButton.Text = "SAVE FAILED"
            end
            safeSpawn(function()
                safeWait(1.0)
                if saveButton and saveButton.Parent and C.Running then
                    saveButton.Text = "SAVE NOW"
                end
            end)
        end)

        stopButton.Activated:Connect(function()
            if not C.Running then return end
            stopButton.Text = "SAVING..."
            local ok, result = save("MANUAL")
            if ok then
                print("[ZHUB COMBAT v2.2] MOBILE STOP SAVE OK:", result)
            else
                C.LastSaveStatus = "STOP SAVE FAILED"
                warn("[ZHUB COMBAT v2.2] MOBILE STOP SAVE FAILED:", tostring(result))
            end
            if type(C.Cleanup) == "function" then
                C.Cleanup()
            end
        end)

        local expanded = true
        collapse.Activated:Connect(function()
            expanded = not expanded
            label.Visible = expanded
            buttonRow.Visible = expanded
            collapse.Text = expanded and "-" or "+"
            frame.Size = expanded and UDim2.fromOffset(330, 214) or UDim2.fromOffset(184, 38)
            title.Size = UDim2.new(1, -52, 0, 22)
        end)

        -- Same touch-drag behavior used by the established Stage-1 mobile UI.
        local dragging = false
        local dragStart = nil
        local startPos = nil
        local dragInput = nil

        frame.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Touch
                or input.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = true
                dragStart = input.Position
                startPos = frame.Position
            end
        end)

        frame.InputChanged:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Touch
                or input.UserInputType == Enum.UserInputType.MouseMovement then
                dragInput = input
            end
        end)

        track(UserInputService.InputChanged:Connect(function(input)
            if dragging and input == dragInput and dragStart and startPos then
                local delta = input.Position - dragStart
                frame.Position = UDim2.new(
                    startPos.X.Scale,
                    startPos.X.Offset + delta.X,
                    startPos.Y.Scale,
                    startPos.Y.Offset + delta.Y
                )
            end
        end))

        track(UserInputService.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Touch
                or input.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = false
                dragInput = nil
            end
        end))
    end

    safeSpawn(function()
        local refresh = DEVICE.Mobile and 0.75 or 0.5
        while C.Running do
            safeWait(refresh)
            if label.Parent then
                local controlLine
                if DEVICE.TouchEnabled then
                    controlLine = "AUTO 150s | TOUCH: SAVE NOW / STOP+SAVE"
                else
                    controlLine = "AUTO 150s | F7 MANUAL | RightShift HUD"
                end

                label.Text = string.format(
                    "TARGET-AWARE / PASSIVE\nCALLS %d | DAMAGE CALLS %d | HP DAMAGE %d\nCORRELATED %d | UNMATCHED %d | KILLS %d\nPROJECTILEHIT %d | HITTARGETS %d | SHOOT %d | SWING %d\n%s\n%s",
                    C.Stats.Calls,
                    C.Stats.DamageCandidateCalls,
                    C.Stats.DamageChanges,
                    C.Stats.Correlations,
                    unmatchedDamageCount(),
                    C.Stats.Kills,
                    C.Stats.ProjectileHits,
                    C.Stats.HitTargets,
                    C.Stats.ShootCalls,
                    C.Stats.SwingCalls,
                    controlLine,
                    tostring(C.LastSaveStatus)
                )
            end
        end
    end)
end

local broker, brokerOk, brokerWhy = ensurePassiveBroker()
if not brokerOk then
    warn("[ZHUB COMBAT v2.2] Passive hook unavailable:", tostring(brokerWhy))
else
    broker.Listeners[KEY] = processNaturalCall
end

C.Cleanup = function()
    if not C.Running then
        return
    end
    C.Running = false
    C.TraceEnabled = false

    local activeBroker = ENV[BROKER_KEY]
    if type(activeBroker) == "table" and type(activeBroker.Listeners) == "table" then
        activeBroker.Listeners[KEY] = nil
    end

    for _, connection in ipairs(C.Connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    C.Connections = {}

    if C.Gui and C.Gui.Parent then
        C.Gui:Destroy()
    end
end

makeGui()

safeSpawn(initialHumanoidScan)
track(Workspace.DescendantAdded:Connect(function(item)
    if C.Running and item:IsA("Humanoid") then
        safeSpawn(watchHumanoid, item)
    end
end))

safeSpawn(function()
    while C.Running do
        safeWait(C.AutoSaveSeconds)
        if C.Running then
            local ok, result = save("AUTO")
            if ok then
                print("[ZHUB COMBAT v2.2] AUTOSAVE OK:", result)
            else
                warn("[ZHUB COMBAT v2.2] AUTOSAVE FAILED:", tostring(result))
            end
        end
    end
end)

C.SaveNow = function()
    return save("MANUAL")
end
C.StopAndSave = function()
    local ok, result = save("MANUAL")
    if type(C.Cleanup) == "function" then C.Cleanup() end
    return ok, result
end
ENV.ZHUB_COMBAT_OUTCOME_SAVE = C.SaveNow
ENV.ZHUB_COMBAT_OUTCOME_STOP_SAVE = C.StopAndSave
ENV.ZHUB_COMBAT_OUTCOME_DEVICE = DEVICE

track(UserInputService.InputBegan:Connect(function(input, processed)
    if processed then
        return
    end

    if input.KeyCode == Enum.KeyCode.F7 then
        local ok, result = save("MANUAL")
        if ok then
            print("[ZHUB COMBAT v2.2] MANUAL SAVE OK:", result)
        else
            warn("[ZHUB COMBAT v2.2] MANUAL SAVE FAILED:", tostring(result))
        end
    elseif input.KeyCode == Enum.KeyCode.RightShift and C.Gui then
        C.Gui.Enabled = not C.Gui.Enabled
    end
end))

print("============================================================")
print("ZHUB COMBAT OUTCOME CORRELATOR v2.2 UNIVERSAL READY")
print("Passive broker:", brokerOk, brokerWhy)
print("Autosave: 150 seconds")
print("DESKTOP: F7 = manual checkpoint | RightShift = HUD toggle")
print("TOUCH/MOBILE: on-screen SAVE NOW / STOP + SAVE")
print("DEVICE: Platform=" .. tostring(DEVICE.Platform) .. " | Touch=" .. tostring(DEVICE.TouchEnabled) .. " | Keyboard=" .. tostring(DEVICE.KeyboardEnabled) .. " | MobileProfile=" .. tostring(DEVICE.Mobile))
print("Generated server calls: 0")
print("IMPORTANT: do NOT run the broad Deep Scanner simultaneously.")
print("Test naturally with: normal gun, projectile weapon, melee, Quickdraw.")
print("============================================================")
