--[[
VD AUTO MANS V6.1 — ADAPTIVE ORBIT
PlaceId: 93978595733734

Core movement features inherited from V5:
  * Any killer animation is observed, but motion is only triggered when close,
    approaching, facing the survivor, or clearly attack-like (reduces idle spam).
  * Predicts relative motion and closest approach, not only current distance.
  * Scores many dodge headings by projected spacing from nearby killers/projectiles,
    wall clearance, and floor availability.
  * Adds proactive pressure kiting: keeps a buffer from an approaching killer,
    then disengages after restoring separation.
  * Re-plans kite direction frequently and reuses raycast filters per pass.
  * Mobile toggle/status panel, duplicate-run cleanup, respawn/team tracking.

Optional timed footwork patterns are disabled to keep regular dodges brief; the critical
close-range orbit has its own obstacle-aware planner. This remains a client-side prototype
and has not been tested in a live match;
server-side hitboxes, attack-specific mechanics, latency, and executor differences
can prevent it from dodging reliably. It does not trigger game remotes.
]]

-- Stop an older copy first, even when a place transition means this script must exit.
local env = (getgenv and getgenv()) or _G
local previousStop = env.VD_AUTO_MANS_STOP or _G.VD_AUTO_MANS_STOP
if type(previousStop) == "function" then
    pcall(previousStop)
end

local EXPECTED_PLACE_ID = 93978595733734
if game.PlaceId ~= EXPECTED_PLACE_ID then
    warn("[VD Auto Mans V6] Wrong place; stopped.")
    return
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local CFG = {
    -- Start safely paused. Tap the pill to enable Auto Mans.
    Enabled = false,

    -- Animation listener watches every animation, then scores whether the
    -- situation is dangerous rather than blindly dodging every idle animation.
    AnimationTrigger = true,
    AnimationRange = 21,
    CriticalAnimationRange = 4.5,
    EmergencyTakeoverRange = 4.6, -- full movement takeover only at point-blank range
    EmergencyTakeoverReleaseRange = 6.2, -- release with a small hysteresis margin
    MaxThreatVerticalSeparation = 5.5, -- avoid reacting to players on another floor
    CriticalVerticalSeparation = 3.5, -- close orbit is allowed only on the same level
    CloseOrbitTimeout = 3.0, -- failsafe cap; normally ends after an actual full revolution
    CloseOrbitTargetRadius = 3.8,
    OrbitReplanInterval = 0.085,
    OrbitTangentWeight = 1.0,
    StuckCheckInterval = 0.22,
    StuckMinProgress = 0.32,
    CloseFacingRange = 8,
    MinimumClosingSpeed = 1.0,
    FacingDotThreshold = 0.12,
    AttackNameHints = true,

    -- Prediction of the killer's future position.
    PlayerPrediction = true,
    PlayerScanRange = 32,
    PlayerHorizon = 0.95,
    PlayerThreatRadius = 4.6,
    MinimumApproachSpeed = 1.8,
    MinimumClosingSpeedForPrediction = 0.55,
    RequireLineOfSight = true,

    -- Best-effort detection of fast, unanchored moving objects.
    ProjectilePrediction = true,
    ProjectileHorizon = 0.85,
    ProjectileThreatRadius = 3.4,
    ProjectileMinSpeed = 17,
    ProjectileMaxDistance = 95,
    ProjectileLifetime = 4.0,
    MaxTrackedParts = 240,
    InitialScanYieldEvery = 300,
    NewPartDelay = 0.04,

    -- Smart movement / steering.
    DodgeDuration = 0.28,
    KillerCooldown = 0.16,
    MinimumDodgeInterval = 0.18,
    -- Proactive kiting: start creating space before a hit is imminent.
    -- No continuous chase/spacing movement; only brief threat-response dodges.
    KiteEnabled = false,
    KiteStartRange = 25.0,
    KiteReleaseRange = 29.0,
    KiteHardRange = 12.0,
    KiteClosingThreshold = 0.25,
    KitePulseDuration = 0.42,
    KiteReplanInterval = 0.075,
    KiteAwayWeight = 5.0,
    KiteSideWeight = 0.65,
    ProbeDistance = 5.4,
    MinimumWallClearance = 0.85,
    GroundProbeAhead = 2.7,
    GroundProbeDepth = 8.5,
    CandidateCount = 12,
    RetargetFraction = 0.44,
    CandidateThreatCount = 6,
    PlayerMotionFactor = 0.83,
    NearThreatExtraAway = 0.7,
    SideBias = 0.28,
    PredictionInterval = 0.035,

    -- Short dodges get light style variation; close-range orbit has its own steering.
    MovementStylesEnabled = true,
    StyleCycleDuration = 0.46,
    StyleBlendDuration = 0.10,
    StyleSafetyInterval = 0.06,
    SteeringSmoothingSeconds = 0.075,
    StyleRadialKeepout = 0.55,
}

local shuttingDown = false
local connections = {}
local uiConnections = {}
local playerConnections = {}
local characterConnections = {}
local watchedCharacters = setmetatable({}, { __mode = "k" })
local characterTokens = setmetatable({}, { __mode = "k" })
local lastByKiller = setmetatable({}, { __mode = "k" })
local trackedParts = setmetatable({}, { __mode = "k" })

local activeDodge = nil
local lastDodge = -math.huge
local lastPrediction = 0
local preferredSide = 1
local kiteFocusCharacter = nil
local gui = nil
local statusLabel = nil
local detailLabel = nil
local toggleButton = nil

local function connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(connections, connection)
    return connection
end

local function disconnect(connection)
    if connection then
        pcall(function() connection:Disconnect() end)
    end
end

local function connectUI(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(uiConnections, connection)
    return connection
end

local function flat(v)
    return Vector3.new(v.X, 0, v.Z)
end

local function unitOrZero(v)
    if v.Magnitude < 0.001 then return Vector3.zero end
    return v.Unit
end

local function setStatus(message, detail)
    if statusLabel and statusLabel.Parent then
        statusLabel.Text = message
    end
    if detailLabel and detailLabel.Parent and detail then
        detailLabel.Text = detail
    end
end

local function isKiller(player)
    if not player then return false end

    local teamName = player.Team and string.lower(player.Team.Name) or ""
    if string.find(teamName, "killer", 1, true)
        or string.find(teamName, "hunter", 1, true) then
        return true
    end

    local role = player:GetAttribute("Role")
    if typeof(role) == "string" and string.lower(role) == "killer" then
        return true
    end
    return player:GetAttribute("Killer") == true
end

local function getCharacterParts(character)
    if not character then return nil, nil end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")
        or character:FindFirstChild("RootPart")

    if not humanoid or not root or humanoid.Health <= 0 then
        return nil, nil
    end
    return humanoid, root
end

local function localCharacterBlocked(character, humanoid)
    if not character or not character.Parent or not humanoid then return true end
    if humanoid.Health <= 0 or humanoid.Sit or humanoid.PlatformStand then return true end
    if LocalPlayer:GetAttribute("IsDead") == true then return true end

    if character:GetAttribute("IsHooked") == true
        or character:GetAttribute("IsCarried") == true
        or character:GetAttribute("Knocked") == true then
        return true
    end
    return false
end

local function isCharacterPart(instance)
    local parent = instance
    while parent and parent ~= Workspace do
        if parent:IsA("Model") and parent:FindFirstChildOfClass("Humanoid") then
            return true
        end
        parent = parent.Parent
    end
    return false
end

local moveRayParams = RaycastParams.new()
moveRayParams.FilterType = Enum.RaycastFilterType.Exclude
moveRayParams.IgnoreWater = true
pcall(function() moveRayParams.RespectCanCollide = true end)

local groundRayParams = RaycastParams.new()
groundRayParams.FilterType = Enum.RaycastFilterType.Exclude
groundRayParams.IgnoreWater = true
pcall(function() groundRayParams.RespectCanCollide = true end)

local function buildCharacterExclusions(includeAllPlayers)
    local excluded = {}
    if LocalPlayer.Character then table.insert(excluded, LocalPlayer.Character) end
    if includeAllPlayers then
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer and player.Character then
                table.insert(excluded, player.Character)
            end
        end
    end
    return excluded
end

local function directionClearance(root, direction)
    direction = unitOrZero(flat(direction))
    if direction.Magnitude < 0.01 then return nil, 0 end

    local clearance = CFG.ProbeDistance
    -- Lower and lengthen the sweep: the old cast started too high and could miss low walls.
    local bodyOrigin = root.Position + Vector3.new(0, -0.15, 0)

    -- Sweep a box approximating the avatar's body so shoulder/hip corners are checked too.
    -- Roblox Blockcast does not report parts already intersecting the start shape, so the
    -- offset rays are also run on every pass to catch corners/partial overlap.
    local ok, bodyHit = pcall(function()
        return Workspace:Blockcast(
            CFrame.new(bodyOrigin),
            Vector3.new(1.8, 3.0, 1.8),
            direction * CFG.ProbeDistance,
            moveRayParams
        )
    end)
    if ok and bodyHit then
        clearance = math.min(clearance, math.max(0, bodyHit.Distance - 0.25))
    end

    local right = Vector3.new(-direction.Z, 0, direction.X)
    for _, lateralOffset in ipairs({ 0, -0.58, 0.58 }) do
        local origin = root.Position + Vector3.new(0, -0.80, 0) + right * lateralOffset
        local wall = Workspace:Raycast(origin, direction * CFG.ProbeDistance, moveRayParams)
        if wall then
            clearance = math.min(clearance, math.max(0, wall.Distance - 0.25))
        end
    end

    if clearance < CFG.MinimumWallClearance then return nil, clearance end

    -- Reject edges and near-vertical surfaces masquerading as ground.
    local groundOrigin = root.Position
        + direction * CFG.GroundProbeAhead
        + Vector3.new(0, 2.8, 0)
    local ground = Workspace:Raycast(
        groundOrigin,
        Vector3.new(0, -CFG.GroundProbeDepth, 0),
        groundRayParams
    )
    if not ground or ground.Normal.Y < 0.45 then return nil, clearance end

    return direction, clearance
end

local function hasLineOfSight(myRoot, targetRoot, targetCharacter)
    if not myRoot or not targetRoot or not myRoot.Parent or not targetRoot.Parent then
        return false
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.IgnoreWater = true
    params.FilterDescendantsInstances = { LocalPlayer.Character, targetCharacter }

    local origin = myRoot.Position + Vector3.new(0, 1.2, 0)
    return Workspace:Raycast(origin, targetRoot.Position - origin, params) == nil
end

local function attackLike(track)
    if not CFG.AttackNameHints or not track then return false end

    local names = {}
    pcall(function() table.insert(names, string.lower(track.Name or "")) end)
    pcall(function()
        if track.Animation then
            table.insert(names, string.lower(track.Animation.Name or ""))
        end
    end)

    local hints = { "attack", "lunge", "slash", "swing", "stab", "hit", "throw", "charge", "skill", "dash", "strike" }
    for _, name in ipairs(names) do
        for _, hint in ipairs(hints) do
            if string.find(name, hint, 1, true) then return true end
        end
    end
    return false
end

local function closingSpeed(myRoot, enemyRoot)
    local offset = flat(myRoot.Position - enemyRoot.Position)
    if offset.Magnitude < 0.05 then return 999 end
    local relativeVelocity = flat(myRoot.AssemblyLinearVelocity - enemyRoot.AssemblyLinearVelocity)
    return -relativeVelocity:Dot(offset.Unit)
end

local function facingUs(myRoot, enemyRoot)
    local toSurvivor = unitOrZero(flat(myRoot.Position - enemyRoot.Position))
    if toSurvivor.Magnitude < 0.05 then return true end
    local look = unitOrZero(flat(enemyRoot.CFrame.LookVector))
    if look.Magnitude < 0.05 then return false end
    return look:Dot(toSurvivor) >= CFG.FacingDotThreshold
end

-- Predict the closest approach between player and killer within a short horizon.
local function predictKillerThreat(myRoot, killerCharacter)
    local _, killerRoot = getCharacterParts(killerCharacter)
    if not killerRoot then return nil end

    local offset = flat(killerRoot.Position - myRoot.Position)
    local distance = offset.Magnitude
    if math.abs(killerRoot.Position.Y - myRoot.Position.Y) > CFG.MaxThreatVerticalSeparation then
        return nil
    end
    if distance < 0.1 or distance > CFG.PlayerScanRange then return nil end

    local relativeVelocity = flat(killerRoot.AssemblyLinearVelocity - myRoot.AssemblyLinearVelocity)
    local speedSquared = relativeVelocity:Dot(relativeVelocity)
    if speedSquared < CFG.MinimumApproachSpeed ^ 2 then return nil end

    local t = math.clamp(-offset:Dot(relativeVelocity) / speedSquared, 0, CFG.PlayerHorizon)
    local closest = offset + relativeVelocity * t
    local missDistance = closest.Magnitude
    local closing = -offset:Dot(relativeVelocity) / math.max(distance, 0.1)

    if closing <= CFG.MinimumClosingSpeedForPrediction or missDistance > CFG.PlayerThreatRadius then
        return nil
    end
    if t <= 0.035 and distance > CFG.PlayerThreatRadius then return nil end
    if CFG.RequireLineOfSight and not hasLineOfSight(myRoot, killerRoot, killerCharacter) then
        return nil
    end

    return {
        score = t + missDistance * 0.06,
        time = t,
        position = killerRoot.Position,
        velocity = killerRoot.AssemblyLinearVelocity,
        kind = "approach prediction",
        killerCharacter = killerCharacter,
        sourceRoot = killerRoot,
    }
end

local function trackPart(part)
    if shuttingDown or not part or not part:IsA("BasePart") then return end
    if not part.Parent or part.Anchored or not part:IsDescendantOf(Workspace) then return end
    if part.Size.Magnitude > 42 then return end
    if LocalPlayer.Character and part:IsDescendantOf(LocalPlayer.Character) then return end
    if isCharacterPart(part) then return end

    trackedParts[part] = trackedParts[part] or os.clock()

    local count, oldest, oldestTime = 0, nil, math.huge
    for tracked, born in pairs(trackedParts) do
        if not tracked.Parent or tracked.Anchored then
            trackedParts[tracked] = nil
        else
            count += 1
            if born < oldestTime then
                oldestTime = born
                oldest = tracked
            end
        end
    end
    if count > CFG.MaxTrackedParts and oldest then trackedParts[oldest] = nil end
end

local function predictProjectileThreat(myRoot)
    local now = os.clock()
    local best = nil

    for part, born in pairs(trackedParts) do
        if not part.Parent or part.Anchored or now - born > CFG.ProjectileLifetime then
            trackedParts[part] = nil
        else
            local velocity = part.AssemblyLinearVelocity
            local relative = part.Position - myRoot.Position
            local distance = relative.Magnitude

            if velocity.Magnitude >= CFG.ProjectileMinSpeed
                and distance <= CFG.ProjectileMaxDistance then
                local relativeVelocity = velocity - myRoot.AssemblyLinearVelocity
                local speedSquared = relativeVelocity:Dot(relativeVelocity)

                -- Skip parts that are not moving toward the player.
                if speedSquared > 1 and relative:Dot(relativeVelocity) < 0 then
                    local t = math.clamp(-relative:Dot(relativeVelocity) / speedSquared, 0, CFG.ProjectileHorizon)
                    local miss = (relative + relativeVelocity * t).Magnitude
                    if miss <= CFG.ProjectileThreatRadius then
                        local threat = {
                            score = t + miss * 0.07,
                            time = t,
                            position = part.Position,
                            velocity = velocity,
                            kind = "projectile prediction",
                            projectile = part,
                        }
                        if not best or threat.score < best.score then best = threat end
                    end
                end
            end
        end
    end
    return best
end

local function collectNearbyThreats(primary, myRoot)
    local threats = {}
    local seen = {}

    local function add(threat)
        if not threat then return end
        local key = threat.killerCharacter or threat.projectile or threat
        if seen[key] then return end
        seen[key] = true
        table.insert(threats, threat)
    end

    add(primary)

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and isKiller(player) then
            local _, root = getCharacterParts(player.Character)
            if root
                and math.abs(root.Position.Y - myRoot.Position.Y) <= CFG.MaxThreatVerticalSeparation
                and (root.Position - myRoot.Position).Magnitude <= CFG.PlayerScanRange then
                add({
                    position = root.Position,
                    velocity = root.AssemblyLinearVelocity,
                    kind = "nearby killer",
                    killerCharacter = player.Character,
                    sourceRoot = root,
                    time = 0.25,
                })
            end
        end
    end

    -- Add only a handful of nearby moving objects to keep scoring lightweight.
    local projectileThreats = {}
    if CFG.ProjectilePrediction then
        for part in pairs(trackedParts) do
            if part.Parent and not part.Anchored then
                local velocity = part.AssemblyLinearVelocity
                local distance = (part.Position - myRoot.Position).Magnitude
                if velocity.Magnitude >= CFG.ProjectileMinSpeed and distance <= 30 then
                    local rel = part.Position - myRoot.Position
                    local relVel = velocity - myRoot.AssemblyLinearVelocity
                    local denom = relVel:Dot(relVel)
                    if denom > 1 and rel:Dot(relVel) < 0 then
                        local t = math.clamp(-rel:Dot(relVel) / denom, 0, CFG.ProjectileHorizon)
                        local miss = (rel + relVel * t).Magnitude
                        if miss < 10 then
                            table.insert(projectileThreats, {
                                score = t + miss * 0.08,
                                time = t,
                                position = part.Position,
                                velocity = velocity,
                                kind = "moving object",
                                projectile = part,
                            })
                        end
                    end
                end
            end
        end
    end
    table.sort(projectileThreats, function(a, b) return a.score < b.score end)
    for i = 1, math.min(CFG.CandidateThreatCount, #projectileThreats) do
        add(projectileThreats[i])
    end

    return threats
end

local function predictedThreatPosition(threat, t)
    if threat.projectile and threat.projectile.Parent then
        return threat.projectile.Position + threat.projectile.AssemblyLinearVelocity * t
    end
    if threat.killerCharacter then
        local _, root = getCharacterParts(threat.killerCharacter)
        if root then
            return root.Position + flat(root.AssemblyLinearVelocity) * t
        end
    end
    return (threat.position or Vector3.zero) + flat(threat.velocity or Vector3.zero) * t
end

local function scoreDirection(root, humanoid, direction, clearance, threats, primary)
    direction = unitOrZero(flat(direction))
    if direction.Magnitude < 0.01 then return -math.huge end

    local speed = math.max(humanoid.WalkSpeed, 9)
    local currentVelocity = flat(root.AssemblyLinearVelocity)
    local minSeparation = math.huge
    local endSeparation = math.huge
    local finalSampleTime = 0.56
    local sampleTimes = { 0.10, 0.19, 0.30, 0.43, finalSampleTime }

    for _, threat in ipairs(threats) do
        for _, t in ipairs(sampleTimes) do
            local myFuture = root.Position
                + currentVelocity * (t * 0.30)
                + direction * (speed * t * CFG.PlayerMotionFactor)
            local theirFuture = predictedThreatPosition(threat, t)
            local separation = flat(myFuture - theirFuture).Magnitude
            if separation < minSeparation then minSeparation = separation end
            if t == finalSampleTime then
                endSeparation = math.min(endSeparation, separation)
            end
        end
    end

    if minSeparation == math.huge then minSeparation = 0 end
    if endSeparation == math.huge then endSeparation = 0 end

    local awayScore = 0
    local sideScore = 0
    if primary and primary.position then
        local threatPosition = predictedThreatPosition(primary, math.clamp(primary.time or 0, 0, 0.25))
        local away = unitOrZero(flat(root.Position - threatPosition))
        local enemyVelocity = flat(primary.velocity or Vector3.zero)
        local lateral = unitOrZero(Vector3.new(-enemyVelocity.Z, 0, enemyVelocity.X))
        awayScore = direction:Dot(away)
        if lateral.Magnitude > 0.01 then
            sideScore = math.abs(direction:Dot(lateral))
        end
    end

    -- A larger projected clearance from the threats outweighs pure distance
    -- from walls; side/away preferences are tie-breakers.
    local awayWeight = (primary and primary.kiting) and CFG.KiteAwayWeight or 1.25
    local sideWeight = (primary and primary.kiting) and CFG.KiteSideWeight or CFG.SideBias

    return minSeparation * 1.7
        + endSeparation * 0.40
        + math.min(clearance, CFG.ProbeDistance) * 0.65
        + awayScore * awayWeight
        + sideScore * sideWeight
end

local function chooseDodgeDirection(root, humanoid, primary)
    -- Reuse one exclusion list for all candidate raycasts in this planning pass.
    local exclusions = buildCharacterExclusions(true)
    moveRayParams.FilterDescendantsInstances = exclusions
    groundRayParams.FilterDescendantsInstances = exclusions

    local threats = collectNearbyThreats(primary, root)
    local bestDirection, bestScore = nil, -math.huge

    local away = Vector3.zero
    if primary and primary.position then
        away = unitOrZero(flat(root.Position - predictedThreatPosition(primary, math.clamp(primary.time or 0, 0, 0.22))) )
    end
    if away.Magnitude < 0.01 then away = -unitOrZero(flat(root.CFrame.LookVector)) end

    local velocity = primary and flat(primary.velocity or Vector3.zero) or Vector3.zero
    local lateral = unitOrZero(Vector3.new(-velocity.Z, 0, velocity.X))
    if lateral.Magnitude < 0.05 then
        lateral = Vector3.new(-away.Z, 0, away.X)
    end

    local candidates = {}
    local primaryDistance = primary and primary.position
        and flat(root.Position - predictedThreatPosition(primary, 0)).Magnitude or math.huge
    local near = (primary and primary.kiting) or primaryDistance <= 6.5
    local retreat = (primary and primary.kiting)
        and CFG.KiteAwayWeight
        or (near and CFG.NearThreatExtraAway or 0.24)

    table.insert(candidates, unitOrZero(away + lateral * preferredSide * 0.72))
    table.insert(candidates, unitOrZero(away - lateral * preferredSide * 0.72))
    table.insert(candidates, unitOrZero(away + lateral * preferredSide * 0.35))
    table.insert(candidates, unitOrZero(away - lateral * preferredSide * 0.35))
    table.insert(candidates, unitOrZero(away + lateral * preferredSide * 0.95))
    table.insert(candidates, unitOrZero(away - lateral * preferredSide * 0.95))

    for i = 0, CFG.CandidateCount - 1 do
        local angle = (math.pi * 2 * i / CFG.CandidateCount)
        table.insert(candidates, Vector3.new(math.cos(angle), 0, math.sin(angle)))
    end

    local bestClearance = 0
    for _, candidate in ipairs(candidates) do
        local moveDirection, clearance = directionClearance(root, candidate)
        if moveDirection then
            local score = scoreDirection(root, humanoid, moveDirection, clearance, threats, primary)
            if near then
                score = score + moveDirection:Dot(away) * retreat
            end
            if moveDirection:Dot(lateral) * preferredSide > 0.2 then
                score = score + 0.06
            end
            if score > bestScore then
                bestScore = score
                bestDirection = moveDirection
                bestClearance = clearance
            end
        end
    end

    if bestDirection then
        preferredSide = -preferredSide
    end
    return bestDirection, bestScore, bestClearance
end

-- Diverse footwork patterns inspired by common game-steering methods:
-- circle strafing (https://en.wikipedia.org/wiki/Strafing_(video_games))
-- and evade/separation/orbit steering (https://github.com/cpowell/steering-behaviors).
-- The VD predictive-dodge reference also motivates predicted trajectories and ground checks:
-- https://github.com/gg8752383-cpu/AutoDodge1/blob/d53d95e15b2cf3e237775065aaf8d9b11c7e7b6b/Predictive_AutoDodge.lua
-- Each pattern retains an outward component so it does not intentionally run into the killer.
local STYLE_NAMES = {
    "ARC LEFT", "ARC RIGHT", "ZIGZAG", "S-WEAVE", "J-HOOK",
    "ORBIT", "REVERSE ORBIT", "SPIRAL", "FEINT STEP", "DIAGONAL BURST",
    "MICRO-SNAKE", "RETREAT ARC", "COUNTER-CUT", "WIDE ORBIT", "CROSS-STEP",
}

local function getStyleVector(styleIndex, elapsed, away, tangent, radial, side)
    local wave = math.sin(elapsed * 13.5)
    local vector

    if styleIndex == 1 then -- Arc to the left with outward drift
        vector = away * math.max(radial, 0.58) + tangent * side * 0.95
    elseif styleIndex == 2 then -- Reverse arc
        vector = away * math.max(radial, 0.58) - tangent * side * 0.95
    elseif styleIndex == 3 then -- Zig-zag: left/right cuts, never a straight approach
        vector = away * math.max(radial, 0.66) + tangent * (wave >= 0 and 0.88 or -0.88)
    elseif styleIndex == 4 then -- Smooth S-shaped weave
        vector = away * math.max(radial, 0.72) + tangent * math.sin(elapsed * 8.8) * 1.02
    elseif styleIndex == 5 then -- J-hook: short side-step, then hard outward cut
        local phase = elapsed % 0.62
        local flip = phase < 0.20 and side or -side
        local lateral = phase < 0.20 and 1.05 or 0.62
        vector = away * (phase < 0.20 and 0.70 or math.max(radial, 0.90)) + tangent * flip * lateral
    elseif styleIndex == 6 then -- Clockwise orbit with an outward bias
        vector = away * math.max(radial, 0.52) + tangent * side * 1.12
    elseif styleIndex == 7 then -- Counter-clockwise orbit
        vector = away * math.max(radial, 0.52) - tangent * side * 1.12
    elseif styleIndex == 8 then -- Spiral-like outward sweep
        local angle = elapsed * 6.4
        vector = away * math.max(radial, 0.72) + tangent * math.sin(angle) * 1.08
    elseif styleIndex == 9 then -- Feint-step: rapid side reversal while drifting out
        local phase = elapsed % 0.46
        local flip = phase < 0.13 and side or -side
        vector = away * math.max(radial, 0.62) + tangent * flip * (phase < 0.13 and 1.05 or 0.82)
    elseif styleIndex == 10 then -- Diagonal burst, then a controlled retreat
        local phase = elapsed % 0.68
        if phase < 0.19 then
            vector = away * 1.12 + tangent * side * 1.02
        else
            vector = away * math.max(radial, 0.72) + tangent * side * 0.42
        end
    elseif styleIndex == 11 then -- Small quick snake steps
        vector = away * math.max(radial, 0.72) + tangent * math.sin(elapsed * 21.0) * 0.72
    elseif styleIndex == 12 then -- Strong retreat arc when pressure is high
        vector = away * math.max(radial, 1.0) + tangent * side * 0.52
    elseif styleIndex == 13 then -- Counter-cut: swap the angle midway through the beat
        local phase = elapsed % 0.58
        local flip = phase < 0.29 and side or -side
        vector = away * math.max(radial, 0.80) + tangent * flip * 0.96
    elseif styleIndex == 14 then -- Wider orbit; only use when there is room
        vector = away * math.max(radial, 0.44) + tangent * side * 1.30
    else -- Cross-step: angled retreat with continuous side sway
        vector = away * math.max(radial, 0.78) + tangent * (side * 0.52 + math.sin(elapsed * 10.5) * 0.38)
    end

    return unitOrZero(flat(vector))
end

local function styledDirectionFor(dodge, now)
    if not CFG.MovementStylesEnabled or not dodge or not dodge.root then
        return dodge and dodge.direction or nil
    end

    local threat = dodge.threat
    if not threat then return dodge.direction end

    local root = dodge.root
    if not root.Parent then return dodge.direction end

    local targetPosition = predictedThreatPosition(threat, math.clamp(threat.time or 0.08, 0, 0.14))
    local targetVelocity = flat(threat.velocity or Vector3.zero)

    if threat.killerCharacter then
        local _, currentTargetRoot = getCharacterParts(threat.killerCharacter)
        if currentTargetRoot then
            targetPosition = currentTargetRoot.Position + flat(currentTargetRoot.AssemblyLinearVelocity) * 0.08
            targetVelocity = flat(currentTargetRoot.AssemblyLinearVelocity)
        end
    elseif threat.projectile and threat.projectile.Parent then
        targetPosition = threat.projectile.Position + threat.projectile.AssemblyLinearVelocity * 0.06
        targetVelocity = flat(threat.projectile.AssemblyLinearVelocity)
    end

    local offset = flat(root.Position - targetPosition)
    local distance = offset.Magnitude
    local away = unitOrZero(offset)
    if away.Magnitude < 0.01 then
        away = unitOrZero(flat(dodge.direction or root.CFrame.RightVector))
    end
    if away.Magnitude < 0.01 then away = Vector3.new(1, 0, 0) end

    local tangent = Vector3.new(-away.Z, 0, away.X)
    -- Prefer the side that crosses the killer's path rather than the side the killer is already moving into.
    local lateralVelocity = Vector3.new(-targetVelocity.Z, 0, targetVelocity.X)
    if lateralVelocity.Magnitude > 0.25 and lateralVelocity.Unit:Dot(tangent) < -0.1 then
        tangent = -tangent
    end

    -- Keep distance first; style supplies the lateral shape around that safety vector.
    local radial
    if distance <= 6 then
        radial = 1.18
    elseif distance <= 12 then
        radial = 0.95
    elseif distance <= 20 then
        radial = 0.74
    elseif distance <= CFG.KiteStartRange then
        radial = 0.55
    elseif distance <= CFG.KiteReleaseRange then
        radial = CFG.StyleRadialKeepout
    else
        radial = 0.22
    end

    local startedAt = dodge.patternStartAt or dodge.startedAt or now
    local elapsed = math.max(0, now - startedAt)
    local slot = math.floor(elapsed / CFG.StyleCycleDuration)
    local within = elapsed - slot * CFG.StyleCycleDuration
    local baseIndex = ((dodge.styleOffset or 1) + slot - 1) % #STYLE_NAMES + 1
    local nextIndex = baseIndex % #STYLE_NAMES + 1
    local side = (slot % 2 == 0) and (dodge.patternSide or 1) or -(dodge.patternSide or 1)

    local wanted = getStyleVector(baseIndex, elapsed, away, tangent, radial, side)
    local blendStart = CFG.StyleCycleDuration - CFG.StyleBlendDuration
    if within >= blendStart then
        local alpha = math.clamp((within - blendStart) / CFG.StyleBlendDuration, 0, 1)
        alpha = alpha * alpha * (3 - 2 * alpha) -- smoothstep to avoid harsh turns
        local nextWanted = getStyleVector(nextIndex, elapsed, away, tangent, radial, -side)
        local mixed = wanted:Lerp(nextWanted, alpha)
        if mixed.Magnitude > 0.02 then wanted = mixed.Unit end
    end

    -- Validate every selected move against walls and missing ground; if blocked,
    -- pick the safest nearby alternative rather than blindly following the pattern.
    if now - (dodge.lastStyleSafetyAt or 0) >= CFG.StyleSafetyInterval then
        dodge.lastStyleSafetyAt = now
        local exclusions = buildCharacterExclusions(true)
        moveRayParams.FilterDescendantsInstances = exclusions
        groundRayParams.FilterDescendantsInstances = exclusions

        local candidates = {
            wanted,
            away,
            unitOrZero(away + tangent * side * 0.8),
            unitOrZero(away - tangent * side * 0.8),
            tangent * side,
            -tangent * side,
            dodge.direction,
        }
        local best, bestScore = nil, -math.huge
        for _, candidate in ipairs(candidates) do
            local clearDirection, clearance = directionClearance(root, candidate)
            if clearDirection then
                local score = clearDirection:Dot(wanted) * 2.8
                    + clearDirection:Dot(away) * 0.35
                    + math.min(clearance or 0, CFG.ProbeDistance) * 0.035
                if score > bestScore then
                    bestScore, best = score, clearDirection
                end
            end
        end
        if best then
            local previous = dodge.smoothedStyleDirection or dodge.direction or best
            local dt = math.max(0.001, now - (dodge.lastStyleUpdateAt or now))
            local alpha = 1 - math.exp(-dt / CFG.SteeringSmoothingSeconds)
            local smooth = previous:Lerp(best, math.clamp(alpha, 0.12, 0.85))
            if smooth.Magnitude > 0.02 then
                dodge.smoothedStyleDirection = smooth.Unit
            else
                dodge.smoothedStyleDirection = best
            end
            dodge.lastStyleUpdateAt = now
        else
            -- If every tested direction is blocked or lacks ground, stop briefly
            -- instead of blindly continuing toward a ledge.
            dodge.smoothedStyleDirection = Vector3.zero
            dodge.lastStyleUpdateAt = now
            setStatus("NO SAFE STEP", "Blocked / edge detected")
        end
    end

    local styleName = STYLE_NAMES[baseIndex]
    if dodge.lastDisplayedStyle ~= styleName then
        dodge.lastDisplayedStyle = styleName
        if dodge.kiting then
            setStatus("KITE: " .. styleName, string.format("Pattern %d/%d • %.1f studs", baseIndex, #STYLE_NAMES, distance))
        end
    end

    return dodge.smoothedStyleDirection or wanted, styleName
end

local function orbitAngle(root, targetRoot)
    if not root or not targetRoot or not root.Parent or not targetRoot.Parent then return nil end
    local offset = flat(root.Position - targetRoot.Position)
    if offset.Magnitude < 0.05 then return nil end
    return math.atan2(offset.Z, offset.X)
end

local function signedAngleDelta(fromAngle, toAngle)
    return (toAngle - fromAngle + math.pi) % (math.pi * 2) - math.pi
end

local function requestDodge(threat, forceUrgent)
    if shuttingDown or not CFG.Enabled or isKiller(LocalPlayer) then return false end

    local now = os.clock()
    local urgent = forceUrgent or (threat and (threat.time or 1) < 0.16)

    if activeDodge and now < activeDodge.finishAt then
        -- If a normal short dodge is already underway when the killer gets
        -- critically close, promote it into the controlled orbit immediately.
        if threat and threat.killerCharacter and activeDodge.root and activeDodge.root.Parent then
            local _, closeRoot = getCharacterParts(threat.killerCharacter)
            if closeRoot then
                local closeOffset = activeDodge.root.Position - closeRoot.Position
                local closeDistance = closeOffset.Magnitude
                if closeDistance <= CFG.EmergencyTakeoverRange
                    and math.abs(closeOffset.Y) <= CFG.CriticalVerticalSeparation then
                    local targetChanged = activeDodge.threat
                        and activeDodge.threat.killerCharacter ~= threat.killerCharacter
                    if not activeDodge.orbiting or targetChanged then
                        activeDodge.orbiting = true
                        activeDodge.orbitSide = preferredSide
                        activeDodge.orbitStartedAt = now
                        activeDodge.orbitProgress = 0
                        activeDodge.lastOrbitAngle = orbitAngle(activeDodge.root, closeRoot)
                        activeDodge.finishAt = math.max(activeDodge.finishAt, now + CFG.CloseOrbitTimeout)
                        activeDodge.lastMotionPosition = activeDodge.root.Position
                        activeDodge.lastMotionCheckAt = now
                        activeDodge.nextOrbitPlanAt = 0
                        activeDodge.orbitDirection = nil
                    end
                    activeDodge.threat = threat
                    return true
                end
            end
        end

        -- A confirmed/imminent threat can override the continuous kite pulse.
        if activeDodge.kiting and threat and not threat.kiting and urgent then
            activeDodge.kiting = false
            activeDodge.threat = threat
            activeDodge.finishAt = math.max(activeDodge.finishAt, now + 0.24)
            activeDodge.retargeted = false
            activeDodge.retargetNow = true
            return true
        end
        -- Continuous kite pulses are refreshed while the killer remains nearby.
        if activeDodge.kiting and threat and threat.kiting then
            activeDodge.threat = threat
            activeDodge.finishAt = now + CFG.KitePulseDuration
            return true
        end
        -- If a more urgent second threat appears, retarget the existing motion.
        local activeEta = activeDodge.threat and activeDodge.threat.time or 1
        local newEta = threat and threat.time or 1
        if urgent and newEta + 0.04 < activeEta then
            activeDodge.threat = threat
            activeDodge.retargetNow = true
        end
        return false
    end

    local character = LocalPlayer.Character
    local humanoid, root = getCharacterParts(character)
    if not humanoid or not root or localCharacterBlocked(character, humanoid) then
        return false
    end

    local sourceCharacter = threat and threat.killerCharacter
    local veryClose = threat and threat.kind == "CRITICAL PROXIMITY" or false
    if sourceCharacter then
        local _, sourceRoot = getCharacterParts(sourceCharacter)
        if not sourceRoot then return false end

        local offset = root.Position - sourceRoot.Position
        local distance = offset.Magnitude
        local sameLevel = math.abs(offset.Y) <= CFG.CriticalVerticalSeparation
        veryClose = veryClose or (distance <= CFG.EmergencyTakeoverRange and sameLevel)
        if math.abs(offset.Y) > CFG.MaxThreatVerticalSeparation then return false end
        if CFG.RequireLineOfSight and not hasLineOfSight(root, sourceRoot, sourceCharacter) then
            return false
        end
        local maxThreatRange = (threat and threat.kiting)
            and (CFG.KiteReleaseRange + 1)
            or (CFG.AnimationRange + 3)
        if distance > maxThreatRange then return false end

        if not (threat and threat.kiting) then
            local previous = lastByKiller[sourceCharacter] or -math.huge
            if now - previous < CFG.KillerCooldown and not urgent then return false end
            lastByKiller[sourceCharacter] = now
        end
    end

    -- Point-blank takeovers bypass the regular cooldown; ordinary player and
    -- projectile dodges remain rate-limited to avoid repetitive movement bursts.
    if not veryClose and now - lastDodge < CFG.MinimumDodgeInterval then return false end

    local direction, score, clearance = chooseDodgeDirection(root, humanoid, threat)
    if not direction then
        setStatus("NO CLEAR PATH", "No safe route; normal control kept")
        return false
    end

    lastDodge = now
    local isKiting = threat and threat.kiting == true
    local estimatedEta = math.clamp(threat and threat.time or 0.25, 0, 0.40)
    local duration = veryClose
        and CFG.CloseOrbitTimeout
        or (isKiting and CFG.KitePulseDuration
        or math.clamp(0.18 + estimatedEta * 0.24, 0.20, CFG.DodgeDuration))

    activeDodge = {
        direction = direction,
        startedAt = now,
        finishAt = now + duration,
        retargetAt = now + (isKiting and CFG.KiteReplanInterval or duration * CFG.RetargetFraction),
        retargeted = false,
        retargetNow = false,
        kiting = isKiting,
        orbiting = veryClose and sourceCharacter ~= nil,
        orbitSide = preferredSide,
        orbitDirection = direction,
        orbitStartedAt = veryClose and now or nil,
        orbitProgress = 0,
        lastOrbitAngle = nil,
        nextOrbitPlanAt = 0,
        lastMotionPosition = root.Position,
        lastMotionCheckAt = now,
        character = character,
        humanoid = humanoid,
        root = root,
        threat = threat,
        score = score,
        clearance = clearance,
        patternStartAt = now,
        styleOffset = math.random(1, #STYLE_NAMES),
        patternSide = preferredSide,
        lastStyleSafetyAt = 0,
        lastStyleUpdateAt = now,
        smoothedStyleDirection = direction,
    }

    if activeDodge.orbiting and sourceCharacter then
        local _, orbitTargetRoot = getCharacterParts(sourceCharacter)
        activeDodge.lastOrbitAngle = orbitAngle(root, orbitTargetRoot)
    end

    local directionName = "STRAFE"
    if direction:Dot(flat(root.CFrame.RightVector)) > 0.45 then
        directionName = "RIGHT CUT"
    elseif direction:Dot(flat(root.CFrame.RightVector)) < -0.45 then
        directionName = "LEFT CUT"
    end
    setStatus(veryClose and "CLOSE ORBIT" or (isKiting and ("KITE: " .. directionName) or ("DODGE: " .. directionName)),
        veryClose and "Wall-aware circular evade" or string.format("%s • %.1f studs clear", threat.kind or "threat", clearance))
    return true
end

-- Hold space when a killer enters the pressure radius. Start only when it is
-- approaching/facing us (or critically close), then continue until separation is restored.
local function findKiteThreat(myRoot)
    if not CFG.KiteEnabled then
        kiteFocusCharacter = nil
        return nil
    end

    local nowFocus = kiteFocusCharacter
    if nowFocus then
        local focusPlayer = Players:GetPlayerFromCharacter(nowFocus)
        local _, focusRoot = getCharacterParts(nowFocus)
        if focusPlayer and isKiller(focusPlayer) and focusRoot then
            local offset = focusRoot.Position - myRoot.Position
            local distance = offset.Magnitude
            if math.abs(offset.Y) <= CFG.MaxThreatVerticalSeparation and distance <= CFG.KiteReleaseRange then
                return {
                    time = CFG.KitePulseDuration,
                    position = focusRoot.Position,
                    velocity = focusRoot.AssemblyLinearVelocity,
                    kind = "SPACE CONTROL",
                    killerCharacter = nowFocus,
                    sourceRoot = focusRoot,
                    kiting = true,
                }
            end
        end
        kiteFocusCharacter = nil
    end

    local bestCharacter, bestRoot, bestDistance = nil, nil, math.huge
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and isKiller(player) and player.Character then
            local _, killerRoot = getCharacterParts(player.Character)
            if killerRoot then
                local offset = killerRoot.Position - myRoot.Position
                local distance = offset.Magnitude
                if math.abs(offset.Y) <= CFG.MaxThreatVerticalSeparation
                    and distance <= CFG.KiteStartRange and distance < bestDistance then
                    local closing = closingSpeed(myRoot, killerRoot)
                    local facing = facingUs(myRoot, killerRoot)
                    if distance <= CFG.KiteHardRange
                        or closing >= CFG.KiteClosingThreshold
                        or facing then
                        bestCharacter, bestRoot, bestDistance = player.Character, killerRoot, distance
                    end
                end
            end
        end
    end

    if not bestCharacter then return nil end
    kiteFocusCharacter = bestCharacter
    return {
        time = CFG.KitePulseDuration,
        position = bestRoot.Position,
        velocity = bestRoot.AssemblyLinearVelocity,
        kind = "SPACE CONTROL",
        killerCharacter = bestCharacter,
        sourceRoot = bestRoot,
        kiting = true,
    }
end

local function onKillerAnimation(player, character, track)
    if shuttingDown or not CFG.Enabled or not CFG.AnimationTrigger then return end
    if player.Character ~= character or not isKiller(player) then return end

    local myCharacter = LocalPlayer.Character
    local _, myRoot = getCharacterParts(myCharacter)
    local _, killerRoot = getCharacterParts(character)
    if not myRoot or not killerRoot or localCharacterBlocked(myCharacter, myCharacter:FindFirstChildOfClass("Humanoid")) then
        return
    end

    local animationOffset = myRoot.Position - killerRoot.Position
    local distance = animationOffset.Magnitude
    if distance > CFG.AnimationRange then return end
    if math.abs(animationOffset.Y) > CFG.MaxThreatVerticalSeparation then return end
    if CFG.RequireLineOfSight and not hasLineOfSight(myRoot, killerRoot, character) then
        return
    end

    local closing = closingSpeed(myRoot, killerRoot)
    local facing = facingUs(myRoot, killerRoot)
    local attackHint = attackLike(track)

    -- Keep all animations observable, but avoid blindly dodging an idle animation
    -- from far away. Very close movement is treated as a critical cue.
    local critical = distance <= CFG.CriticalAnimationRange
    local smartThreat = closing >= CFG.MinimumClosingSpeed
        or (facing and distance <= CFG.CloseFacingRange)
        or attackHint

    if not critical and not smartThreat then
        return
    end

    local eta = math.clamp((distance - 2.0) / math.max(closing, 0.1), 0, 0.45)
    -- Ignore early animation cues: react only to a close cue or near-immediate hit.
    if not critical and eta > 0.18 then return end
    local threat = {
        time = critical and math.min(eta, 0.12) or eta,
        position = killerRoot.Position,
        velocity = killerRoot.AssemblyLinearVelocity,
        kind = attackHint and "attack animation" or "killer animation",
        killerCharacter = character,
        sourceRoot = killerRoot,
    }
    requestDodge(threat, critical)
end

local function watchCharacter(player, character)
    if not character or player == LocalPlayer then return end

    if not isKiller(player) then
        disconnect(characterConnections[character])
        characterConnections[character] = nil
        watchedCharacters[character] = nil
        characterTokens[character] = (characterTokens[character] or 0) + 1
        return
    end

    if watchedCharacters[character] then return end
    watchedCharacters[character] = true
    local token = (characterTokens[character] or 0) + 1
    characterTokens[character] = token

    task.spawn(function()
        local humanoid = character:WaitForChild("Humanoid", 5)
        local animator = humanoid and (
            humanoid:FindFirstChildOfClass("Animator")
            or humanoid:WaitForChild("Animator", 5)
        )
        if not animator then
            if characterTokens[character] == token then watchedCharacters[character] = nil end
            return
        end
        if shuttingDown or characterTokens[character] ~= token
            or player.Character ~= character or not isKiller(player) then
            return
        end

        disconnect(characterConnections[character])
        characterConnections[character] = animator.AnimationPlayed:Connect(function(track)
            onKillerAnimation(player, character, track)
        end)
    end)
end

local function refreshPlayer(player)
    if player.Character then watchCharacter(player, player.Character) end
end

local function watchPlayer(player)
    if player == LocalPlayer or playerConnections[player] then return end

    local conns = {}
    playerConnections[player] = conns
    table.insert(conns, player.CharacterAdded:Connect(function(character)
        watchCharacter(player, character)
    end))
    table.insert(conns, player.CharacterRemoving:Connect(function(character)
        characterTokens[character] = (characterTokens[character] or 0) + 1
        watchedCharacters[character] = nil
        disconnect(characterConnections[character])
        characterConnections[character] = nil
        lastByKiller[character] = nil
        if activeDodge and activeDodge.threat and activeDodge.threat.killerCharacter == character then
            activeDodge = nil
        end
    end))
    table.insert(conns, player:GetPropertyChangedSignal("Team"):Connect(function()
        refreshPlayer(player)
    end))
    table.insert(conns, player:GetAttributeChangedSignal("Role"):Connect(function()
        refreshPlayer(player)
    end))
    table.insert(conns, player:GetAttributeChangedSignal("Killer"):Connect(function()
        refreshPlayer(player)
    end))
    refreshPlayer(player)
end

local function makeUI()
    -- The game/executor may replace PlayerGui during a location transition.
    -- Disconnect old UIS handlers before rebuilding so taps never double-toggle.
    for _, connection in ipairs(uiConnections) do disconnect(connection) end
    table.clear(uiConnections)

    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        or LocalPlayer:WaitForChild("PlayerGui", 8)
    if not playerGui then return end

    local old = playerGui:FindFirstChild("VD_AutoMansV6")
    if old then old:Destroy() end

    gui = Instance.new("ScreenGui")
    gui.Name = "VD_AutoMansV6"
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 9999
    gui.Parent = playerGui

    -- Compact single-control pill; the same surface supports tap and one-finger drag.
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    local frame = Instance.new("Frame")
    frame.Name = "Panel"
    frame.AnchorPoint = Vector2.new(1, 0.5)
    frame.Position = UDim2.new(1, -12, 0.70, 0)
    frame.Size = UDim2.fromOffset(104, 38)
    frame.BackgroundColor3 = Color3.fromRGB(18, 22, 31)
    frame.BackgroundTransparency = 0.04
    frame.BorderSizePixel = 0
    frame.Active = false
    frame.ZIndex = 100
    frame.Parent = gui
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 11)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(70, 148, 208)
    stroke.Transparency = 0.2
    stroke.Thickness = 1
    stroke.Parent = frame

    toggleButton = Instance.new("TextButton")
    toggleButton.Name = "Toggle"
    toggleButton.Position = UDim2.fromOffset(3, 3)
    toggleButton.Size = UDim2.new(1, -6, 1, -6)
    toggleButton.BorderSizePixel = 0
    toggleButton.TextColor3 = Color3.new(1, 1, 1)
    toggleButton.Font = Enum.Font.GothamBold
    toggleButton.TextSize = 13
    toggleButton.AutoButtonColor = false
    toggleButton.Active = true
    toggleButton.Selectable = false
    toggleButton.ZIndex = 101
    toggleButton.Parent = frame
    Instance.new("UICorner", toggleButton).CornerRadius = UDim.new(0, 8)

    -- Keep the legacy status labels nil: no extra text/UI is shown.
    statusLabel, detailLabel = nil, nil

    local dragging = false
    local dragMoved = false
    local dragStart, startPosition
    local activeInput

    local function updateButton()
        toggleButton.Text = CFG.Enabled and "MANS  •  ON" or "MANS  •  OFF"
        toggleButton.BackgroundColor3 = CFG.Enabled
            and Color3.fromRGB(28, 131, 84)
            or Color3.fromRGB(113, 53, 60)
    end

    local function toggleMans()
        CFG.Enabled = not CFG.Enabled
        if not CFG.Enabled then
            -- Stop the automation immediately; do not issue Move(Vector3.zero),
            -- because that briefly overrides the player's own joystick input.
            activeDodge = nil
            kiteFocusCharacter = nil
        end
        updateButton()
        setStatus(CFG.Enabled and "SCANNING" or "PAUSED",
            CFG.Enabled and "Auto Mans enabled" or "Auto Mans paused")
    end

    -- Use one gesture handler for taps and drags so mobile executor/UI timing
    -- cannot fire a delayed Activated event or toggle twice.

    connectUI(toggleButton.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragMoved = false
            dragStart = input.Position
            startPosition = frame.Position
            activeInput = input
        end
    end)

    connectUI(UserInputService.InputChanged, function(input)
        if not dragging or not activeInput or not dragStart or not startPosition then return end
        local isMatchingTouch = activeInput.UserInputType == Enum.UserInputType.Touch
            and input == activeInput
        local isMouseMove = activeInput.UserInputType == Enum.UserInputType.MouseButton1
            and input.UserInputType == Enum.UserInputType.MouseMovement
        if isMatchingTouch or isMouseMove then
            local delta = input.Position - dragStart
            -- Ignore normal touch jitter. A tap toggles; a real swipe drags.
            if delta.Magnitude >= 12 then dragMoved = true end
            if dragMoved then
                local xOffset = startPosition.X.Offset + delta.X
                local yOffset = startPosition.Y.Offset + delta.Y
                local camera = Workspace.CurrentCamera
                if camera then
                    local view = camera.ViewportSize
                    xOffset = math.clamp(xOffset, frame.AbsoluteSize.X - view.X, 0)
                    local yMin = frame.AbsoluteSize.Y / 2 - startPosition.Y.Scale * view.Y
                    local yMax = view.Y - frame.AbsoluteSize.Y / 2 - startPosition.Y.Scale * view.Y
                    yOffset = math.clamp(yOffset, yMin, yMax)
                end
                frame.Position = UDim2.new(
                    startPosition.X.Scale, xOffset,
                    startPosition.Y.Scale, yOffset
                )
            end
        end
    end)

    connectUI(UserInputService.InputEnded, function(input)
        if not dragging or not activeInput then return end
        local touchEnded = input == activeInput
        local mouseEnded = activeInput.UserInputType == Enum.UserInputType.MouseButton1
            and input.UserInputType == Enum.UserInputType.MouseButton1
        if touchEnded or mouseEnded then
            local wasTap = not dragMoved
            dragging = false
            activeInput = nil
            dragStart = nil
            startPosition = nil
            dragMoved = false
            if wasTap then
                toggleMans()
            end
        end
    end)

    updateButton()
end

local function planCloseOrbit(dodge, now)
    if not dodge or not dodge.root or not dodge.root.Parent then return nil end
    local threat = dodge.threat
    local targetCharacter = threat and threat.killerCharacter
    local _, targetRoot = getCharacterParts(targetCharacter)
    if not targetRoot then return nil end

    if now < (dodge.nextOrbitPlanAt or 0) and dodge.orbitDirection then
        return dodge.orbitDirection
    end
    dodge.nextOrbitPlanAt = now + CFG.OrbitReplanInterval

    local root = dodge.root
    local away = unitOrZero(flat(root.Position - (targetRoot.Position + flat(targetRoot.AssemblyLinearVelocity) * 0.06)))
    if away.Magnitude < 0.01 then away = unitOrZero(flat(root.CFrame.LookVector)) end
    if away.Magnitude < 0.01 then away = Vector3.new(1, 0, 0) end

    local tangent = Vector3.new(-away.Z, 0, away.X) * (dodge.orbitSide or 1)
    local distance = flat(root.Position - targetRoot.Position).Magnitude
    -- Correct toward a stable radius; a constant outward push tends to create spirals.
    local radialError = CFG.CloseOrbitTargetRadius - distance
    local radialWeight = math.clamp(radialError * 0.55, -0.80, 0.95)
    if distance < 2.65 then
        radialWeight = math.max(radialWeight, 1.0) -- escape immediate collision range
    end
    local desired = unitOrZero(tangent * CFG.OrbitTangentWeight + away * radialWeight)
    if desired.Magnitude < 0.01 then desired = away end

    local exclusions = buildCharacterExclusions(true)
    moveRayParams.FilterDescendantsInstances = exclusions
    groundRayParams.FilterDescendantsInstances = exclusions

    local function rotated(v, degrees)
        local angle = math.rad(degrees)
        local c, si = math.cos(angle), math.sin(angle)
        return unitOrZero(Vector3.new(v.X * c - v.Z * si, 0, v.X * si + v.Z * c))
    end

    local candidates = {
        desired,
        rotated(desired, 25), rotated(desired, -25),
        rotated(desired, 50), rotated(desired, -50),
        rotated(desired, 80), rotated(desired, -80),
        tangent, -tangent, away,
    }
    local bestDirection, bestScore = nil, -math.huge
    for _, candidate in ipairs(candidates) do
        local clearDirection, clearance = directionClearance(root, candidate)
        if clearDirection then
            local orbitAlignment = clearDirection:Dot(desired)
            local outward = clearDirection:Dot(away)
            local score = orbitAlignment * 3.0 + outward * (distance < 2.6 and 0.8 or 0.08)
                + math.min(clearance or 0, CFG.ProbeDistance) * 0.09
            if score > bestScore then
                bestScore, bestDirection = score, clearDirection
            end
        end
    end

    if not bestDirection then
        -- If the circle points into a wall/corner, abandon it and use the
        -- general threat-scored escape planner instead of pushing into geometry.
        bestDirection = select(1, chooseDodgeDirection(root, dodge.humanoid, threat))
        dodge.orbitSide = -(dodge.orbitSide or 1)
        dodge.orbitProgress = 0
        dodge.lastOrbitAngle = orbitAngle(root, targetRoot)
        if not bestDirection then
            -- No proven safe direction: stop pushing into the obstacle and retry
            -- on the next orbit-planning tick.
            bestDirection = Vector3.zero
        end
    end

    dodge.orbitDirection = bestDirection
    dodge.direction = bestDirection
    return bestDirection
end

local function cleanup()
    if shuttingDown then return end
    shuttingDown = true
    activeDodge = nil
    kiteFocusCharacter = nil

    pcall(function() RunService:UnbindFromRenderStep("VD_AutoMansV6_Move") end)

    for _, connection in ipairs(uiConnections) do disconnect(connection) end
    table.clear(uiConnections)

    for _, connection in ipairs(connections) do disconnect(connection) end
    table.clear(connections)

    for _, conns in pairs(playerConnections) do
        for _, connection in ipairs(conns) do disconnect(connection) end
    end
    table.clear(playerConnections)

    for _, connection in pairs(characterConnections) do disconnect(connection) end
    table.clear(characterConnections)
    table.clear(trackedParts)
    table.clear(lastByKiller)

    if gui and gui.Parent then pcall(function() gui:Destroy() end) end
    gui, statusLabel, detailLabel, toggleButton = nil, nil, nil, nil
end

env.VD_AUTO_MANS_STOP = cleanup
_G.VD_AUTO_MANS_STOP = cleanup

pcall(function() RunService:UnbindFromRenderStep("VD_AutoMansV6_Move") end)
RunService:BindToRenderStep(
    "VD_AutoMansV6_Move",
    Enum.RenderPriority.Last.Value,
    function()
        if shuttingDown then return end
        local dodge = activeDodge
        if not dodge then return end

        local now = os.clock()
        if not CFG.Enabled or now >= dodge.finishAt then
            -- Simply release our render-step steering; normal player controls resume.
            activeDodge = nil
            return
        end

        if LocalPlayer.Character ~= dodge.character
            or not dodge.root.Parent
            or not dodge.humanoid.Parent
            or dodge.humanoid.Health <= 0 then
            activeDodge = nil
            return
        end

        -- Emergency takeover is conditional: release when the target leaves the
        -- critical bubble, disappears, the actual 360 completes, or the safety timer expires.
        if dodge.orbiting then
            local _, targetRoot = getCharacterParts(dodge.threat and dodge.threat.killerCharacter)
            if not targetRoot then
                activeDodge = nil
                return
            end

            local orbitOffset = dodge.root.Position - targetRoot.Position
            local distance = orbitOffset.Magnitude
            if math.abs(orbitOffset.Y) > CFG.CriticalVerticalSeparation
                or distance > CFG.EmergencyTakeoverReleaseRange
                or now - (dodge.orbitStartedAt or dodge.startedAt) >= CFG.CloseOrbitTimeout then
                activeDodge = nil
                return
            end

            local angle = orbitAngle(dodge.root, targetRoot)
            if angle then
                if dodge.lastOrbitAngle then
                    local delta = signedAngleDelta(dodge.lastOrbitAngle, angle)
                    dodge.orbitProgress = (dodge.orbitProgress or 0)
                        + delta * (dodge.orbitSide or 1)
                end
                dodge.lastOrbitAngle = angle
            end
            if (dodge.orbitProgress or 0) >= (math.pi * 2) then
                activeDodge = nil
                return
            end
        end

        -- One mid-maneuver re-plan: avoids locking into a bad line if the
        -- killer cuts across after the first half of the dodge.
        local shouldRetargetKite = dodge.kiting and now >= dodge.retargetAt
        local shouldRetargetDodge = not dodge.kiting and not dodge.retargeted
            and (dodge.retargetNow or now >= dodge.retargetAt)
        if shouldRetargetKite or shouldRetargetDodge then
            local threat = dodge.threat
            local freshThreat = nil

            if threat and threat.killerCharacter then
                local _, enemyRoot = getCharacterParts(threat.killerCharacter)
                if enemyRoot then
                    freshThreat = {
                        time = 0.12,
                        position = enemyRoot.Position,
                        velocity = enemyRoot.AssemblyLinearVelocity,
                        kind = threat.kind or "re-target",
                        killerCharacter = threat.killerCharacter,
                        sourceRoot = enemyRoot,
                        kiting = dodge.kiting == true,
                    }
                end
            elseif threat and threat.projectile and threat.projectile.Parent then
                freshThreat = {
                    time = 0.12,
                    position = threat.projectile.Position,
                    velocity = threat.projectile.AssemblyLinearVelocity,
                    kind = threat.kind or "projectile re-target",
                    projectile = threat.projectile,
                }
            end

            if freshThreat then
                freshThreat.kiting = dodge.kiting == true
                local newDirection, newScore, clearance = chooseDodgeDirection(dodge.root, dodge.humanoid, freshThreat)
                if newDirection then
                    dodge.direction = newDirection
                    dodge.score = newScore
                    dodge.clearance = clearance
                    if dodge.kiting then
                        setStatus("KITE: ADJUST", string.format("Path refreshed • %.1f clear", clearance))
                    else
                        setStatus("RE-WEAVE", string.format("Updated path • %.1f studs clear", clearance))
                    end
                end
            end
            if not dodge.kiting then dodge.retargeted = true end
            dodge.retargetNow = false
            if dodge.kiting then dodge.retargetAt = now + CFG.KiteReplanInterval end
        end

        if dodge.orbiting then
            local orbitDirection = planCloseOrbit(dodge, now)
            if orbitDirection then
                if orbitDirection.Magnitude < 0.02 then
                    activeDodge = nil
                    return
                end
                dodge.direction = orbitDirection
            end

            -- Recover from corners: if we are issuing movement but make almost
            -- no horizontal progress, flip orbit direction and find another safe path.
            if now - (dodge.lastMotionCheckAt or now) >= CFG.StuckCheckInterval then
                local previousPosition = dodge.lastMotionPosition or dodge.root.Position
                local progress = flat(dodge.root.Position - previousPosition).Magnitude
                dodge.lastMotionPosition = dodge.root.Position
                dodge.lastMotionCheckAt = now
                if progress < CFG.StuckMinProgress then
                    dodge.orbitSide = -(dodge.orbitSide or 1)
                    dodge.orbitProgress = 0
                    local _, targetRoot = getCharacterParts(dodge.threat and dodge.threat.killerCharacter)
                    dodge.lastOrbitAngle = orbitAngle(dodge.root, targetRoot)
                    dodge.orbitDirection = nil
                    dodge.nextOrbitPlanAt = 0
                    local escapeDirection = select(1, chooseDodgeDirection(dodge.root, dodge.humanoid, dodge.threat))
                    if escapeDirection then
                        dodge.direction = escapeDirection
                        dodge.orbitDirection = escapeDirection
                        dodge.nextOrbitPlanAt = now + 0.10
                    else
                        -- Never keep overriding the joystick while trapped; hand back control.
                        activeDodge = nil
                        return
                    end
                end
            end
        elseif CFG.MovementStylesEnabled then
            local styledDirection = styledDirectionFor(dodge, now)
            if not styledDirection or styledDirection.Magnitude <= 0.02 then
                -- styledDirectionFor returns zero when every tested path is blocked.
                -- Do not fall back to the previous direction and keep pushing the wall.
                activeDodge = nil
                return
            end
            dodge.direction = styledDirection
        end

        dodge.humanoid:Move(dodge.direction, false)
    end
)

connect(Players.PlayerAdded, watchPlayer)
connect(Players.PlayerRemoving, function(player)
    if player.Character then
        local character = player.Character
        characterTokens[character] = (characterTokens[character] or 0) + 1
        disconnect(characterConnections[character])
        characterConnections[character] = nil
        watchedCharacters[character] = nil
        lastByKiller[character] = nil
    end
    for _, connection in ipairs(playerConnections[player] or {}) do disconnect(connection) end
    playerConnections[player] = nil
end)

connect(Workspace.DescendantAdded, function(instance)
    if not CFG.ProjectilePrediction or not instance:IsA("BasePart") then return end
    task.delay(CFG.NewPartDelay, function()
        if not shuttingDown then trackPart(instance) end
    end)
end)

-- Scan existing parts without blocking a single frame for the full map.
task.spawn(function()
    local descendants = Workspace:GetDescendants()
    for index, instance in ipairs(descendants) do
        if shuttingDown then break end
        if instance:IsA("BasePart") then trackPart(instance) end
        if index % CFG.InitialScanYieldEvery == 0 then task.wait() end
    end
end)

connect(RunService.Heartbeat, function()
    if shuttingDown or not CFG.Enabled or isKiller(LocalPlayer) then return end

    local now = os.clock()
    if now - lastPrediction < CFG.PredictionInterval then return end
    lastPrediction = now

    local character = LocalPlayer.Character
    local humanoid, root = getCharacterParts(character)
    if not humanoid or not root or localCharacterBlocked(character, humanoid) then
        activeDodge = nil
        return
    end

    local bestThreat = nil

    -- Emergency proximity takeover: only when a killer is genuinely close.
    -- It issues a short evasive movement burst, then returns control to the player.
    local nearestCriticalDistance = CFG.EmergencyTakeoverRange
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and isKiller(player) then
            local _, enemyRoot = getCharacterParts(player.Character)
            if enemyRoot then
                local offset = enemyRoot.Position - root.Position
                local distance = offset.Magnitude
                local sameLevel = math.abs(offset.Y) <= CFG.CriticalVerticalSeparation
                local visible = hasLineOfSight(root, enemyRoot, player.Character)
                if sameLevel and visible and distance <= nearestCriticalDistance then
                    nearestCriticalDistance = distance
                    bestThreat = {
                        time = 0,
                        score = -1,
                        position = enemyRoot.Position,
                        velocity = enemyRoot.AssemblyLinearVelocity,
                        kind = "CRITICAL PROXIMITY",
                        killerCharacter = player.Character,
                        sourceRoot = enemyRoot,
                    }
                end
            end
        end
    end

    if CFG.PlayerPrediction and not bestThreat then
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer and isKiller(player) then
                local threat = predictKillerThreat(root, player.Character)
                if threat and (not bestThreat or threat.score < bestThreat.score) then
                    bestThreat = threat
                end
            end
        end
    end

    if CFG.ProjectilePrediction then
        local projectile = predictProjectileThreat(root)
        if projectile and (not bestThreat or projectile.score < bestThreat.score) then
            bestThreat = projectile
        end
    end

    local kiteThreat = findKiteThreat(root)

    -- Respond only to imminent hazards. No continuous chase, kite, or fallback
    -- movement while a killer is merely nearby.
    if bestThreat and bestThreat.projectile then
        if (bestThreat.time or 1) <= 0.24 then
            requestDodge(bestThreat, (bestThreat.time or 1) <= 0.14)
        end
    elseif bestThreat and bestThreat.killerCharacter
        and ((bestThreat.time or 1) <= 0.18 or bestThreat.kind == "CRITICAL PROXIMITY") then
        requestDodge(bestThreat, true)
    elseif kiteThreat then
        -- Normally unreachable because KiteEnabled is false; retained as a safe guard.
        requestDodge(kiteThreat, true)
    else
        kiteFocusCharacter = nil
    end
end)

for _, player in ipairs(Players:GetPlayers()) do watchPlayer(player) end
makeUI()
setStatus("SCANNING", "Close-range orbit • wall-aware")

-- Recreate only the small panel if PlayerGui/ScreenGui is removed or replaced.
-- This preserves the current ON/OFF state and does not restart the movement logic.
local nextUIRepairAt = 0
connect(RunService.Heartbeat, function()
    if shuttingDown then return end
    local now = os.clock()
    if now < nextUIRepairAt then return end

    local currentPlayerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local panelMissing = not gui or not gui.Parent
        or not currentPlayerGui or gui.Parent ~= currentPlayerGui
        or not gui:FindFirstChild("Panel")
    if panelMissing then
        nextUIRepairAt = now + 0.5
        if currentPlayerGui then makeUI() end
    end
end)
print("[VD Auto Mans V6.1] Adaptive Orbit loaded; live-match behavior is not verified.")
