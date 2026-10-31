local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local AXIS_X, AXIS_Y, AXIS_Z = Vector3.xAxis, Vector3.yAxis, Vector3.zAxis
local ZERO = Vector3.zero
local TAU = math.pi * 2
local DEG = math.pi / 180

local Config = {
	StartEnabled = true,
	Debug = false,
	NpcModel = nil,
	ManualOverride = false,

	ReactionMinMs = 0,
	ReactionMaxMs = 8,
	TurnRateNormal = 480,
	TurnRateEmergency = 2600,
	SpeedAccel = 6,
	SpeedDecel = 9,
	BrainHz = 30,
	BrainHzDanger = 60,
	RayInterval = 0.05,
	UseAccel = true,

	ConflictRange = 38,
	OptimalMin = 8,
	OptimalMax = 14,
	EnemyAttackRange = 9,
	IncludeTeammates = false,
	NpcFolder = nil,
	IsEnemy = nil,
	AttackHitFrac = 0.38,
	MeleeReactWindow = 0.6,
	MeleeDashLead = 0.3,
	MeleeDashDistance = 10,
	EvadeSideRandom = 0.2,
	CounterWindow = 0.7,
	OnCounterWindow = nil,
	FeintChancePerSec = 0.45,
	FlankEnabled = true,
	Mode = "Escape",
	EscapeRange = 36,
	EscapeDashRange = 6,

	AutoTune = true,
	AutoDetectNpcs = true,
	SpeedBonusPct = 0.15,
	SpeedBonusMax = 4,
	DashEnabled = false,
	MoveDodgeCooldown = 0.12,
	UseCover = true,
	CoverWeight = 0.5,
	CoverStep = 6,
	OpenSpaceWeight = 0.5,
	LimbTracking = true,
	LimbMinSpeed = 18,
	LogHits = true,
	InstantStart = true,
	VelocityDrive = true,
	WallLoop = true,
	WallLoopWeight = 0.8,
	BruteForceScan = false,
	FreshRadius = 400,
	FreshBudget = 150,
	RangedAntiAim = true,
	RangedRange = 160,
	IsThreat = nil,
	AllowPhysicsState = false,
	AutoVault = true,
	VaultMaxHeight = 4.2,
	WallKick = true,
	WallKickSpeedMul = 1.3,
	WallKickHeight = 4,
	WallKickCooldown = 1.2,
	FastLeadExtra = 0.5,
	FastLeadPerSpeed = 0.004,
	DodgeJump = true,
	DodgeJumpCooldown = 0.9,
	ZigzagAngle = 55,
	ZigzagPeriod = 0.32,
	InOutStepIn = 0.15,
	TurnRatePattern = 2600,
	SpeedAccelDodge = 45,
	EscapeZigzag = true,
	EscapeZigzagAngle = 35,
	EscapePeriod = 0.55,
	EscapeJuke = true,
	EscapeGoal = nil,
	FaceEnemy = false,

	ScanRadius = 80,
	MaxScanParts = 1200,
	CalmScanEvery = 1,
	DangerScanEvery = 1,
	DangerTTI = 0.9,
	MinRelSpeed = 28,
	MaxThreatSize = 24,
	MaxProjectileRadius = 6,
	IgnoreOtherCharacters = false,
	SlowPruneSeconds = 0.4,

	Horizon = 2,
	SampleStep = 0.04,
	TriggerLead = 0.5,
	BodyRadius = 2.4,
	BodyHalfHeight = 2.6,
	HitMargin = 1.2,
	WalkDodge = true,
	WalkDodgeTTI = 0.42,

	PingSign = 1,
	PingMaxMs = 600,

	AOEGrowthRate = 8,
	AOEMinGrowthStep = 0.3,
	ZoneLookahead = 0.35,
	ZoneLinger = 1.2,
	MaxZoneRadius = 150,
	MinZoneDiameter = 5,
	FreshStaticZones = false,

	FreshBeams = true,
	FreshWindow = 0.4,
	BeamAspect = 5,
	BeamMaxThickness = 8,
	BeamLookahead = 0.15,
	BeamLinger = 0.5,

	DashDistance = 15,
	DashMaxDistance = 30,
	DashMinDistance = 5,
	DashDuration = 0.2,
	DashAvgSpeed = 75,
	DashCooldown = 0.85,
	DashForce = 1e7,
	PostDashSettle = 0.12,
	WallPadding = 1.6,
	VoidCheckDepth = 45,

	TreatZeroWalkSpeedAsStun = true,
	DetectRagdollConstraints = true,
	ExtraBlockCheck = nil,
	OnDodge = nil,
}

local rng = Random.new()
local Enabled = Config.StartEnabled
local pingMs = 0
local fsm = "Idle"
local cachedReason = nil
local MIN_SP2 = Config.MinRelSpeed * Config.MinRelSpeed

local ctx = {
	char = nil, hum = nil, hrp = nil,
	lv = nil, att = nil, ao = nil,
	rayParams = nil, overlapParams = nil,
	conns = {},
	dashing = false, dashStart = 0, dashDur = 0.2, dashDir = Vector3.zero, dashPeak = 0,
	cooldownEnd = 0, settleUntil = 0,
	lastDirX = 0, lastDirZ = 0, lastDirTime = -10,
	baseWS = 16, lastWS = 16, bonusCur = 0, extents = Vector3.new(4, 5, 1), feetOff = 3, canJump = true,
}

local MV_DODGE, MV_MELEE, MV_UNSTICK = 1, 2, 3
local PAT_LINE, PAT_ZIGZAG, PAT_ARC, PAT_ORBIT, PAT_INOUT = 1, 2, 3, 4, 5
local Ctl = {
	active = false, facing = false, prevAutoRotate = true,
	heading = 0, speed = 0,
	wantX = 0, wantZ = 0, wantSpeed = 0, wantTurn = 480,
	mvActive = false, mvX = 0, mvZ = 0, mvUntil = 0, mvSpeed = 1, mvKind = 0,
	mvPattern = 1, mvStart = 0, mvDur = 0.5, mvAx = 0, mvAz = 0, mvSpin = 1, mvR0 = 8, mvPhase = 0, jukeAt = 0, escRange = 40, jumpReadyAt = 0, vaultReadyAt = 0, kickReadyAt = 0, combatOn = false, nextTune = 0, caution = 0, nextCast = 0, coverTick = 0, rangedAt = 0, rangedSide = 1, nextBrute = 0, avgDt = 0.016, nextAttr = 0, hits = 0, lastErr = "", errCount = 0, driveVel = false, velOn = false, noComply = 0, driveUntil = 0, refSpeed = 16, zeroWs = 0, customMove = false,
	threatUntil = 0,
	orbitDir = rng:NextNumber() < 0.5 and 1 or -1, nextFlipAt = 0,
	nextStutterAt = 0, stutterUntil = 0, stutterScale = 1,
	feintPhase = 0, feintUntil = 0, feintCooldown = 0, feintSide = 1,
	flankUntil = 0, nextFlankAt = 0, flankSide = 1,
	pendingDodgeAt = 0, noDelayUntil = 0,
	meleeReactAt = 0, meleeFor = nil,
	stuckT = 0, stuckX = 0, stuckZ = 0, unstickUntil = 0, unstickX = 0, unstickZ = 0,
	noiseSeed = rng:NextNumber(0, 1000),
	nextEnemyRefresh = 0,
}

local threats = {}
local pool = {}
local watch = setmetatable({}, { __mode = "k" })
local bornAt = setmetatable({}, { __mode = "k" })
local fresh = {}
local hitLog = {}
local errLog = {}
local scanIdx = 0
local stagger = 0
local frame = 0
local dangerUntil = 0
local active = {}
local activeN = 0

local MAXC = 48
local candX, candZ, candBonus, candScore, candUsed = {}, {}, {}, {}, {}
local candN = 0
local N_DIR = 16
local baseCos, baseSin = {}, {}
for i = 0, 15 do
	local a = i * (TAU / 16)
	baseCos[i + 1] = math.cos(a)
	baseSin[i + 1] = math.sin(a)
end

local RAY_LEN = 8
local RAY_FAR = 22
local rayClear, rayVoid, rayNx, rayNz, rayFar, rayCover = {}, {}, {}, {}, {}, {}
local castTick = 0
for i = 1, N_DIR do
	rayClear[i] = 1
	rayVoid[i] = false
	rayNx[i] = 0
	rayNz[i] = 0
	rayFar[i] = 1
	rayCover[i] = 0
end

local enemyMap = {}
local enemyList = {}
local enemyN = 0
local epoch = 0
local target = nil
local seenTracks = setmetatable({}, { __mode = "k" })

local MOVER_CLASSES = { "BodyVelocity", "BodyForce", "BodyPosition", "BodyThrust", "LinearVelocity", "VectorForce", "AlignPosition" }

local BAD_STATES = {
	[Enum.HumanoidStateType.Dead] = true,
	[Enum.HumanoidStateType.Ragdoll] = true,
	[Enum.HumanoidStateType.FallingDown] = true,
	[Enum.HumanoidStateType.Physics] = true,
	[Enum.HumanoidStateType.PlatformStanding] = true,
	[Enum.HumanoidStateType.Seated] = true,
}

local refreshUI

local function dbg(...)
	if Config.Debug then
		print("[HumanlikeAutoMans]", ...)
	end
end

local function hasMover(part)
	for i = 1, #MOVER_CLASSES do
		if part:FindFirstChildWhichIsA(MOVER_CLASSES[i]) then
			return true
		end
	end
	return false
end

local function setExclude(params, list)
	local ok = pcall(function()
		params.ExcludeInstances = list
	end)
	if not ok then
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = list
	end
end

local function getTarget()
	return Config.NpcModel or LocalPlayer.Character
end

local function segDist2(ox, oy, oz, dx, dy, dz, len, px, py, pz)
	local rx, ry, rz = px - ox, py - oy, pz - oz
	local t = rx * dx + ry * dy + rz * dz
	if t < 0 then
		t = 0
	elseif t > len then
		t = len
	end
	local qx, qy, qz = rx - dx * t, ry - dy * t, rz - dz * t
	return qx * qx + qy * qy + qz * qz
end

local function slotOf(dx, dz)
	local a = math.atan2(dz, dx)
	if a < 0 then
		a += TAU
	end
	return math.floor(a / (TAU / 16) + 0.5) % 16 + 1
end

local function guardReason()
	local char, hum, hrp = ctx.char, ctx.hum, ctx.hrp
	if not char or char.Parent == nil or not hum or hum.Parent == nil or not hrp or hrp.Parent == nil then
		return "NoCharacter"
	end
	if hum.Health <= 0 then
		return "Dead"
	end
	local st = hum:GetState()
	if BAD_STATES[st] and not (st == Enum.HumanoidStateType.Physics and Config.AllowPhysicsState) then
		return "BadHumanoidState"
	end
	if hum.PlatformStand then
		return "PlatformStand"
	end
	if hum.Sit then
		return "Seated"
	end
	if hrp.Anchored then
		return "Anchored"
	end
	if Config.TreatZeroWalkSpeedAsStun and not Ctl.customMove and hum.WalkSpeed <= 0.05 then
		return "Rooted"
	end
	if Config.DetectRagdollConstraints then
		local bs = char:FindFirstChildWhichIsA("BallSocketConstraint", true)
		if bs and bs.Enabled then
			return "RagdollConstraints"
		end
	end
	if Config.ExtraBlockCheck then
		local ok, r = pcall(Config.ExtraBlockCheck)
		if ok and r then
			return "Custom"
		end
	end
	return nil
end

local function updatePing()
	local ok, v = pcall(function()
		return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
	end)
	if ok and type(v) == "number" then
		v = math.clamp(v, 0, Config.PingMaxMs)
		if pingMs == 0 then
			pingMs = v
		else
			pingMs = pingMs * 0.5 + v * 0.5
		end
	end
end

local function startManeuver(now, dx, dz, kind, duration, pattern, ax, az)
	local m = math.sqrt(dx * dx + dz * dz)
	if m < 1e-4 then
		return
	end
	Ctl.mvActive = true
	Ctl.mvX, Ctl.mvZ = dx / m, dz / m
	Ctl.mvKind = kind
	Ctl.mvStart = now
	Ctl.mvDur = duration
	Ctl.mvUntil = now + duration
	Ctl.mvSpeed = 1
	Ctl.mvPattern = pattern or PAT_LINE
	Ctl.mvAx, Ctl.mvAz = ax or 0, az or 0
	Ctl.mvSpin = rng:NextNumber() < 0.5 and 1 or -1
	Ctl.mvPhase = rng:NextNumber()
	if Ctl.mvPattern == PAT_ORBIT and ctx.hrp then
		local pp = ctx.hrp.Position
		local rx, rz = pp.X - Ctl.mvAx, pp.Z - Ctl.mvAz
		Ctl.mvR0 = math.max(math.sqrt(rx * rx + rz * rz), Config.EnemyAttackRange * 0.9)
	end
	if Ctl.mvUntil > Ctl.threatUntil then
		Ctl.threatUntil = Ctl.mvUntil
	end
	Ctl.feintPhase = 0
	if Config.InstantStart and ctx.hrp then
		local nx, nz = dx / m, dz / m
		Ctl.heading = math.atan2(nz, nx)
		Ctl.speed = 1
		local sp = ctx.baseWS + math.min(Config.SpeedBonusMax, ctx.baseWS * Config.SpeedBonusPct)
		if sp < 1 then
			sp = Ctl.refSpeed
		end
		local v = ctx.hrp.AssemblyLinearVelocity
		ctx.hrp.AssemblyLinearVelocity = Vector3.new(nx * sp, v.Y, nz * sp)
	end
end

local function pickPattern(timeLeft, hasAnchor, melee)
	if timeLeft < 0.22 then
		return PAT_LINE
	end
	local r = rng:NextNumber()
	if melee then
		if hasAnchor and r < 0.4 then
			return PAT_ORBIT
		end
		if r < 0.7 then
			return PAT_ZIGZAG
		end
		return PAT_LINE
	end
	if r < 0.35 then
		return PAT_ZIGZAG
	end
	if r < 0.55 then
		return PAT_ARC
	end
	return PAT_LINE
end

local function reactDelay(timeLeft)
	local d = rng:NextNumber(Config.ReactionMinMs, Config.ReactionMaxMs) / 1000
	if timeLeft < 0.3 then
		d = d * math.max(0, timeLeft - 0.04) / 0.26
	end
	return d
end

local function maneuverDir(now, mx, mz)
	local t = now - Ctl.mvStart
	local bx, bz = Ctl.mvX, Ctl.mvZ
	local pat = Ctl.mvPattern
	if pat == PAT_ZIGZAG then

		local a = math.rad(Config.ZigzagAngle) * math.sin(TAU * (t / Config.ZigzagPeriod + Ctl.mvPhase))
		local ca, sa = math.cos(a), math.sin(a)
		return bx * ca - bz * sa, bx * sa + bz * ca
	elseif pat == PAT_ARC then

		local a = Ctl.mvSpin * TAU * math.min(1, t / math.max(Ctl.mvDur, 0.1))
		local ca, sa = math.cos(a), math.sin(a)
		return bx * ca - bz * sa, bx * sa + bz * ca
	elseif pat == PAT_ORBIT then

		local rx, rz = mx - Ctl.mvAx, mz - Ctl.mvAz
		local r = math.sqrt(rx * rx + rz * rz)
		if r < 0.5 then
			return bx, bz
		end
		local nx, nz = rx / r, rz / r
		local k = math.clamp((Ctl.mvR0 - r) / math.max(Ctl.mvR0, 1) * 1.5, -1, 1)
		return -nz * Ctl.mvSpin + nx * k, nx * Ctl.mvSpin + nz * k
	elseif pat == PAT_INOUT then

		local tx, tz = Ctl.mvAx - mx, Ctl.mvAz - mz
		local tm = math.sqrt(tx * tx + tz * tz)
		if tm < 0.1 then
			return bx, bz
		end
		tx, tz = tx / tm, tz / tm
		if t < Config.InOutStepIn then
			return tx, tz
		end
		local a = math.rad(35) * Ctl.mvSpin
		local ca, sa = math.cos(a), math.sin(a)
		return -tx * ca + tz * sa, -tx * sa - tz * ca
	end
	return bx, bz
end

local function endDash()
	local c = ctx
	if c.lv then
		c.lv.VectorVelocity = Vector3.zero
		c.lv.Enabled = false
	end
	if c.dashing then
		c.settleUntil = os.clock() + Config.PostDashSettle
	end
	c.dashing = false
end

local function autoTune(baseWS)
	if not Config.AutoTune then
		return
	end
	local base = math.max(baseWS, 4)
	local c = ctx
	c.tunedWS = baseWS
	if c.char then
		local ok, size = pcall(function()
			return c.char:GetExtentsSize()
		end)
		if ok and typeof(size) == "Vector3" then
			c.extents = size
			Config.BodyRadius = math.clamp(math.max(size.X, size.Z) * 0.5 + 0.2, 1, 6)
			Config.BodyHalfHeight = math.clamp(size.Y * 0.5, 1.5, 8)
		end
	end
	if c.char and c.hrp then
		local okb, bcf, bsize = pcall(function()
			return c.char:GetBoundingBox()
		end)
		if okb and typeof(bcf) == "CFrame" and typeof(bsize) == "Vector3" then
			local off = c.hrp.Position.Y - (bcf.Position.Y - bsize.Y * 0.5)
			if off > 0.5 then
				c.feetOff = off
			end
		end
	end
	local k = math.clamp(c.extents.Y / 5.2, 0.4, 4)
	RAY_LEN = 8 * k
	Config.MaxThreatSize = 24 * k
	Config.MaxProjectileRadius = 6 * k
	Config.MinZoneDiameter = 5 * k
	Config.BeamMaxThickness = 8 * k
	RAY_FAR = 22 * k
	Config.WallPadding = 1.6 * k
	Config.CoverStep = 6 * k
	Config.HitMargin = 1.2 * k
	Config.VoidCheckDepth = math.max(30, 45 * k)
	local jumpH = 0
	if c.hum then
		if c.hum.UseJumpPower then
			local jp = c.hum.JumpPower
			jumpH = jp * jp / (2 * Workspace.Gravity)
		else
			jumpH = c.hum.JumpHeight
		end
	end
	c.canJump = jumpH > 0.5
	if c.canJump then
		Config.VaultMaxHeight = math.clamp(jumpH * 0.6, 1.5, 10)
		Config.WallKickHeight = math.clamp(jumpH * 0.55, 1.5, 8)
	end
	Config.EnemyAttackRange = math.clamp(c.extents.Y * 1.7, 6, 18)
	Config.OptimalMin = Config.EnemyAttackRange * 0.9
	Config.OptimalMax = Config.EnemyAttackRange * 1.6
	Config.ConflictRange = math.clamp(base * 2.4, 24, 70)
	Config.EscapeRange = Config.ConflictRange * 1.15
	Config.EscapeDashRange = Config.EnemyAttackRange * 0.7
	Config.DashDistance = math.clamp(base * 0.8, 6, 26)
	Config.DashMaxDistance = Config.DashDistance * 1.9
	Config.DashMinDistance = Config.DashDistance * 0.35
	Config.DashAvgSpeed = Config.DashDistance / Config.DashDuration
	Config.MeleeDashDistance = Config.DashDistance * 0.67
	Config.MinRelSpeed = math.max(28, base * 1.7)
	MIN_SP2 = Config.MinRelSpeed * Config.MinRelSpeed
	Config.ScanRadius = math.max(90, base * 6)
end

local function startDash(now, dx, dz, dist)
	local c = ctx
	if not Config.DashEnabled then

		c.cooldownEnd = now + Config.MoveDodgeCooldown
		c.lastDirX, c.lastDirZ, c.lastDirTime = dx, dz, now
		Ctl.pendingDodgeAt = 0
		startManeuver(now, dx, dz, MV_DODGE, 0.5)
		if Config.OnDodge then
			pcall(Config.OnDodge, AXIS_X * dx + AXIS_Z * dz, dist)
		end
		return true
	end
	if not c.lv or not c.lv.Parent then
		return false
	end
	local dur = math.max(Config.DashDuration, dist / Config.DashAvgSpeed)
	c.dashDur = dur
	c.dashDir = AXIS_X * dx + AXIS_Z * dz
	c.dashPeak = 1.5 * dist / dur
	c.dashStart = now
	c.dashing = true
	c.cooldownEnd = now + Config.DashCooldown
	c.lastDirX, c.lastDirZ, c.lastDirTime = dx, dz, now
	c.lv.VectorVelocity = c.dashDir * c.dashPeak
	c.lv.Enabled = true
	Ctl.pendingDodgeAt = 0

	startManeuver(now, dx, dz, MV_DODGE, dur + 0.22)
	if Config.OnDodge then
		pcall(Config.OnDodge, c.dashDir, dist)
	end
	dbg("dash", dx, dz, dist, dur)
	return true
end

local function releaseRecord(rec)
	rec.part = nil
	pool[#pool + 1] = rec
end

local function newRecord(part, kind, now, px, py, pz, vx, vy, vz, m, growth)
	local rec = pool[#pool]
	if rec then
		pool[#pool] = nil
	else
		rec = {}
	end
	rec.part = part
	rec.kind = kind
	rec.firstSeen = now
	rec.lastSeen = now
	rec.t = now
	rec.px, rec.py, rec.pz = px, py, pz
	rec.vx, rec.vy, rec.vz = vx, vy, vz
	rec.s = m
	rec.growth = growth or 0
	rec.anchored = part.Anchored
	rec.samples = 0
	rec.tti, rec.baseTti = math.huge, math.huge
	rec.urgent = false
	rec.handledUntil = 0
	rec.dirx, rec.dirz, rec.hasDir = 0, 0, false
	rec.slowSince = 0
	rec.tracked = bornAt[part] ~= nil
	rec.activeUntil = math.huge
	rec.gravity = false
	rec.accY = 0
	rec.accX, rec.accZ = 0, 0
	rec.hitR, rec.radius, rec.safeR, rec.halfY = 0, 0, 0, 0
	rec.ox, rec.oy, rec.oz, rec.ax, rec.ay, rec.az, rec.blen, rec.lim = 0, 0, 0, 0, 0, 0, 0, 0
	if kind == "Proj" then
		rec.radius = math.min(m * 0.5, Config.MaxProjectileRadius)
		rec.hitR = rec.radius + Config.BodyRadius + Config.HitMargin
		rec.gravity = (not rec.anchored) and not hasMover(part)
		rec.accY = rec.gravity and -Workspace.Gravity or 0
	elseif kind == "AOE" then
		rec.radius = math.min(m * 0.5, Config.MaxZoneRadius)
		rec.halfY = rec.radius
		rec.safeR = rec.radius + Config.BodyRadius + Config.HitMargin
		rec.activeUntil = now + Config.ZoneLinger
	else
		rec.activeUntil = now + Config.BeamLinger
	end
	return rec
end

local function clearThreats()
	for part, rec in pairs(threats) do
		threats[part] = nil
		releaseRecord(rec)
	end
	activeN = 0
end

local function updateRecord(rec, now)
	local part = rec.part
	local p = part.Position
	local px, py, pz = p.X, p.Y, p.Z
	local dt = now - rec.t
	if rec.kind == "Proj" then
		local vx, vy, vz
		local anch = part.Anchored
		rec.anchored = anch
		if anch then
			if dt > 0.004 then
				vx = rec.vx * 0.4 + ((px - rec.px) / dt) * 0.6
				vy = rec.vy * 0.4 + ((py - rec.py) / dt) * 0.6
				vz = rec.vz * 0.4 + ((pz - rec.pz) / dt) * 0.6
			else
				vx, vy, vz = rec.vx, rec.vy, rec.vz
			end
			rec.gravity = false
		else
			local v = part.AssemblyLinearVelocity
			vx, vy, vz = v.X, v.Y, v.Z
			if dt > 0.01 then
				rec.accY = rec.accY * 0.7 + ((vy - rec.vy) / dt) * 0.3
				rec.samples += 1
				if rec.samples >= 4 then
					rec.gravity = rec.accY < -0.5 * Workspace.Gravity
				end
			end
		end
		if dt > 0.01 and Config.UseAccel then
			local nax, naz = (vx - rec.vx) / dt, (vz - rec.vz) / dt
			local lim = 6 * math.sqrt(vx * vx + vz * vz) + 40
			if nax * nax + naz * naz > lim * lim then
				nax, naz = 0, 0
			end
			rec.accX = rec.accX * 0.75 + nax * 0.25
			rec.accZ = rec.accZ * 0.75 + naz * 0.25
		end
		rec.vx, rec.vy, rec.vz = vx, vy, vz
		rec.t = now
	else
		local s = part.Size
		local m = math.max(s.X, s.Y, s.Z)
		if dt > 0.004 then
			local gr = (m - rec.s) / dt
			rec.growth = rec.growth * 0.6 + gr * 0.4
			if gr >= Config.AOEGrowthRate then
				local untilT = now + (rec.kind == "AOE" and Config.ZoneLinger or Config.BeamLinger)
				if untilT > rec.activeUntil then
					rec.activeUntil = untilT
				end
			end
			rec.s = m
			rec.t = now
		end
	end
	rec.px, rec.py, rec.pz = px, py, pz
	rec.lastSeen = now
end

local function acceptZone(part, myRoot)
	if part.AssemblyRootPart == myRoot then
		return false
	end
	if Config.IgnoreOtherCharacters then
		local model = part:FindFirstAncestorOfClass("Model")
		if model and model:FindFirstChildOfClass("Humanoid") then
			return false
		end
	end
	return true
end

local function acceptProj(part, m, myRoot)
	if m > Config.MaxThreatSize then
		return false
	end
	if Config.IsThreat then
		local ok, r = pcall(Config.IsThreat, part)
		if ok and r == false then
			return false
		end
	end
	return acceptZone(part, myRoot)
end

local function zoneKind(s, m)
	local a, b, c3 = s.X, s.Y, s.Z
	local mn = math.min(a, b, c3)
	local mid = a + b + c3 - m - mn
	if m / math.max(mid, 0.05) >= Config.BeamAspect and mid <= Config.BeamMaxThickness then
		return "Beam"
	end
	return "AOE"
end

local function tryFresh(part, s, m, now, px, py, pz, myRoot)
	if part.CanCollide or not acceptZone(part, myRoot) then
		return
	end
	local kind = zoneKind(s, m)
	if kind == "Beam" then
		if Config.FreshBeams and m >= 4 then
			watch[part] = nil
			threats[part] = newRecord(part, "Beam", now, px, py, pz, 0, 0, 0, m, 0)
		end
	elseif Config.FreshStaticZones and m >= Config.MinZoneDiameter and m <= Config.MaxZoneRadius * 2 then
		watch[part] = nil
		threats[part] = newRecord(part, "AOE", now, px, py, pz, 0, 0, 0, m, 0)
	end
end

local function scheduleWatch(w)
	if w.n < 4 then
		w.n += 1
		w.next = scanIdx + 1
	else
		stagger = (stagger + 1) % 3
		w.next = scanIdx + 3 + stagger
	end
end

local function observePart(part, w, now, mvx, mvy, mvz, myRoot)
	if part.Anchored then
		local p = part.Position
		local px, py, pz = p.X, p.Y, p.Z
		local s = part.Size
		local m = math.max(s.X, s.Y, s.Z)
		if not w then
			w = { x = px, y = py, z = pz, t = now, s = m, n = 0, next = 0 }
			watch[part] = w
			scheduleWatch(w)
			local born = bornAt[part]
			if born and now - born <= Config.FreshWindow then
				tryFresh(part, s, m, now, px, py, pz, myRoot)
			end
			return
		end
		local dt = now - w.t
		if dt > 0.25 then
			w.x, w.y, w.z, w.t, w.s = px, py, pz, now, m
			w.n = 0
			scheduleWatch(w)
			return
		end
		if dt <= 0.004 then
			return
		end
		local vx, vy, vz = (px - w.x) / dt, (py - w.y) / dt, (pz - w.z) / dt
		local dm = m - w.s
		local growth = dm / dt
		w.x, w.y, w.z, w.t, w.s = px, py, pz, now, m
		local rvx, rvy, rvz = vx - mvx, vy - mvy, vz - mvz
		if rvx * rvx + rvy * rvy + rvz * rvz >= MIN_SP2 then
			if acceptProj(part, m, myRoot) then
				watch[part] = nil
				threats[part] = newRecord(part, "Proj", now, px, py, pz, vx, vy, vz, m, 0)
				return
			end
		elseif growth >= Config.AOEGrowthRate and dm >= Config.AOEMinGrowthStep then
			if acceptZone(part, myRoot) then
				watch[part] = nil
				threats[part] = newRecord(part, zoneKind(s, m), now, px, py, pz, 0, 0, 0, m, growth)
				return
			end
		end
		scheduleWatch(w)
	else
		if w then
			watch[part] = nil
		end
		local v = part.AssemblyLinearVelocity
		local vx, vy, vz = v.X, v.Y, v.Z
		local rvx, rvy, rvz = vx - mvx, vy - mvy, vz - mvz
		if rvx * rvx + rvy * rvy + rvz * rvz >= MIN_SP2 then
			local s = part.Size
			local m = math.max(s.X, s.Y, s.Z)
			if acceptProj(part, m, myRoot) then
				local p = part.Position
				threats[part] = newRecord(part, "Proj", now, p.X, p.Y, p.Z, vx, vy, vz, m, 0)
			end
		end
	end
end

local function prune(now)
	local slowLimit = Config.SlowPruneSeconds
	for part, rec in pairs(threats) do
		if rec.lastSeen < now - 0.2
			or part.Parent == nil
			or now > rec.activeUntil
			or (rec.slowSince > 0 and now - rec.slowSince > slowLimit) then
			threats[part] = nil
			releaseRecord(rec)
		end
	end
end

local function processParts(parts, now, mvx, mvy, mvz, myRoot)
	local terrain = Workspace.Terrain
	for i = 1, #parts do
		local part = parts[i]
		local rec = threats[part]
		if rec then
			updateRecord(rec, now)
		elseif part ~= terrain then
			local w = watch[part]
			if not (w and w.next > scanIdx) then
				observePart(part, w, now, mvx, mvy, mvz, myRoot)
			end
		end
	end
end

local function ScanForThreats(now)
	scanIdx += 1
	local c = ctx
	local hrp = c.hrp
	local hv = hrp.AssemblyLinearVelocity
	local mvx, mvy, mvz = hv.X, hv.Y, hv.Z
	local myRoot = hrp.AssemblyRootPart
	local pos = hrp.Position
	processParts(Workspace:GetPartBoundsInRadius(pos, Config.ScanRadius, c.overlapParams), now, mvx, mvy, mvz, myRoot)
	if Config.BruteForceScan and c.bruteParams and now >= Ctl.nextBrute then
		Ctl.nextBrute = now + 0.3
		processParts(Workspace:GetPartBoundsInRadius(pos, Config.ScanRadius, c.bruteParams), now, mvx, mvy, mvz, myRoot)
	end

	local budget = Config.FreshBudget
	local r2 = Config.FreshRadius * Config.FreshRadius
	for i = #fresh, 1, -1 do
		local part = fresh[i]
		local born = bornAt[part]
		if part.Parent == nil or not born or now - born > 2.5 then
			fresh[i] = fresh[#fresh]
			fresh[#fresh] = nil
		elseif budget > 0 and not threats[part] then
			local pp = part.Position
			local dx, dy, dz = pp.X - pos.X, pp.Y - pos.Y, pp.Z - pos.Z
			if dx * dx + dy * dy + dz * dz <= r2 then
				budget -= 1
				observePart(part, watch[part], now, mvx, mvy, mvz, myRoot)
			end
		end
	end
	for part, rec in pairs(threats) do
		if rec.lastSeen ~= now and rec.tracked and part.Parent ~= nil then
			local born = bornAt[part]
			if born and now - born < 8 then
				updateRecord(rec, now)
			end
		end
	end
	prune(now)
end

local function pushActive(rec)
	rec.urgent = true
	activeN += 1
	active[activeN] = rec
end

local function evalProj(rec, mx, my, mz, mvx, mvy, mvz, pingSec, grav, now)
	local rvx, rvy, rvz = rec.vx - mvx, rec.vy - mvy, rec.vz - mvz
	local sp2 = rvx * rvx + rvy * rvy + rvz * rvz
	if sp2 < MIN_SP2 then
		if rec.slowSince == 0 then
			rec.slowSince = now
		end
		return
	end
	rec.slowSince = 0

	local rx, ry, rz = rec.px - mx, rec.py - my, rec.pz - mz
	if -(rx * rvx + ry * rvy + rz * rvz) <= 0 then
		return
	end
	local reachD = math.sqrt(sp2) * Config.Horizon + rec.hitR
	if rx * rx + ry * ry + rz * rz > reachD * reachD then
		return
	end

	local R = rec.hitR
	local R2 = R * R
	local hh = Config.BodyHalfHeight
	local g = rec.gravity and -grav or 0
	local step = Config.SampleStep
	local horizon = Config.Horizon

	local hitT = nil
	local x0, y0, z0 = rx, ry, rz
	local t0 = 0
	while t0 < horizon do
		local t1 = t0 + step
		local x1 = rx + rvx * t1 + 0.5 * rec.accX * t1 * t1
		local z1 = rz + rvz * t1 + 0.5 * rec.accZ * t1 * t1
		local y1 = ry + rvy * t1 + 0.5 * g * t1 * t1
		local ex, ey, ez = x1 - x0, y1 - y0, z1 - z0
		local l2 = ex * ex + ey * ey + ez * ez
		local u = 0
		if l2 > 1e-9 then
			u = -(x0 * ex + y0 * ey + z0 * ez) / l2
			if u < 0 then
				u = 0
			elseif u > 1 then
				u = 1
			end
		end
		local qx, qy, qz = x0 + ex * u, y0 + ey * u, z0 + ez * u
		local ay = math.abs(qy) - hh
		if ay < 0 then
			ay = 0
		end
		local d2 = qx * qx + qz * qz + ay * ay
		if d2 <= R2 then
			local back = 0
			if l2 > 1e-9 then
				back = math.sqrt(R2 - d2) / (math.sqrt(l2) / step)
			end
			hitT = t0 + u * step - back
			if hitT < 0 then
				hitT = 0
			end
			break
		end
		x0, y0, z0 = x1, y1, z1
		t0 = t1
	end
	if hitT == nil then
		return
	end

	dangerUntil = now + 0.4
	local adj = hitT + Config.PingSign * pingSec
	if adj < 0 or hitT <= 0.001 then
		adj = 0
	end
	rec.baseTti = hitT
	rec.tti = adj

	local hs2 = rvx * rvx + rvz * rvz
	if hs2 >= 4 then
		local hs = math.sqrt(hs2)
		rec.dirx, rec.dirz, rec.hasDir = rvx / hs, rvz / hs, true
	else
		rec.hasDir = false
	end

	local lead = Config.TriggerLead + math.min(Config.FastLeadExtra, math.sqrt(sp2) * Config.FastLeadPerSpeed) + Ctl.caution * 0.15
	if adj <= lead then
		pushActive(rec)
	end
end

local function evalAOE(rec, mx, my, mz, now)
	local part = rec.part
	local s = part.Size
	local sx, sy, sz = s.X, s.Y, s.Z
	local m = math.max(sx, sy, sz)
	local mn = math.min(sx, sy, sz)
	local radius = math.min(m * 0.5, Config.MaxZoneRadius)
	local grow = rec.growth
	if grow < 0 then
		grow = 0
	end
	local radP = radius + grow * 0.5 * Config.ZoneLookahead
	rec.radius = radius
	rec.safeR = radP + Config.BodyRadius + Config.HitMargin
	if mn < 0.35 * m then
		rec.halfY = mn * 0.5 + 1
	else
		rec.halfY = radius
	end
	local dx, dz = mx - rec.px, mz - rec.pz
	local ay = math.abs(my - rec.py) - Config.BodyHalfHeight - rec.halfY
	if ay < 0 then
		ay = 0
	end
	if math.sqrt(dx * dx + dz * dz + ay * ay) > rec.safeR then
		return
	end
	rec.tti, rec.baseTti = 0, 0
	dangerUntil = now + 0.4
	pushActive(rec)
end

local function beamGeometry(rec)
	local part = rec.part
	local s = part.Size
	local cf = part.CFrame
	local axis, len, w
	if s.Z >= s.X and s.Z >= s.Y then
		axis, len, w = cf.LookVector, s.Z, math.max(s.X, s.Y)
	elseif s.X >= s.Y then
		axis, len, w = cf.RightVector, s.X, math.max(s.Y, s.Z)
	else
		axis, len, w = cf.UpVector, s.Y, math.max(s.X, s.Z)
	end
	local ext = rec.growth
	if ext < 0 then
		ext = 0
	end
	local L = len + ext * Config.BeamLookahead
	local c = cf.Position
	local h = L * 0.5
	rec.ox, rec.oy, rec.oz = c.X - axis.X * h, c.Y - axis.Y * h, c.Z - axis.Z * h
	rec.ax, rec.ay, rec.az = axis.X, axis.Y, axis.Z
	rec.blen = L
	rec.lim = w * 0.5 + Config.BodyHalfHeight * 0.9 + Config.HitMargin * 0.5
end

local function evalBeam(rec, mx, my, mz, now)
	beamGeometry(rec)
	local d2 = segDist2(rec.ox, rec.oy, rec.oz, rec.ax, rec.ay, rec.az, rec.blen, mx, my, mz)
	if d2 <= rec.lim * rec.lim then
		rec.tti, rec.baseTti = 0, 0
		dangerUntil = now + 0.4
		pushActive(rec)
	end
end

local function evaluate(now)
	activeN = 0
	local c = ctx
	local p = c.hrp.Position
	local v = c.hrp.AssemblyLinearVelocity
	local mx, my, mz = p.X, p.Y, p.Z
	local mvx, mvy, mvz = v.X, v.Y, v.Z
	local pingSec = pingMs / 1000
	local grav = Workspace.Gravity
	for _, rec in pairs(threats) do
		rec.urgent = false
		if now >= rec.handledUntil then
			local kind = rec.kind
			if kind == "Proj" then
				evalProj(rec, mx, my, mz, mvx, mvy, mvz, pingSec, grav, now)
			elseif kind == "AOE" then
				evalAOE(rec, mx, my, mz, now)
			else
				evalBeam(rec, mx, my, mz, now)
			end
		end
	end
end

local function addCand(x, z, bonus)
	if candN >= MAXC then
		return
	end
	local m = math.sqrt(x * x + z * z)
	if m < 1e-4 then
		return
	end
	candN += 1
	candX[candN] = x / m
	candZ[candN] = z / m
	candBonus[candN] = bonus
	candScore[candN] = 0
	candUsed[candN] = false
end

local function dashDisp(t, D, delay, dur)
	local u = (t - delay) / dur
	if u <= 0 then
		return 0
	end
	if u >= 1 then
		return D
	end
	return D * 1.5 * (u - u * u * u / 3)
end

local function projClearance(rec, cx, cz, D, dur, delay, mx, my, mz, grav)
	local rx, ry, rz = rec.px - mx, rec.py - my, rec.pz - mz
	local vx, vy, vz = rec.vx, rec.vy, rec.vz
	local g = rec.gravity and -grav or 0
	local tEnd = math.min(rec.baseTti + 0.3, Config.Horizon + 0.3)
	local step = Config.SampleStep
	local hh = Config.BodyHalfHeight
	local s0 = dashDisp(0, D, delay, dur)
	local x0 = rx - cx * s0
	local z0 = rz - cz * s0
	local y0 = ry
	local minD2 = math.huge
	local t0 = 0
	while t0 < tEnd do
		local t1 = t0 + step
		local s1 = dashDisp(t1, D, delay, dur)
		local x1 = rx + vx * t1 + 0.5 * rec.accX * t1 * t1 - cx * s1
		local z1 = rz + vz * t1 + 0.5 * rec.accZ * t1 * t1 - cz * s1
		local y1 = ry + vy * t1 + 0.5 * g * t1 * t1
		local ex, ey, ez = x1 - x0, y1 - y0, z1 - z0
		local l2 = ex * ex + ey * ey + ez * ez
		local u = 0
		if l2 > 1e-9 then
			u = -(x0 * ex + y0 * ey + z0 * ez) / l2
			if u < 0 then
				u = 0
			elseif u > 1 then
				u = 1
			end
		end
		local qx, qy, qz = x0 + ex * u, y0 + ey * u, z0 + ez * u
		local ay = math.abs(qy) - hh
		if ay < 0 then
			ay = 0
		end
		local d2 = qx * qx + qz * qz + ay * ay
		if d2 < minD2 then
			minD2 = d2
		end
		x0, y0, z0 = x1, y1, z1
		t0 = t1
	end
	return math.sqrt(minD2) - rec.hitR
end

local function aoeClearance(rec, cx, cz, D, dur, delay, mx, my, mz)
	local s = dashDisp(0.16 + delay, D, delay, dur)
	local dx = mx + cx * s - rec.px
	local dz = mz + cz * s - rec.pz
	local ay = math.abs(my - rec.py) - Config.BodyHalfHeight - rec.halfY
	if ay < 0 then
		ay = 0
	end
	return math.sqrt(dx * dx + dz * dz + ay * ay) - rec.safeR
end

local function beamClearance(rec, cx, cz, D, dur, delay, mx, my, mz)
	local s = dashDisp(0.12 + delay, D, delay, dur)
	local d2 = segDist2(rec.ox, rec.oy, rec.oz, rec.ax, rec.ay, rec.az, rec.blen, mx + cx * s, my, mz + cz * s)
	return math.sqrt(d2) - rec.lim
end

local function validateDir(dx, dz, D)
	local c = ctx
	local origin = c.hrp.Position
	local dir = AXIS_X * dx + AXIS_Z * dz
	local pad = Config.WallPadding
	local free = D
	local reach = dir * (D + pad)
	local hh = Config.BodyHalfHeight

	local r1 = Workspace:Raycast(origin, reach, c.rayParams)
	if r1 then
		free = math.min(free, r1.Distance - pad)
	end
	local r2 = Workspace:Raycast(origin - AXIS_Y * (hh * 0.8), reach, c.rayParams)
	if r2 then
		free = math.min(free, r2.Distance - pad)
	end
	local r3 = Workspace:Raycast(origin + AXIS_Y * (hh * 0.7), reach, c.rayParams)
	if r3 then
		free = math.min(free, r3.Distance - pad)
	end
	if free < Config.DashMinDistance then
		return nil, "wall"
	end

	local down = -AXIS_Y * Config.VoidCheckDepth
	if not Workspace:Raycast(origin + dir * (free * 0.5), down, c.rayParams) then
		return nil, "void"
	end
	if not Workspace:Raycast(origin + dir * free, down, c.rayParams) then
		return nil, "void"
	end
	return free, nil
end

local function tryJumpDodge(now, my)
	if not Config.DodgeJump or not ctx.canJump or now < Ctl.jumpReadyAt then
		return
	end
	local hum = ctx.hum
	if not hum or hum.FloorMaterial == Enum.Material.Air then
		return
	end
	local grav = Workspace.Gravity
	local hh = Config.BodyHalfHeight
	for i = 1, activeN do
		local rec = active[i]
		if rec.kind == "Beam" and math.abs(rec.ay) < 0.35 and rec.oy > my - hh * 2 and rec.oy < my - hh * 0.2 then
			hum:ChangeState(Enum.HumanoidStateType.Jumping)
			Ctl.jumpReadyAt = now + Config.DodgeJumpCooldown
			return
		end
		if rec.kind == "Proj" and rec.baseTti <= 0.38 then
			local t = rec.baseTti
			local g = rec.gravity and -grav or 0
			local yHit = rec.py + rec.vy * t + 0.5 * g * t * t - my
			if yHit < -hh * 0.25 and yHit > -hh * 1.4 then
				hum:ChangeState(Enum.HumanoidStateType.Jumping)
				Ctl.jumpReadyAt = now + Config.DodgeJumpCooldown
				return
			end
		end
	end
end

local function decide(now)
	local c = ctx
	local p = c.hrp.Position
	local mx, my, mz = p.X, p.Y, p.Z
	local delay = pingMs / 2000
	local grav = Workspace.Gravity
	local look = c.hrp.CFrame.LookVector
	local hh = Config.BodyHalfHeight
	local D = Config.DashEnabled and Config.DashDistance or ((ctx.baseWS + Config.SpeedBonusMax) * 0.5)
	local urgentMin = math.huge
	tryJumpDodge(now, my)

	candN = 0
	for i = 1, 16 do
		addCand(baseCos[i], baseSin[i], 0)
	end

	for i = 1, activeN do
		local rec = active[i]
		local kind = rec.kind
		if rec.tti < urgentMin then
			urgentMin = rec.tti
		end
		if kind == "Proj" then
			if rec.hasDir then

				local sx, sz = -rec.dirz, rec.dirx
				local lat = (mx - rec.px) * sx + (mz - rec.pz) * sz
				local pref = lat >= 0 and 1 or -1
				addCand(sx * pref, sz * pref, -0.9)
				addCand(-sx * pref, -sz * pref, -0.6)
			else
				addCand(mx - rec.px, mz - rec.pz, -0.9)
			end
		elseif kind == "AOE" then

			local ax, az = mx - rec.px, mz - rec.pz
			local hd2 = ax * ax + az * az
			local ay = math.abs(my - rec.py) - hh - rec.halfY
			if ay < 0 then
				ay = 0
			end
			local dist = math.sqrt(hd2 + ay * ay)
			if hd2 < 0.09 then
				ax, az = -look.X, -look.Z
			end
			addCand(ax, az, -2.5)
			local need = rec.safeR - dist + 1.5
			if need > D then
				D = math.min(need, Config.DashMaxDistance)
			end
		else

			local rx, ry, rz = mx - rec.ox, my - rec.oy, mz - rec.oz
			local t = rx * rec.ax + ry * rec.ay + rz * rec.az
			if t < 0 then
				t = 0
			elseif t > rec.blen then
				t = rec.blen
			end
			local qx, qy, qz = rx - rec.ax * t, ry - rec.ay * t, rz - rec.az * t
			local dist = math.sqrt(qx * qx + qy * qy + qz * qz)
			local hs2 = rec.ax * rec.ax + rec.az * rec.az
			if hs2 >= 0.01 then
				local hs = math.sqrt(hs2)
				local ux, uz = rec.ax / hs, rec.az / hs
				local sx, sz = -uz, ux
				local pref = (qx * sx + qz * sz) >= 0 and 1 or -1
				addCand(sx * pref, sz * pref, -2.0)
				addCand(-sx * pref, -sz * pref, -0.6)
			else
				addCand(qx, qz, -2.0)
				addCand(-look.X, -look.Z, -0.5)
			end
			local need = rec.lim - dist + 1.5
			if need > D then
				D = math.min(need, Config.DashMaxDistance)
			end
		end
	end

	local moveReach = (ctx.baseWS + Config.SpeedBonusMax) * 0.5
	if not Config.DashEnabled and D > moveReach then
		D = moveReach
	end
	local dur = Config.DashEnabled and math.max(Config.DashDuration, D / Config.DashAvgSpeed) or 0.5
	local repeatActive = now - c.lastDirTime < 1.6
	for i = 1, candN do
		local cx, cz = candX[i], candZ[i]
		local sc = candBonus[i]
		if repeatActive and cx * c.lastDirX + cz * c.lastDirZ > 0.7 then
			sc += 0.35
		end
		for k = 1, activeN do
			local rec = active[k]
			local kind = rec.kind
			local clearance, R
			if kind == "Proj" then
				clearance = projClearance(rec, cx, cz, D, dur, delay, mx, my, mz, grav)
				R = rec.hitR
			elseif kind == "AOE" then
				clearance = aoeClearance(rec, cx, cz, D, dur, delay, mx, my, mz)
				R = rec.safeR
			else
				clearance = beamClearance(rec, cx, cz, D, dur, delay, mx, my, mz)
				R = rec.lim
			end
			local urgency = math.min(6, 1.5 / (0.25 + rec.tti))
			if clearance < 0 then
				sc += math.min(1, -clearance / R) * urgency
			else
				sc -= math.min(0.4, clearance / R * 0.2)
			end
		end
		candScore[i] = sc
	end

	if Config.UseCover then
		local src = nil
		for k = 1, activeN do
			if active[k].kind == "Proj" then
				src = active[k]
				break
			end
		end
		if src then
			local origin = Vector3.new(src.px, src.py, src.pz)
			local cstep = math.min(D, Config.CoverStep)
			for i = 1, candN do
				local pt = Vector3.new(mx + candX[i] * cstep, my, mz + candZ[i] * cstep)
				local hit = Workspace:Raycast(origin, pt - origin, c.rayParams)
				if hit then
					candScore[i] -= Config.CoverWeight
				end
			end
		end
	end

	local chosen, chosenDist = 0, 0
	for _ = 1, 20 do
		local bi, bs = 0, math.huge
		for i = 1, candN do
			if not candUsed[i] and candScore[i] < bs then
				bi, bs = i, candScore[i]
			end
		end
		if bi == 0 then
			break
		end
		candUsed[bi] = true
		local d = validateDir(candX[bi], candZ[bi], D)
		if d then
			chosen, chosenDist = bi, d
			break
		end
		local fx, fz = candX[bi], candZ[bi]
		for j = 1, candN do
			if not candUsed[j] and candX[j] * fx + candZ[j] * fz <= -0.7 then
				candScore[j] -= 2
			end
		end
	end

	if chosen == 0 then
		for i = 1, activeN do
			active[i].handledUntil = now + 0.3
		end
		return
	end

	if (Config.WalkDodge and urgentMin >= Config.WalkDodgeTTI) or not Config.DashEnabled then

		local onlyProj = true
		for i = 1, activeN do
			if active[i].kind ~= "Proj" then
				onlyProj = false
			end
		end
		local pat = onlyProj and pickPattern(urgentMin, false, false) or PAT_LINE
		local dur = urgentMin + 0.25
		if pat == PAT_ARC then
			dur = math.max(dur, 0.85)
		elseif pat == PAT_ZIGZAG then
			dur = math.max(dur, 0.7)
		end
		startManeuver(now, candX[chosen], candZ[chosen], MV_DODGE, dur, pat)
		if not Config.DashEnabled then
			c.cooldownEnd = now + Config.MoveDodgeCooldown
			c.lastDirX, c.lastDirZ, c.lastDirTime = candX[chosen], candZ[chosen], now
			Ctl.pendingDodgeAt = 0
			if Config.OnDodge then
				pcall(Config.OnDodge, AXIS_X * candX[chosen] + AXIS_Z * candZ[chosen], chosenDist)
			end
		end
		for i = 1, activeN do
			active[i].handledUntil = now + (pat == PAT_LINE and 0.14 or 0.35)
		end
		return
	end

	for i = 1, activeN do
		active[i].handledUntil = now + 0.6
	end
	startDash(now, candX[chosen], candZ[chosen], chosenDist)
end

local function step(now)
	local c = ctx
	if c.dashing or now < c.settleUntil then
		return
	end
	ScanForThreats(now)
	evaluate(now)
	if activeN == 0 then
		Ctl.pendingDodgeAt = 0
		return
	end
	dangerUntil = now + 0.4
	if now + 0.6 > Ctl.threatUntil then
		Ctl.threatUntil = now + 0.6
	end
	if now < c.cooldownEnd then
		return
	end

	if now >= Ctl.noDelayUntil then
		if Ctl.pendingDodgeAt == 0 then
			local minT = 1
			for i = 1, activeN do
				if active[i].tti < minT then
					minT = active[i].tti
				end
			end
			Ctl.pendingDodgeAt = now + reactDelay(minT)
		end
		if now < Ctl.pendingDodgeAt then
			return
		end
		Ctl.pendingDodgeAt = 0
		Ctl.noDelayUntil = now + 0.7
	end
	local reason = guardReason()
	if reason then
		cachedReason = reason
		return
	end
	decide(now)
end

local function enemyAllowed(model, plr)
	if Config.IsEnemy then
		local ok, r = pcall(Config.IsEnemy, model, plr)
		if ok then
			return r and true or false
		end
	end
	if plr then
		if plr == LocalPlayer then
			return false
		end
		if not Config.IncludeTeammates and LocalPlayer.Team ~= nil and plr.Team == LocalPlayer.Team then
			return false
		end
	end
	return true
end

local function addEnemy(model, plr)
	local hum = model:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		return
	end
	local root = hum.RootPart
	if not root then
		return
	end
	local e = enemyMap[model]
	if not e then
		e = {
			model = model, hum = hum, root = root, plr = plr, animator = nil,
			dist = 1e9, px = 0, pz = 0, vx = 0, vz = 0, lx = 0, lz = 1, ox = 0, oz = 1,
			face = 0, closing = 0,
			attackActive = false, lastAttackStart = -10, attackLen = 0, interval = 0,
			counterUntil = 0, counterFired = true, nextPoll = 0, dodgedAt = -99, seen = 0, hitFrac = Config.AttackHitFrac, reach = Config.EnemyAttackRange, reachAt = 0,
			limbs = {}, limbN = 0, limbListAt = 0, limbT = 0, limbHasPrev = false, lpx = {}, lpy = {}, lpz = {},
			swing = false, swingTti = 1, swingId = 0, dodgedSwing = -1, lastDodgeAt = -9,
		}
		enemyMap[model] = e
	end
	e.hum, e.root = hum, root
	e.seen = epoch
	enemyN += 1
	enemyList[enemyN] = e
end

local function refreshEnemies()
	epoch += 1
	enemyN = 0
	local me = ctx.char
	for _, plr in ipairs(Players:GetPlayers()) do
		local ch = plr.Character
		if ch and ch ~= me and enemyAllowed(ch, plr) then
			addEnemy(ch, plr)
		end
	end
	local folder = Config.NpcFolder
	if folder then
		for _, m in ipairs(folder:GetChildren()) do
			if m:IsA("Model") and m ~= me and enemyAllowed(m, nil) then
				addEnemy(m, nil)
			end
		end
	end
	if Config.AutoDetectNpcs and ctx.overlapParams and ctx.hrp then
		local parts = Workspace:GetPartBoundsInRadius(ctx.hrp.Position, math.max(Config.ConflictRange, Config.EscapeRange * 1.35) + 10, ctx.overlapParams)
		for i = 1, #parts do
			local model = parts[i]:FindFirstAncestorOfClass("Model")
			if model and model ~= me then
				local known = enemyMap[model]
				if not (known and known.seen == epoch) and Players:GetPlayerFromCharacter(model) == nil and enemyAllowed(model, nil) then
					addEnemy(model, nil)
				end
			end
		end
	end
	for model, e in pairs(enemyMap) do
		if e.seen ~= epoch then
			enemyMap[model] = nil
		end
	end
	for i = enemyN + 1, #enemyList do
		enemyList[i] = nil
	end
end

local function pollEnemyAttack(e, now)
	if now < e.nextPoll then
		return
	end
	e.nextPoll = now + 0.1
	local animator = e.animator
	if not animator or animator.Parent == nil then
		animator = e.hum:FindFirstChildOfClass("Animator")
		e.animator = animator
		if not animator then
			return
		end
	end
	local tracks = animator:GetPlayingAnimationTracks()
	local attackingNow = false
	for i = 1, #tracks do
		local tr = tracks[i]
		local pv = tr.Priority.Value
		if pv >= 2 and pv <= 5 and not tr.Looped and tr.Length > 0.15 then
			attackingNow = true
			if not seenTracks[tr] then
				seenTracks[tr] = true
				if e.lastAttackStart > 0 then
					local iv = now - e.lastAttackStart
					if iv > 0.2 and iv < 4 then
						e.interval = (e.interval > 0) and (e.interval * 0.6 + iv * 0.4) or iv
					end
				end
				e.lastAttackStart = now - tr.TimePosition
				e.attackLen = tr.Length / math.max(tr.Speed, 0.1)
				e.attackActive = true
			end
		end
	end
	if not attackingNow and e.attackActive then
		e.attackActive = false
		e.counterUntil = now + Config.CounterWindow
		e.counterFired = false
	end
end

local function trackLimbs(e, now, mx, my, mz)
	if now >= e.limbListAt then
		e.limbListAt = now + 2
		local list = e.limbs
		local n = 0
		for _, d in ipairs(e.model:GetDescendants()) do
			if n < 40 and d:IsA("BasePart") and d ~= e.root then
				n += 1
				list[n] = d
			end
		end
		for i = n + 1, #list do
			list[i] = nil
		end
		e.limbN = n
		e.limbHasPrev = false
	end
	local dt = now - e.limbT
	local best = 1e9
	local minSp = Config.LimbMinSpeed
	local minSp2 = minSp * minSp
	local rv = e.root.AssemblyLinearVelocity
	for i = 1, e.limbN do
		local part = e.limbs[i]
		local p = part.Position
		local px, py, pz = p.X, p.Y, p.Z
		if e.limbHasPrev and dt > 0.004 and dt < 0.25 then
			local vx = (px - e.lpx[i]) / dt
			local vy = (py - e.lpy[i]) / dt
			local vz = (pz - e.lpz[i]) / dt
			local ox, oy, oz = vx - rv.X, vy - rv.Y, vz - rv.Z
			if ox * ox + oy * oy + oz * oz >= minSp2 then
				local rx, ry, rz = mx - px, my - py, mz - pz
				local sp2 = vx * vx + vy * vy + vz * vz
				if sp2 > 1 then
					local closing = rx * vx + ry * vy + rz * vz
					if closing > 0 then
						local d2 = rx * rx + ry * ry + rz * rz - closing * closing / sp2
						local sz = part.Size
						local R = Config.BodyRadius + Config.HitMargin + math.min(2, math.max(sz.X, sz.Y, sz.Z) * 0.5)
						if d2 <= R * R then
							local th = closing / sp2 - math.sqrt(math.max(0, R * R - d2) / sp2)
							if th < 0 then
								th = 0
							end
							if th < best then
								best = th
							end
						end
					end
				end
			end
		end
		e.lpx[i], e.lpy[i], e.lpz[i] = px, py, pz
	end
	e.limbT = now
	e.limbHasPrev = true
	local swinging = best < 0.5
	if swinging and not e.swing then
		e.swingId += 1
	elseif swinging and e.dodgedSwing == e.swingId and now - e.lastDodgeAt > 0.55 then
		e.swingId += 1
	end
	e.swing = swinging
	e.swingTti = best
end

local function updateEnemies(now, mx, mz)
	local my = ctx.hrp.Position.Y
	local polled = 0
	local far = math.max(Config.ConflictRange + 4, Config.RangedRange)
	for i = 1, enemyN do
		local e = enemyList[i]
		local root = e.root
		if root.Parent == nil or e.hum.Health <= 0 then
			e.dist = 1e9
			e.attackActive = false
		else
			if now >= e.reachAt then
				e.reachAt = now + 3
				local okr, esz = pcall(function()
					return e.model:GetExtentsSize()
				end)
				if okr and typeof(esz) == "Vector3" then
					e.reach = math.clamp(esz.Y * 1.7, 5, 30)
				end
			end
			local p = root.Position
			local v = root.AssemblyLinearVelocity
			local look = root.CFrame.LookVector
			e.px, e.pz = p.X, p.Z
			e.vx, e.vz = v.X, v.Z
			local lh = math.sqrt(look.X * look.X + look.Z * look.Z)
			if lh > 1e-3 then
				e.lx, e.lz = look.X / lh, look.Z / lh
			end
			local dx, dz = mx - e.px, mz - e.pz
			local d = math.sqrt(dx * dx + dz * dz)
			if d < 0.05 then
				d = 0.05
			end
			e.dist = d
			e.ox, e.oz = dx / d, dz / d
			e.face = e.lx * e.ox + e.lz * e.oz
			e.closing = e.vx * e.ox + e.vz * e.oz
			if Config.LimbTracking and d <= e.reach * 2.5 + 10 then
				trackLimbs(e, now, mx, my, mz)
			else
				e.swing = false
				e.limbHasPrev = false
			end
			if d <= far then
				if polled < 8 and (d <= Config.ConflictRange + 4 or e.face > 0.5) then
					polled += 1
					pollEnemyAttack(e, now)
				elseif d > Config.ConflictRange + 4 then
					e.attackActive = false
				end
			else
				e.attackActive = false
			end
		end
	end
end

local function pickTarget()
	local rangeLimit = (Config.Mode == "Escape") and Ctl.escRange or Config.ConflictRange
	local best, bd = nil, rangeLimit
	for i = 1, enemyN do
		local e = enemyList[i]
		if e.dist < bd then
			best, bd = e, e.dist
		end
	end
	local cur = target
	if cur and cur.seen == epoch and cur.dist <= rangeLimit and best and best ~= cur then
		if best.dist > cur.dist * 0.8 then
			best = cur
		end
	end
	target = best
	return best
end

local function castSurroundings()
	local c = ctx
	local origin = c.hrp.Position
	local down = -AXIS_Y * Config.VoidCheckDepth
	local params = c.rayParams
	castTick += 1
	for i = 1, N_DIR do
		local cx, cz = baseCos[i], baseSin[i]
		local dir = AXIS_X * cx + AXIS_Z * cz
		local r = Workspace:Raycast(origin, dir * RAY_LEN, params)
		local clear = 1
		rayNx[i], rayNz[i] = 0, 0
		if r then
			clear = r.Distance / RAY_LEN
			local n = r.Normal
			local nh = math.sqrt(n.X * n.X + n.Z * n.Z)
			if nh > 0.2 then
				rayNx[i], rayNz[i] = n.X / nh, n.Z / nh
			end
		end
		rayClear[i] = clear
		rayVoid[i] = false

		if clear * RAY_LEN > RAY_LEN * 0.69 then
			if not Workspace:Raycast(origin + dir * (RAY_LEN * 0.62), down, params) then
				rayVoid[i] = true
			end
		end

		if (i + castTick) % 2 == 0 then
			local rf = Workspace:Raycast(origin, dir * RAY_FAR, params)
			rayFar[i] = rf and (rf.Distance / RAY_FAR) or 1
		end
	end
end

local function contextSteer(wx, wz)
	local wm = math.sqrt(wx * wx + wz * wz)
	if wm < 1e-4 then
		return 0, 0
	end
	wx, wz = wx / wm, wz / wm
	local sx, sz = 0, 0
	local bestClear, bestI = -1, 1
	local orbit = Ctl.orbitDir
	for i = 1, N_DIR do
		local cx, cz = baseCos[i], baseSin[i]
		local clear = rayClear[i]
		local danger = 0
		if rayVoid[i] then
			clear = 0
			danger = 1
		elseif clear < 0.75 then
			danger = (0.75 - clear) / 0.75
		end
		if clear > bestClear then
			bestClear, bestI = clear, i
		end
		local align = cx * wx + cz * wz
		local cross = wx * cz - wz * cx

		local score = align - danger * 1.6 + 0.15 * orbit * cross * (danger > 0 and 1 or 0)
		if align > -0.2 then
			score += Config.CoverWeight * rayCover[i]
		end
		if align > 0 then
			score += Config.OpenSpaceWeight * (rayFar[i] - 0.6)
		end
		if score > 0 then
			sx += cx * score
			sz += cz * score
		end
	end
	local sm = math.sqrt(sx * sx + sz * sz)
	if sm < 0.05 then
		return baseCos[bestI], baseSin[bestI]
	end
	sx, sz = sx / sm, sz / sm

	local fs = slotOf(sx, sz)
	local fc = rayVoid[fs] and 0 or rayClear[fs]
	if fc < 0.6 and (rayNx[fs] ~= 0 or rayNz[fs] ~= 0) then
		local nx, nz = rayNx[fs], rayNz[fs]
		local d = sx * nx + sz * nz
		if d < 0 then
			sx = sx - nx * d + nx * 0.12
			sz = sz - nz * d + nz * 0.12
			local m2 = math.sqrt(sx * sx + sz * sz)
			if m2 > 1e-3 then
				sx, sz = sx / m2, sz / m2
			end
		end
	end
	return sx, sz
end

local function computeCover(srcx, srcy, srcz, model)
	local c = ctx
	local p = c.hrp.Position
	local params = c.rayParams
	local dx, dz = srcx - p.X, srcz - p.Z
	local dm = math.sqrt(dx * dx + dz * dz)
	if dm < 1 then
		for i = 1, N_DIR do
			rayCover[i] = 0
		end
		return
	end

	local origin = Vector3.new(srcx - dx / dm * 2.5, srcy + 1, srcz - dz / dm * 2.5)
	local step = Config.CoverStep
	for i = 1, N_DIR do
		rayCover[i] = 0
		local clear = rayVoid[i] and 0 or rayClear[i]
		if clear >= 0.95 then
			local target = Vector3.new(p.X + baseCos[i] * step, srcy + 1, p.Z + baseSin[i] * step)
			local hit = Workspace:Raycast(origin, target - origin, params)
			if hit and not (model and hit.Instance:IsDescendantOf(model)) then
				rayCover[i] = 1
			end
		end
	end
end

local function stuckCheck(now, mx, mz)
	if now - Ctl.stuckT < 0.4 then
		return
	end
	local dx, dz = mx - Ctl.stuckX, mz - Ctl.stuckZ
	local moved = math.sqrt(dx * dx + dz * dz)
	Ctl.stuckT, Ctl.stuckX, Ctl.stuckZ = now, mx, mz
	if Ctl.speed > 0.55 and moved < 0.9 and not ctx.dashing and now > Ctl.unstickUntil then

		local hx, hz = math.cos(Ctl.heading), math.sin(Ctl.heading)
		local bestI, bestS = 1, -9
		for i = 1, N_DIR do
			local clear = rayVoid[i] and 0 or rayClear[i]
			local s = clear - 0.6 * math.max(0, baseCos[i] * hx + baseSin[i] * hz)
			if s > bestS then
				bestS, bestI = s, i
			end
		end
		Ctl.unstickX, Ctl.unstickZ = baseCos[bestI], baseSin[bestI]
		Ctl.unstickUntil = now + 0.5
		Ctl.orbitDir = -Ctl.orbitDir
		Ctl.feintPhase = 0
		Ctl.flankUntil = 0
	end
end

local function humanScale(now)
	if now >= Ctl.nextStutterAt then
		Ctl.nextStutterAt = now + rng:NextNumber(0.35, 1.2)
		if rng:NextNumber() < 0.55 then
			Ctl.stutterUntil = now + rng:NextNumber(0.07, 0.16)
			Ctl.stutterScale = rng:NextNumber(0.2, 0.55)
		else
			Ctl.stutterUntil = now + rng:NextNumber(0.1, 0.22)
			Ctl.stutterScale = 1
		end
	end
	local s = 1
	if now < Ctl.stutterUntil then
		s = Ctl.stutterScale
	end
	local n = math.noise(now * 1.7, Ctl.noiseSeed)
	local k = 0.88 + 0.2 * n
	if k > 1 then
		k = 1
	end
	return s * k
end

local function flankSideFor(e)

	local cross = e.lx * e.oz - e.lz * e.ox
	return cross > 0 and -1 or 1
end

local function flankMove(e, mx, mz, ux, uz, tx, tz, dist, side)
	local bx = e.px - e.lx * Config.OptimalMin * 0.9
	local bz = e.pz - e.lz * Config.OptimalMin * 0.9
	local gx, gz = bx - mx, bz - mz
	local gl = math.sqrt(gx * gx + gz * gz)
	if gl < 1e-3 then
		return 0, 0
	end
	local k = math.min(1, gl / 10)
	local wx = gx / gl * 0.8 + tx * side * 0.6 * k
	local wz = gz / gl * 0.8 + tz * side * 0.6 * k
	if dist < Config.OptimalMin - 1 then
		wx -= ux * 0.8
		wz -= uz * 0.8
	end
	return wx, wz
end

local function tactics(now, dt, mx, mz, e)
	local dist = e.dist
	local ux, uz = -e.ox, -e.oz
	local tx, tz = -uz, ux
	local opt0, opt1 = Config.OptimalMin, Config.OptimalMax
	local turnN, turnE = Config.TurnRateNormal, Config.TurnRateEmergency

	if Ctl.feintPhase == 1 then
		if now < Ctl.feintUntil then
			return tx * Ctl.feintSide * 0.95 + ux * 0.2, tz * Ctl.feintSide * 0.95 + uz * 0.2, 1, turnN
		end
		Ctl.feintPhase = 2
		Ctl.feintUntil = now + rng:NextNumber(0.25, 0.42)
		Ctl.orbitDir = -Ctl.feintSide
	end
	if Ctl.feintPhase == 2 then
		if now < Ctl.feintUntil then
			return tx * Ctl.orbitDir * 0.9 + ux * 0.55, tz * Ctl.orbitDir * 0.9 + uz * 0.55, 1, turnE
		end
		Ctl.feintPhase = 0
		Ctl.feintCooldown = now + rng:NextNumber(2.2, 4.5)
	end
	if Ctl.feintPhase == 0 and now >= Ctl.feintCooldown and not e.attackActive and e.face > 0.3
		and dist >= opt0 - 1 and dist <= opt1 + 6 then

		local chance = Config.FeintChancePerSec * dt * (1 + math.max(0, e.closing) / 8)
		if rng:NextNumber() < chance then
			Ctl.feintPhase = 1
			Ctl.feintUntil = now + rng:NextNumber(0.12, 0.2)
			Ctl.feintSide = rng:NextNumber() < 0.5 and 1 or -1
		end
	end

	if now < e.counterUntil then
		if not e.counterFired and dist <= Config.EnemyAttackRange + 3 then
			e.counterFired = true
			if Config.OnCounterWindow then
				pcall(Config.OnCounterWindow, e.model)
			end
		end
		local wx, wz = flankMove(e, mx, mz, ux, uz, tx, tz, dist, flankSideFor(e))
		return wx, wz, 1, turnN
	end

	if now < Ctl.flankUntil then
		if (e.face < -0.35 and dist <= opt0 + 3) or e.attackActive then
			Ctl.flankUntil = 0
		else
			local wx, wz = flankMove(e, mx, mz, ux, uz, tx, tz, dist, Ctl.flankSide)
			return wx, wz, 1, turnN
		end
	elseif Config.FlankEnabled and now >= Ctl.nextFlankAt and not e.attackActive
		and dist >= opt0 - 2 and dist <= opt1 + 4 then
		local chance = (e.face < 0.2) and 1.2 or 0.22
		if rng:NextNumber() < chance * dt then
			Ctl.flankSide = flankSideFor(e)
			Ctl.flankUntil = now + rng:NextNumber(1.6, 2.6)
			Ctl.nextFlankAt = now + rng:NextNumber(5, 9)
		end
	end

	if now >= Ctl.nextFlipAt then
		Ctl.nextFlipAt = now + rng:NextNumber(0.7, 2.1)
		Ctl.orbitDir = -Ctl.orbitDir
		Ctl.stutterUntil = now + 0.09
		Ctl.stutterScale = 0.3
	end
	local rad = 0
	if dist > opt1 then
		rad = math.min(1, (dist - opt1) / 6)
	elseif dist < opt0 then
		rad = -math.min(1, (opt0 - dist) / 4)
	else
		rad = 0.25 * math.noise(now * 0.9, Ctl.noiseSeed + 11)
	end

	if e.interval > 0 and not e.attackActive and now > e.lastAttackStart + e.interval - 0.3
		and dist < Config.EnemyAttackRange + 4 then
		rad = math.min(rad, -0.8)
	end
	local tan = 0.65 + 0.35 * (math.noise(now * 0.6, Ctl.noiseSeed + 23) + 0.5)
	local wx = ux * rad + tx * Ctl.orbitDir * tan
	local wz = uz * rad + tz * Ctl.orbitDir * tan
	return wx, wz, humanScale(now), turnN
end

local function escapeTactics(now, mx, mz)
	local fx, fz = 0, 0
	local near, ne = 1e9, nil
	for i = 1, enemyN do
		local e = enemyList[i]
		if e.dist <= Ctl.escRange then
			local w = (Ctl.escRange - e.dist) / Ctl.escRange
			w = w * w * (1 + math.max(0, e.closing) / 12)
			if e.attackActive then
				w *= 1.6
			end
			local qx, qz = mx - (e.px + e.vx * 0.35), mz - (e.pz + e.vz * 0.35)
			local qm = math.sqrt(qx * qx + qz * qz)
			if qm > 0.1 then
				fx += qx / qm * w
				fz += qz / qm * w
			else
				fx += e.ox * w
				fz += e.oz * w
			end
			if e.dist < near then
				near, ne = e.dist, e
			end
		end
	end
	if not ne then
		return 0, 0, 0, Config.TurnRateNormal
	end
	local fm = math.sqrt(fx * fx + fz * fz)
	if fm < 1e-4 then
		fx, fz = ne.ox, ne.oz
	else
		fx, fz = fx / fm, fz / fm
	end

	local goal = Config.EscapeGoal
	if goal then
		local ok, g = pcall(goal)
		if ok and typeof(g) == "Vector3" then
			local gx, gz = g.X - mx, g.Z - mz
			local gm = math.sqrt(gx * gx + gz * gz)
			if gm > 1 and (gx / gm) * fx + (gz / gm) * fz > -0.3 then
				fx += gx / gm * 0.7
				fz += gz / gm * 0.7
			end
		end
	end

	local tx, tz = -fz, fx
	fx += tx * Ctl.orbitDir * 0.25
	fz += tz * Ctl.orbitDir * 0.25

	local c = ctx
	if near < Config.EscapeDashRange and now >= c.cooldownEnd and not c.dashing then
		local free = validateDir(ne.ox, ne.oz, Config.DashDistance)
		if free then
			startDash(now, ne.ox, ne.oz, free)
		end
	end

	if Config.WallLoop then
		local bi, bc = 0, 0.65
		for i = 1, N_DIR do
			if rayClear[i] < bc and (rayNx[i] ~= 0 or rayNz[i] ~= 0) then
				bi, bc = i, rayClear[i]
			end
		end
		if bi > 0 then
			local wnx, wnz = rayNx[bi], rayNz[bi]
			local wtx, wtz = -wnz, wnx
			if wtx * fx + wtz * fz < 0 then
				wtx, wtz = -wtx, -wtz
			end
			local k = Config.WallLoopWeight * (1 - bc / 0.65)
			fx += wtx * k
			fz += wtz * k
		end
	end

	if Config.EscapeZigzag then
		local prox = 1 - math.min(1, near / Ctl.escRange)
		local za = math.rad(Config.EscapeZigzagAngle) * prox * math.sin(TAU * now / Config.EscapePeriod + Ctl.noiseSeed)
		local zc, zs = math.cos(za), math.sin(za)
		fx, fz = fx * zc - fz * zs, fx * zs + fz * zc
	end

	if Config.EscapeJuke and now >= Ctl.jukeAt and not ne.attackActive and ne.closing > 2
		and near >= ne.reach * 1.5 and near <= ne.reach * 2.6
		and rng:NextNumber() < 0.04 then
		Ctl.jukeAt = now + rng:NextNumber(3, 6)
		startManeuver(now, ne.ox, ne.oz, MV_DODGE, 0.75, PAT_INOUT, ne.px, ne.pz)
	end

	local spd = 1
	if near >= Ctl.escRange * 0.7 then
		spd = math.max(0.85, humanScale(now))
	end
	return fx, fz, spd, Config.TurnRateEmergency
end

local function meleeEvade(now, mx, mz, e, remaining)
	local sx, sz = -e.lz, e.lx
	local lat = (mx - e.px) * sx + (mz - e.pz) * sz
	local pref = lat >= 0 and 1 or -1
	if rng:NextNumber() < Config.EvadeSideRandom then
		pref = -pref
	end
	local ax, az = sx * pref * 0.9 + e.ox * 0.5, sz * pref * 0.9 + e.oz * 0.5
	local bx, bz = -sx * pref * 0.9 + e.ox * 0.5, -sz * pref * 0.9 + e.oz * 0.5
	local am = math.sqrt(ax * ax + az * az)
	local bm = math.sqrt(bx * bx + bz * bz)
	ax, az, bx, bz = ax / am, az / am, bx / bm, bz / bm
	local ia, ib = slotOf(ax, az), slotOf(bx, bz)
	local ca = rayVoid[ia] and 0 or rayClear[ia]
	local cb = rayVoid[ib] and 0 or rayClear[ib]
	if Config.UseCover and e.root and e.root.Parent then

		local rp = e.root.Position
		local origin = Vector3.new(rp.X + e.ox * 2.5, rp.Y + 1, rp.Z + e.oz * 2.5)
		local ha = Workspace:Raycast(origin, Vector3.new(mx + ax * Config.CoverStep, rp.Y + 1, mz + az * Config.CoverStep) - origin, ctx.rayParams)
		local hb = Workspace:Raycast(origin, Vector3.new(mx + bx * Config.CoverStep, rp.Y + 1, mz + bz * Config.CoverStep) - origin, ctx.rayParams)
		if ha and not ha.Instance:IsDescendantOf(e.model) then
			ca += 0.3
		end
		if hb and not hb.Instance:IsDescendantOf(e.model) then
			cb += 0.3
		end
	end
	local dx, dz, best = ax, az, ca
	if cb > ca then
		dx, dz, best = bx, bz, cb
	end
	if best < 0.45 then
		dx, dz = e.ox, e.oz
	end
	local pat = pickPattern(remaining, true, true)
	local mdur = 0.4
	if pat == PAT_ZIGZAG then
		mdur = 0.7
	elseif pat == PAT_ORBIT then
		mdur = 0.8
	end
	startManeuver(now, dx, dz, MV_MELEE, mdur, pat, e.px, e.pz)
	if pat == PAT_ORBIT then
		Ctl.mvSpin = (dx * -e.oz + dz * e.ox >= 0) and 1 or -1
	end
	local c = ctx
	if remaining <= Config.MeleeDashLead and now >= c.cooldownEnd and not c.dashing then
		local free = validateDir(dx, dz, Config.MeleeDashDistance)
		if free then
			startDash(now, dx, dz, free)
		end
	end
end

local function predDist(e, t)
	local dx = e.ox * e.dist - e.vx * t
	local dz = e.oz * e.dist - e.vz * t
	return math.min(e.dist, math.sqrt(dx * dx + dz * dz))
end

local function onDamaged(now)
	Ctl.caution = math.min(1, Ctl.caution + 0.35)
	Ctl.hits += 1
	if Config.LogHits then
		local ne, nd = nil, 1e9
		for i = 1, enemyN do
			local en = enemyList[i]
			if en.dist < nd then
				ne, nd = en, en.dist
			end
		end
		local info = string.format(
			"dist=%.1f atk=%s swing=%s swingTti=%.2f threats=%d active=%s mv=%s sinceMv=%.2f reason=%s ping=%d mode=%s",
			ne and nd or -1, tostring(ne and ne.attackActive), tostring(ne and ne.swing), ne and ne.swingTti or -1,
			activeN, tostring(Ctl.active), tostring(Ctl.mvActive), now - Ctl.mvStart, tostring(cachedReason), math.floor(pingMs), Config.Mode
		)
		LocalPlayer:SetAttribute("AutoEvasionLastHit", info)
		print("[AutoEvasion] HIT " .. info)
		hitLog[#hitLog + 1] = string.format("%.1f %s", now, info)
		if #hitLog > 10 then
			table.remove(hitLog, 1)
		end
	end
	local best, bd = nil, Config.EnemyAttackRange + 6
	for i = 1, enemyN do
		local e = enemyList[i]
		if e.attackActive and e.dist < bd then
			best, bd = e, e.dist
		end
	end
	if best and best.attackLen > 0.1 then
		local frac = (now - best.lastAttackStart) / best.attackLen
		best.hitFrac = best.hitFrac * 0.6 + math.clamp(frac, 0.1, 0.9) * 0.4
	end
end

local function checkMelee(now, mx, mz)
	for i = 1, enemyN do
		local e = enemyList[i]
		if e.swing and e.dodgedSwing ~= e.swingId and e.swingTti <= Config.MeleeReactWindow + Ctl.caution * 0.25 then
			if Ctl.meleeReactAt == 0 or Ctl.meleeFor ~= e then
				Ctl.meleeFor = e
				Ctl.meleeReactAt = now + reactDelay(e.swingTti)
			end
			if now >= Ctl.meleeReactAt then
				Ctl.meleeReactAt = 0
				e.dodgedSwing = e.swingId
				e.lastDodgeAt = now
				meleeEvade(now, mx, mz, e, e.swingTti)
			end
			return
		end
	end
	for i = 1, enemyN do
		local e = enemyList[i]
		if e.attackActive and predDist(e, 0.3) <= e.reach + 2 and e.face >= 0.4 and e.dodgedAt ~= e.lastAttackStart then
			local hitAt = e.lastAttackStart + math.clamp(e.attackLen * e.hitFrac, 0.15, 0.6)
			local remaining = hitAt - now
			if remaining > -0.08 and remaining <= Config.MeleeReactWindow + Ctl.caution * 0.25 then
				if Ctl.meleeReactAt == 0 or Ctl.meleeFor ~= e then
					Ctl.meleeFor = e
					Ctl.meleeReactAt = now + reactDelay(remaining)
				end
				if now >= Ctl.meleeReactAt then
					Ctl.meleeReactAt = 0
					e.dodgedAt = e.lastAttackStart
					meleeEvade(now, mx, mz, e, remaining)
				end
				return
			end
		end
	end
	Ctl.meleeReactAt = 0
end

local function setFacing(on)
	if on == Ctl.facing then
		return
	end
	Ctl.facing = on
	local hum = ctx.hum
	if on then
		if hum then
			Ctl.prevAutoRotate = hum.AutoRotate
			hum.AutoRotate = false
		end
		if ctx.ao then
			ctx.ao.Enabled = true
		end
	else
		if hum then
			hum.AutoRotate = Ctl.prevAutoRotate
		end
		if ctx.ao then
			ctx.ao.Enabled = false
		end
	end
end

local function setControl(want)
	if want == Ctl.active then
		return
	end
	Ctl.active = want
	if want then
		local hum = ctx.hum
		if hum then
			ctx.baseWS = hum.WalkSpeed
			ctx.lastWS = hum.WalkSpeed
			ctx.bonusCur = 0
			if math.abs(ctx.baseWS - (ctx.tunedWS or 0)) > 0.5 then
				autoTune(ctx.baseWS)
			end
			local md = hum.MoveDirection
			if md.Magnitude > 0.1 and not Ctl.mvActive then
				Ctl.heading = math.atan2(md.Z, md.X)
			end
		end
		if not Ctl.mvActive then
			Ctl.speed = 0
		end
	else
		setFacing(false)
		Ctl.speed = 0
		Ctl.wantSpeed = 0
		if Ctl.velOn and ctx.lv then
			ctx.lv.Enabled = false
			ctx.lv.VectorVelocity = Vector3.zero
			Ctl.velOn = false
		end
		local hum = ctx.hum
		if hum and hum.Parent and ctx.bonusCur > 0 then
			hum.WalkSpeed = ctx.baseWS
			ctx.lastWS = ctx.baseWS
			ctx.bonusCur = 0
		end
	end
end

local function checkRanged(now, mx, mz)
	if not Config.RangedAntiAim or now < Ctl.rangedAt or Ctl.mvActive then
		return
	end
	for i = 1, enemyN do
		local e = enemyList[i]
		if e.attackActive and e.dist > e.reach + 3 and e.dist <= Config.RangedRange and e.face > 0.75 then
			local sx, sz = -e.oz, e.ox
			local side = -Ctl.rangedSide
			local ia, ib = slotOf(sx * side, sz * side), slotOf(-sx * side, -sz * side)
			local ca = rayVoid[ia] and 0 or rayClear[ia]
			local cb = rayVoid[ib] and 0 or rayClear[ib]
			if cb > ca + 0.3 then
				side = -side
			end
			Ctl.rangedSide = side
			Ctl.rangedAt = now + rng:NextNumber(0.5, 0.9)
			startManeuver(now, sx * side, sz * side, MV_DODGE, 0.75, PAT_ZIGZAG)
			return
		end
	end
end

local function castIfDue(now)
	if now >= Ctl.nextCast then
		Ctl.nextCast = now + Config.RayInterval * (Ctl.avgDt > 0.028 and 2 or 1)
		castSurroundings()
	end
end

local function autoVault(now, sx, sz)
	local c = ctx
	local hum = c.hum
	if not c.canJump or now < Ctl.vaultReadyAt or hum.FloorMaterial == Enum.Material.Air then
		return
	end
	local p = c.hrp.Position
	local feetY = p.Y - c.feetOff
	local dir = AXIS_X * sx + AXIS_Z * sz
	local reach = 3.2 * math.clamp(c.extents.Y / 5.2, 0.4, 4)
	local low = Workspace:Raycast(Vector3.new(p.X, feetY + 0.9 * math.clamp(c.extents.Y / 5.2, 0.4, 4), p.Z), dir * reach, c.rayParams)
	if not low or math.abs(low.Normal.Y) > 0.5 then
		return
	end
	local high = Workspace:Raycast(Vector3.new(p.X, feetY + Config.VaultMaxHeight, p.Z), dir * (reach + 1), c.rayParams)
	if high then
		return
	end
	hum:ChangeState(Enum.HumanoidStateType.Jumping)
	Ctl.vaultReadyAt = now + 0.6
end

local function tryWallKick(now, fx, fz)
	local c = ctx
	if not c.canJump then
		return
	end
	local bestI, bestC = 0, 0.28
	for i = 1, N_DIR do
		if rayClear[i] < bestC and (rayNx[i] ~= 0 or rayNz[i] ~= 0) then
			bestI, bestC = i, rayClear[i]
		end
	end
	if bestI == 0 then
		return
	end
	local nx, nz = rayNx[bestI], rayNz[bestI]
	local tx, tz = -nz, nx
	if tx * fx + tz * fz < 0 then
		tx, tz = -tx, -tz
	end
	local ts = slotOf(tx, tz)
	if rayVoid[ts] or rayClear[ts] < 0.6 then
		return
	end
	local sp = c.baseWS * Config.WallKickSpeedMul
	c.hum:ChangeState(Enum.HumanoidStateType.Jumping)
	c.hrp.AssemblyLinearVelocity = Vector3.new(
		tx * sp + nx * sp * 0.5,
		math.sqrt(2 * Workspace.Gravity * Config.WallKickHeight),
		tz * sp + nz * sp * 0.5
	)
	Ctl.kickReadyAt = now + Config.WallKickCooldown
	startManeuver(now, tx + nx * 0.3, tz + nz * 0.3, MV_DODGE, 0.55)
end

local function brain(now, dt)
	local c = ctx
	local hrp = c.hrp
	if not hrp then
		return
	end
	local p = hrp.Position
	local mx, mz = p.X, p.Z

	Ctl.caution = math.max(0, Ctl.caution - dt * 0.1)

	if now >= Ctl.nextTune then
		Ctl.nextTune = now + 2
		local oks, size = pcall(function()
			return c.char:GetExtentsSize()
		end)
		if oks and typeof(size) == "Vector3" and math.abs(size.Y - c.extents.Y) > c.extents.Y * 0.08 then
			autoTune(c.baseWS)
		end
	end

	if now >= Ctl.nextEnemyRefresh then
		Ctl.nextEnemyRefresh = now + 0.25
		refreshEnemies()
	end

	Ctl.escRange = Config.EscapeRange * (Ctl.active and 1.35 or 1)
	updateEnemies(now, mx, mz)
	local e = pickTarget()

	if Ctl.mvActive and now >= Ctl.mvUntil then
		Ctl.mvActive = false
	end

	local casted = false
	local want
	if Config.Mode == "Dodge" then

		if Enabled and cachedReason == nil then
			for i = 1, enemyN do
				local en = enemyList[i]
				if (en.attackActive or en.swing) and en.dist <= en.reach + 6 then
					castIfDue(now)
					casted = true
					checkMelee(now, mx, mz)
					break
				end
			end
		end
		if Enabled and cachedReason == nil and not casted and Config.RangedAntiAim then
			for i = 1, enemyN do
				local en = enemyList[i]
				if en.attackActive and en.dist > en.reach + 3 and en.dist <= Config.RangedRange and en.face > 0.75 then
					castIfDue(now)
					casted = true
					checkRanged(now, mx, mz)
					break
				end
			end
		end
		want = Enabled and cachedReason == nil and Ctl.mvActive
	else
		want = Enabled and cachedReason == nil and (Ctl.mvActive or e ~= nil)
	end
	setControl(want)
	if not Ctl.active then
		return
	end

	if not casted then
		castIfDue(now)
		checkMelee(now, mx, mz)
		checkRanged(now, mx, mz)
	end

	if Config.UseCover and Config.Mode == "Escape" and e ~= nil and e.root and e.root.Parent then
		if castTick % 2 == 0 and Ctl.coverTick ~= castTick then
			Ctl.coverTick = castTick
			local rp = e.root.Position
			computeCover(rp.X, rp.Y, rp.Z, e.model)
		end
	else
		for i = 1, N_DIR do
			rayCover[i] = 0
		end
	end

	local wx, wz, spd, turn = 0, 0, 0, Config.TurnRateNormal
	if now < Ctl.unstickUntil then
		wx, wz, spd, turn = Ctl.unstickX, Ctl.unstickZ, 1, Config.TurnRateEmergency
	elseif Ctl.mvActive then
		wx, wz = maneuverDir(now, mx, mz)
		spd = Ctl.mvSpeed
		turn = (Ctl.mvPattern == PAT_LINE) and Config.TurnRateEmergency or Config.TurnRatePattern
	elseif e then
		if Config.Mode == "Escape" then
			wx, wz, spd, turn = escapeTactics(now, mx, mz)
		else
			wx, wz, spd, turn = tactics(now, dt, mx, mz, e)
		end
	end

	local sx, sz = 0, 0
	if spd > 0 then
		sx, sz = contextSteer(wx, wz)
	end
	if sx == 0 and sz == 0 then
		spd = 0
	elseif spd > 0 then

		local fs = slotOf(sx, sz)
		local fc = rayVoid[fs] and 0 or rayClear[fs]
		if fc < 0.3 then
			spd = spd * (0.35 + fc * 2)
		end
	end
	Ctl.wantX, Ctl.wantZ, Ctl.wantSpeed, Ctl.wantTurn = sx, sz, spd, turn

	if Config.AutoVault and spd > 0.3 and (sx ~= 0 or sz ~= 0) then
		autoVault(now, sx, sz)
	end

	if Config.WallKick and now >= Ctl.kickReadyAt and not c.dashing then
		local kx, kz, kick = 0, 0, false
		if e ~= nil and e.dist < Ctl.escRange * 0.55 then
			kx, kz, kick = e.ox, e.oz, true
		elseif activeN > 0 then
			kx, kz, kick = mx - active[1].px, mz - active[1].pz, true
		end
		if kick then
			tryWallKick(now, kx, kz)
		end
	end

	stuckCheck(now, mx, mz)

	local face = Config.FaceEnemy and Ctl.mvActive and Ctl.mvPattern == PAT_ORBIT and e ~= nil and c.ao ~= nil
	setFacing(face)
	if face then
		c.ao.CFrame = CFrame.lookAt(ZERO, AXIS_X * (e.px - mx) + AXIS_Z * (e.pz - mz))
	end
end

local controlsObj = nil
local function readManual()
	if controlsObj == nil then
		local ok, res = pcall(function()
			return require(LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 2)):GetControls()
		end)
		controlsObj = (ok and res) or false
	end
	if controlsObj then
		local mv = controlsObj:GetMoveVector()
		return mv.X * mv.X + mv.Z * mv.Z > 0.09
	end
	return false
end

local function applyMove(dt)
	if not Ctl.active then
		return
	end
	local hum = ctx.hum
	if not hum or hum.Parent == nil then
		return
	end
	if Config.ManualOverride and not Config.NpcModel and readManual() then
		return
	end

	local ws = Ctl.wantSpeed
	local wx, wz = Ctl.wantX, Ctl.wantZ
	local s = Ctl.speed
	local h = Ctl.heading
	local tgt = 0

	if ws > 0.02 then
		local dhFull = (math.atan2(wz, wx) - h + math.pi) % TAU - math.pi
		local dh = dhFull
		if s < 0.12 then
			h = h + dh
		else
			local maxStep = Ctl.wantTurn * DEG * dt
			if dh > maxStep then
				dh = maxStep
			elseif dh < -maxStep then
				dh = -maxStep
			end
			h = h + dh
		end

		tgt = ws * (1 - (Ctl.mvActive and 0.12 or 0.35) * math.min(1, math.abs(dhFull) / math.pi))
	end

	if tgt > s then
		s = math.min(tgt, s + (Ctl.mvActive and Config.SpeedAccelDodge or Config.SpeedAccel) * dt)
	else
		s = math.max(tgt, s - Config.SpeedDecel * dt)
	end
	h = (h + math.pi) % TAU - math.pi
	Ctl.heading, Ctl.speed = h, s

	local ws0 = hum.WalkSpeed
	if math.abs(ws0 - ctx.lastWS) > 0.01 then

		ctx.baseWS = ws0
		ctx.bonusCur = 0
		if math.abs(ws0 - (ctx.tunedWS or 0)) > 0.5 then
			autoTune(ws0)
		end
	end
	local bonus = 0
	if Ctl.mvActive or (Config.Mode == "Escape" and target ~= nil) then
		bonus = math.min(Config.SpeedBonusMax, ctx.baseWS * Config.SpeedBonusPct)
	end
	ctx.bonusCur = ctx.bonusCur + (bonus - ctx.bonusCur) * (1 - math.exp(-10 * dt))
	hum.WalkSpeed = ctx.baseWS + ctx.bonusCur
	ctx.lastWS = hum.WalkSpeed

	local hrp = ctx.hrp
	local sp = hum.WalkSpeed
	if sp <= 0.05 then
		sp = Ctl.refSpeed
	end
	local useVel = Config.VelocityDrive and (Ctl.driveVel or Ctl.customMove) and not ctx.dashing
	if useVel then
		local lv = ctx.lv
		if lv and lv.Parent then
			if not lv.Enabled then
				lv.MaxAxesForce = Vector3.new(Config.DashForce, 0, Config.DashForce)
				lv.Enabled = true
			end
			Ctl.velOn = true
			lv.VectorVelocity = AXIS_X * (math.cos(h) * s * sp) + AXIS_Z * (math.sin(h) * s * sp)
		end
	elseif Ctl.velOn and not ctx.dashing then
		if ctx.lv then
			ctx.lv.Enabled = false
			ctx.lv.VectorVelocity = Vector3.zero
		end
		Ctl.velOn = false
	end

	hum:Move(AXIS_X * (math.cos(h) * s) + AXIS_Z * (math.sin(h) * s), false)

	if Config.VelocityDrive and not useVel and not ctx.dashing and ws > 0.5 then
		local expected = ctx.baseWS * s
		if expected > 5 then
			local hv = hrp.AssemblyLinearVelocity
			local ch, sh = math.cos(h), math.sin(h)
			local along = hv.X * ch + hv.Z * sh
			local fs = slotOf(ch, sh)
			local free = (rayVoid[fs] and 0 or rayClear[fs]) > 0.5
			if along < expected * 0.3 and free then
				Ctl.noComply += dt
				if Ctl.noComply > 0.35 then
					Ctl.driveVel = true
					Ctl.driveUntil = os.clock() + 3
					Ctl.noComply = 0
				end
			else
				Ctl.noComply = math.max(0, Ctl.noComply - dt * 2)
			end
		end
	end
	if Ctl.driveVel and os.clock() > Ctl.driveUntil then
		Ctl.driveVel = false
	end
end

local function updateState(now)
	local new
	if not Enabled then
		new = "Disabled"
	elseif cachedReason then
		new = "Blocked"
	elseif ctx.dashing then
		new = "Evading"
	elseif Ctl.active then
		new = "Combat"
	elseif now < ctx.cooldownEnd then
		new = "Cooldown"
	else
		new = "Idle"
	end
	if new ~= fsm then
		fsm = new
		LocalPlayer:SetAttribute("AutoEvasionState", fsm)
		dbg("state", new, cachedReason)
	end
	if now >= Ctl.nextAttr then
		Ctl.nextAttr = now + 0.25
		LocalPlayer:SetAttribute("AutoEvasionReason", cachedReason or "")
		LocalPlayer:SetAttribute("AutoEvasionThreats", activeN)
		LocalPlayer:SetAttribute("AutoEvasionEnemies", enemyN)
		LocalPlayer:SetAttribute("AutoEvasionPing", math.floor(pingMs))
	end
end

local function safeCall(name, fn, a, b)
	local ok, err = pcall(fn, a, b)
	if not ok then
		local msg = name .. ": " .. tostring(err)
		if Ctl.lastErr ~= msg then
			Ctl.lastErr = msg
			Ctl.errCount += 1
			errLog[#errLog + 1] = msg
			if #errLog > 6 then
				table.remove(errLog, 1)
			end
			warn("[AutoEvasion] " .. msg)
		end
	end
end

local function applyMoveSafe(dt)
	safeCall("applyMove", applyMove, dt)
end

local guardAcc, pingAcc, brainAcc = 0, 0, 0

local function onHeartbeat(dt)
	local c = ctx
	if not c.hrp then
		return
	end
	local now = os.clock()
	frame += 1
	Ctl.avgDt = Ctl.avgDt * 0.95 + dt * 0.05
	local slow = Ctl.avgDt > 0.028

	if c.dashing then
		local lv = c.lv
		local el = now - c.dashStart
		if el >= c.dashDur or not lv or not lv.Parent or c.hum.Health <= 0 or cachedReason or not Enabled then
			endDash()
		else
			local tau = el / c.dashDur
			lv.VectorVelocity = c.dashDir * (c.dashPeak * (1 - tau * tau))
		end
	end

	do
		local hv = c.hrp.AssemblyLinearVelocity
		local hs = math.sqrt(hv.X * hv.X + hv.Z * hv.Z)
		local wsNow = c.hum.WalkSpeed
		if not Ctl.active and hs > 3 and hs < 80 and wsNow > 0.05 then
			Ctl.refSpeed = Ctl.refSpeed + (hs - Ctl.refSpeed) * 0.02
		end
		if wsNow <= 0.05 and hs > 3 then
			Ctl.zeroWs += dt
			if Ctl.zeroWs > 1 then
				Ctl.customMove = true
			end
		else
			Ctl.zeroWs = math.max(0, Ctl.zeroWs - dt * 2)
			if wsNow > 0.05 then
				Ctl.customMove = false
			end
		end
	end

	pingAcc += dt
	if pingAcc >= 0.25 then
		pingAcc = 0
		updatePing()
	end

	guardAcc += dt
	if guardAcc >= 0.1 then
		guardAcc = 0
		cachedReason = guardReason()
	end

	if not Enabled or cachedReason then
		if Ctl.active then
			setControl(false)
		end
		if Ctl.facing then
			setFacing(false)
		end
		updateState(now)
		return
	end

	local every = Config.CalmScanEvery
	if now < dangerUntil then
		every = Config.DangerScanEvery
	end
	if slow then
		every += 1
	end
	if frame % every == 0 then
		safeCall("step", step, now)
	end
	if Ctl.mvActive and not Ctl.active then
		brainAcc = 0
		safeCall("brain", brain, now, 0.016)
	end

	brainAcc += dt
	if brainAcc >= 1 / (((now < dangerUntil) and Config.BrainHzDanger or Config.BrainHz) * (slow and 0.6 or 1)) then
		local bdt = brainAcc
		brainAcc = 0
		safeCall("brain", brain, now, bdt)
	end

	updateState(now)
end

local function teardownCharacter()
	local c = ctx
	setControl(false)
	for i = #c.conns, 1, -1 do
		c.conns[i]:Disconnect()
		c.conns[i] = nil
	end
	c.dashing = false
	if c.lv then
		c.lv:Destroy()
	end
	if c.ao then
		c.ao:Destroy()
	end
	if c.att then
		c.att:Destroy()
	end
	c.lv, c.ao, c.att = nil, nil, nil
	c.char, c.hum, c.hrp = nil, nil, nil
	c.rayParams, c.overlapParams, c.bruteParams = nil, nil, nil
	c.cooldownEnd = 0
	c.settleUntil = 0
	Ctl.mvActive = false
	Ctl.facing = false
	Ctl.pendingDodgeAt = 0
	target = nil
	clearThreats()
	cachedReason = "NoCharacter"
end

local function onCharacter(char)
	teardownCharacter()
	local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 10)
	local hrp = nil
	if hum then
		for _ = 1, 100 do
			hrp = hum.RootPart or char.PrimaryPart or char:FindFirstChild("HumanoidRootPart")
			if hrp then
				break
			end
			task.wait(0.1)
		end
	end
	if not hum or not hrp or getTarget() ~= char then
		return
	end
	local c = ctx
	c.char, c.hum, c.hrp = char, hum, hrp

	local ray = RaycastParams.new()
	setExclude(ray, { char })
	ray.RespectCanCollide = true
	c.rayParams = ray

	local ov = OverlapParams.new()
	setExclude(ov, { char })
	ov.MaxParts = Config.MaxScanParts
	ov.RespectCanCollide = false
	c.overlapParams = ov

	local bp = OverlapParams.new()
	setExclude(bp, { char })
	bp.MaxParts = Config.MaxScanParts
	pcall(function()
		bp.BruteForceAllSlow = true
	end)
	c.bruteParams = bp

	local att = Instance.new("Attachment")
	att.Name = "AutoEvadeAttachment"
	att.Parent = hrp

	local lv = Instance.new("LinearVelocity")
	lv.Name = "AutoEvadeDash"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	lv.MaxAxesForce = Vector3.new(Config.DashForce, 0, Config.DashForce)
	lv.VectorVelocity = Vector3.zero
	lv.Enabled = false
	lv.Parent = hrp

	local ao = Instance.new("AlignOrientation")
	ao.Name = "AutoMansFacing"
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.Attachment0 = att
	ao.RigidityEnabled = false
	ao.MaxTorque = 1e5
	ao.Responsiveness = 25
	ao.Enabled = false
	ao.Parent = hrp

	c.att, c.lv, c.ao = att, lv, ao

	c.conns[#c.conns + 1] = hum.Died:Connect(function()
		endDash()
		clearThreats()
		cachedReason = "Dead"
		setControl(false)
	end)
	local tuneQueued = false
	local function queueTune()
		if tuneQueued then
			return
		end
		tuneQueued = true
		task.defer(function()
			tuneQueued = false
			if ctx == c and c.hum == hum then
				autoTune(c.baseWS)
			end
		end)
	end
	for _, prop in ipairs({ "JumpHeight", "JumpPower", "UseJumpPower", "HipHeight" }) do
		c.conns[#c.conns + 1] = hum:GetPropertyChangedSignal(prop):Connect(queueTune)
	end
	c.lastHealth = hum.Health
	c.conns[#c.conns + 1] = hum.HealthChanged:Connect(function(h)
		local lost = c.lastHealth - h
		c.lastHealth = h
		if lost > 0.5 then
			onDamaged(os.clock())
		end
	end)
	c.conns[#c.conns + 1] = char.AncestryChanged:Connect(function()
		if not char:IsDescendantOf(game) and ctx.char == char then
			teardownCharacter()
		end
	end)

	c.baseWS, c.lastWS, c.bonusCur = hum.WalkSpeed, hum.WalkSpeed, 0
	autoTune(hum.WalkSpeed)
	cachedReason = nil
	pingAcc = 1
	Ctl.nextEnemyRefresh = 0
	dbg("target ready")
end

local function setEnabled(v)
	if Enabled == v then
		return
	end
	Enabled = v
	LocalPlayer:SetAttribute("AutoEvasionEnabled", v)
	if not v then
		endDash()
		clearThreats()
		Ctl.mvActive = false
		Ctl.pendingDodgeAt = 0
		setControl(false)
		setFacing(false)
	end
	if refreshUI then
		refreshUI(true)
	end
end

local function setMode(mode)
	if Config.Mode == mode then
		return
	end
	Config.Mode = mode
	LocalPlayer:SetAttribute("AutoEvasionMode", mode)
	Ctl.mvActive = false
	setControl(false)
	setFacing(false)
	if refreshUI then
		refreshUI(true)
	end
end

local COLOR_ON_BG = Color3.fromRGB(14, 52, 40)
local COLOR_OFF_BG = Color3.fromRGB(46, 22, 28)
local COLOR_ON = Color3.fromRGB(70, 255, 170)
local COLOR_OFF = Color3.fromRGB(255, 85, 95)
local COLOR_PANEL = Color3.fromRGB(26, 30, 42)
local COLOR_MUTED = Color3.fromRGB(125, 135, 155)
local COLOR_RUN = Color3.fromRGB(255, 150, 80)
local COLOR_DODGE = Color3.fromRGB(110, 190, 255)
local COLOR_COMBAT = Color3.fromRGB(255, 195, 70)
local COLOR_COMBAT_BG = Color3.fromRGB(64, 46, 14)
local COLOR_TEXT_REPORT = Color3.fromRGB(235, 240, 250)
local COLOR_RUN_BG = Color3.fromRGB(64, 34, 14)
local TWEEN_FAST = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TOP_ORDER = 2147483647

local UI = {
	gui = nil, root = nil, button = nil, status = nil, stroke = nil,
	modeBtn = nil, combatBtn = nil, modeStroke = nil, combatStroke = nil,
	conns = {},
	building = false,
	buildStarted = 0,
	validateQueued = false,
	savedPos = UDim2.new(1, -90, 0.45, 0),
	rebuildStamps = {},
}

local function buildReport()
	local L = {}
	local function add(line)
		L[#L + 1] = line
	end
	local c = ctx
	local hum = c.hum
	local nP, nA, nB = 0, 0, 0
	for _, r in pairs(threats) do
		if r.kind == "Proj" then
			nP += 1
		elseif r.kind == "AOE" then
			nA += 1
		else
			nB += 1
		end
	end
	add("=== AutoEvasion report ===")
	add("time(utc): " .. os.date("!%Y-%m-%d %H:%M:%S"))
	add(string.format("place=%s version=%s", tostring(game.PlaceId), tostring(game.PlaceVersion)))
	add(string.format("platform: touch=%s keyboard=%s gamepad=%s fps=%.0f ping=%dms lowFps=%s",
		tostring(UserInputService.TouchEnabled), tostring(UserInputService.KeyboardEnabled), tostring(UserInputService.GamepadEnabled),
		1 / math.max(Ctl.avgDt, 0.001), math.floor(pingMs), tostring(Ctl.avgDt > 0.028)))
	add(string.format("state: enabled=%s mode=%s fsm=%s reason=%s active=%s mv=%s pattern=%d", tostring(Enabled), tostring(Config.Mode),
		tostring(fsm), tostring(cachedReason), tostring(Ctl.active), tostring(Ctl.mvActive), Ctl.mvPattern))
	add(string.format("drive: driveVel=%s customMove=%s velOn=%s refSpeed=%.1f caution=%.2f hits=%d errors=%d", tostring(Ctl.driveVel),
		tostring(Ctl.customMove), tostring(Ctl.velOn), Ctl.refSpeed, Ctl.caution, Ctl.hits, Ctl.errCount))
	if hum and hum.Parent then
		add(string.format("character: rig=%s health=%.0f walk=%.1f base=%.1f bonus=%.2f jumpHeight=%.1f jumpPower=%.1f usePower=%s hip=%.2f extentsY=%.2f feetOff=%.2f canJump=%s",
			tostring(hum.RigType), hum.Health, hum.WalkSpeed, c.baseWS, c.bonusCur, hum.JumpHeight, hum.JumpPower, tostring(hum.UseJumpPower),
			hum.HipHeight, c.extents.Y, c.feetOff, tostring(c.canJump)))
	else
		add("character: none")
	end
	add(string.format("config: react=%s-%sms lead=%.2f horizon=%.1f scan=%.0f minRel=%.1f maxSize=%.1f body=%.2f/%.2f margin=%.2f reach=%.1f conflict=%.1f escape=%.1f",
		tostring(Config.ReactionMinMs), tostring(Config.ReactionMaxMs), Config.TriggerLead, Config.Horizon, Config.ScanRadius, Config.MinRelSpeed,
		Config.MaxThreatSize, Config.BodyRadius, Config.BodyHalfHeight, Config.HitMargin, Config.EnemyAttackRange, Config.ConflictRange, Config.EscapeRange))
	add(string.format("flags: dash=%s instant=%s limb=%s cover=%s loop=%s vault=%s kick=%s jumpDodge=%s ranged=%s brute=%s bonus=%.2f/%.1f",
		tostring(Config.DashEnabled), tostring(Config.InstantStart), tostring(Config.LimbTracking), tostring(Config.UseCover), tostring(Config.WallLoop),
		tostring(Config.AutoVault), tostring(Config.WallKick), tostring(Config.DodgeJump), tostring(Config.RangedAntiAim), tostring(Config.BruteForceScan),
		Config.SpeedBonusPct, Config.SpeedBonusMax))
	add(string.format("threats: tracked proj=%d aoe=%d beam=%d active=%d fresh=%d", nP, nA, nB, activeN, #fresh))
	add("enemies: " .. enemyN)
	for i = 1, math.min(enemyN, 6) do
		local e = enemyList[i]
		add(string.format("  %s dist=%.1f atk=%s swing=%s swingTti=%.2f reach=%.1f face=%.2f closing=%.1f limbs=%d hitFrac=%.2f",
			tostring(e.model.Name), e.dist, tostring(e.attackActive), tostring(e.swing), e.swingTti, e.reach, e.face, e.closing, e.limbN, e.hitFrac))
	end
	add("last hits:")
	for i = 1, #hitLog do
		add("  " .. hitLog[i])
	end
	add("errors:")
	for i = 1, #errLog do
		add("  " .. errLog[i])
	end
	return table.concat(L, "\n")
end

local function attachReportUI(gui, root, sf, y, H3)
	local function track(conn)
		UI.conns[#UI.conns + 1] = conn
		return conn
	end

	local btn = Instance.new("TextButton")
	btn.Name = "ReportButton"
	btn.Size = UDim2.new(1, 0, 0, H3)
	btn.Position = UDim2.fromOffset(0, y)
	btn.AutoButtonColor = false
	btn.BorderSizePixel = 0
	btn.BackgroundColor3 = COLOR_PANEL
	btn.Font = Enum.Font.GothamBold
	btn.TextScaled = true
	btn.TextColor3 = COLOR_MUTED
	btn.Text = "REPORT"
	btn.Parent = root
	local bl = Instance.new("UITextSizeConstraint")
	bl.MaxTextSize = math.floor(12 * sf)
	bl.MinTextSize = 7
	bl.Parent = btn
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(0, 8)
	bc.Parent = btn

	local frame = Instance.new("Frame")
	frame.Name = "ReportWindow"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromScale(0.86, 0.8)
	frame.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = gui
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(0, 14)
	fc.Parent = frame
	local fs = Instance.new("UISizeConstraint")
	fs.MaxSize = Vector2.new(720, 520)
	fs.Parent = frame

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(12, 6)
	title.Size = UDim2.new(1, -24, 0, 24)
	title.Font = Enum.Font.GothamBold
	title.TextSize = math.floor(14 * sf)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = COLOR_TEXT_REPORT
	title.Text = "Отчёт: SELECT, затем скопируй (Ctrl+C / долгое нажатие) и отправь мне"
	title.Parent = frame

	local scroll = Instance.new("ScrollingFrame")
	scroll.Position = UDim2.fromOffset(10, 36)
	scroll.Size = UDim2.new(1, -20, 1, -90)
	scroll.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 8
	scroll.CanvasSize = UDim2.fromOffset(0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Parent = frame
	local sc = Instance.new("UICorner")
	sc.CornerRadius = UDim.new(0, 8)
	sc.Parent = scroll

	local editable = UserInputService.TouchEnabled
	local box = Instance.new("TextBox")
	box.Size = UDim2.new(1, -12, 0, 0)
	box.Position = UDim2.fromOffset(6, 4)
	box.AutomaticSize = Enum.AutomaticSize.Y
	box.BackgroundTransparency = 1
	box.MultiLine = true
	box.TextWrapped = true
	box.ClearTextOnFocus = false
	box.TextEditable = editable
	box.Font = Enum.Font.Code
	box.TextSize = math.floor(12 * sf)
	box.TextColor3 = Color3.fromRGB(215, 225, 240)
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.TextYAlignment = Enum.TextYAlignment.Top
	box.Text = ""
	box.Parent = scroll

	local current = ""
	local function refresh()
		current = buildReport()
		box.Text = current
	end
	local function selectAll()
		if editable then
			box:CaptureFocus()
		end
		box.CursorPosition = #current + 1
		box.SelectionStart = 1
	end
	track(box:GetPropertyChangedSignal("Text"):Connect(function()
		if box.Text ~= current then
			box.Text = current
		end
	end))

	local function action(label, order, onTap)
		local b = Instance.new("TextButton")
		b.Name = label
		b.AutoButtonColor = true
		b.BorderSizePixel = 0
		b.BackgroundColor3 = COLOR_PANEL
		b.Font = Enum.Font.GothamBold
		b.TextSize = math.floor(13 * sf)
		b.TextColor3 = COLOR_TEXT_REPORT
		b.Text = label
		b.Size = UDim2.new(0.25, -9, 0, 34)
		b.Position = UDim2.new((order - 1) * 0.25, 10 - (order - 1) * 2, 1, -44)
		b.Parent = frame
		local cc = Instance.new("UICorner")
		cc.CornerRadius = UDim.new(0, 8)
		cc.Parent = b
		track(b.Activated:Connect(onTap))
	end
	action("SELECT", 1, selectAll)
	action("PRINT", 2, function()
		for line in string.gmatch(current, "[^\n]+") do
			print(line)
		end
	end)
	action("REFRESH", 3, function()
		refresh()
		selectAll()
	end)
	action("CLOSE", 4, function()
		frame.Visible = false
	end)

	track(btn.Activated:Connect(function()
		frame.Visible = not frame.Visible
		if frame.Visible then
			refresh()
			selectAll()
		end
	end))

	UI.reportBtn, UI.reportFrame = btn, frame
end

local function paint(inst, props, animate)
	if animate then
		TweenService:Create(inst, TWEEN_FAST, props):Play()
	else
		for k, v in pairs(props) do
			inst[k] = v
		end
	end
end

function refreshUI(animate)
	local b, mb, cb = UI.button, UI.modeBtn, UI.combatBtn
	if not b or not mb or not cb or not UI.status or not UI.stroke or not UI.modeStroke or not UI.combatStroke then
		return
	end
	local on = Enabled
	local accent = on and COLOR_ON or COLOR_OFF
	UI.status.Text = on and "AUTO  ON" or "AUTO  OFF"
	paint(b, { BackgroundColor3 = on and COLOR_ON_BG or COLOR_OFF_BG }, animate)
	paint(UI.stroke, { Color = accent }, animate)
	paint(UI.status, { TextColor3 = accent }, animate)

	local run = Config.Mode == "Escape"
	paint(mb, {
		BackgroundColor3 = run and COLOR_RUN_BG or COLOR_PANEL,
		TextColor3 = run and COLOR_RUN or COLOR_MUTED,
	}, animate)
	paint(UI.modeStroke, { Color = run and COLOR_RUN or COLOR_MUTED }, animate)

	local combat = not run
	paint(cb, {
		BackgroundColor3 = combat and COLOR_COMBAT_BG or COLOR_PANEL,
		TextColor3 = combat and COLOR_COMBAT or COLOR_MUTED,
	}, animate)
	paint(UI.combatStroke, { Color = combat and COLOR_COMBAT or COLOR_MUTED }, animate)
end

local function disconnectUI()
	for i = #UI.conns, 1, -1 do
		UI.conns[i]:Disconnect()
		UI.conns[i] = nil
	end
end

local function destroyUI()
	disconnectUI()
	local old = UI.gui
	UI.gui, UI.root, UI.button, UI.status, UI.stroke = nil, nil, nil, nil, nil
	UI.modeBtn, UI.combatBtn, UI.modeStroke, UI.combatStroke = nil, nil, nil, nil
	UI.reportBtn, UI.reportFrame = nil, nil
	if old then
		pcall(function()
			old:Destroy()
		end)
	end
end

local buildUI

local function validateUI()
	if UI.building then
		return
	end
	local gui, root, button = UI.gui, UI.root, UI.button
	local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
	local intact = gui ~= nil and root ~= nil and button ~= nil and playerGui ~= nil
		and gui.Parent == playerGui
		and root.Parent == gui
		and button.Parent == root
		and UI.modeBtn ~= nil and UI.modeBtn.Parent == root
		and UI.combatBtn ~= nil and UI.combatBtn.Parent == root
		and UI.status ~= nil and UI.status.Parent == button
		and UI.stroke ~= nil and UI.stroke.Parent == button
	if not intact then
		local now = os.clock()
		local stamps = UI.rebuildStamps
		for i = #stamps, 1, -1 do
			if now - stamps[i] > 2 then
				table.remove(stamps, i)
			end
		end
		stamps[#stamps + 1] = now
		if #stamps > 8 then
			task.wait(0.5)
		end
		buildUI()
		return
	end
	if not gui.Enabled then
		gui.Enabled = true
	end
	if gui.DisplayOrder ~= TOP_ORDER then
		gui.DisplayOrder = TOP_ORDER
	end
	if not root.Visible then
		root.Visible = true
	end
	if not button.Visible then
		button.Visible = true
	end
	if not UI.modeBtn.Visible then
		UI.modeBtn.Visible = true
	end
	if not UI.combatBtn.Visible then
		UI.combatBtn.Visible = true
	end
	if root.AbsoluteSize.X < 40 or button.AbsoluteSize.Y < 16 then
		buildUI()
		return
	end
	local vs = gui.AbsoluteSize
	local ap = root.AbsolutePosition
	if vs.X > 0 and (ap.X < -10 or ap.Y < -10 or ap.X > vs.X - 20 or ap.Y > vs.Y - 20) then
		root.Position = UDim2.new(1, -90, 0.45, 0)
		UI.savedPos = root.Position
	end
end

local function queueValidate()
	if UI.validateQueued then
		return
	end
	UI.validateQueued = true
	task.defer(function()
		UI.validateQueued = false
		validateUI()
	end)
end

function buildUI()
	if UI.building then
		return
	end
	UI.building = true
	UI.buildStarted = os.clock()
	destroyUI()

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local cam = Workspace.CurrentCamera
	local sf = 1
	if cam then
		sf = math.clamp(cam.ViewportSize.Y / 720, 0.8, 1.3)
	end
	local W = math.floor(156 * sf)
	local H1 = math.floor(46 * sf)
	local H2 = math.floor(34 * sf)
	local H3 = math.floor(22 * sf)
	local gap = math.floor(6 * sf)
	local gapL = math.floor(gap / 2)
	local gapR = gap - gapL

	local gui = Instance.new("ScreenGui")
	gui.Name = "HumanlikeAutoMansGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = TOP_ORDER
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = true

	local root = Instance.new("Frame")
	root.Name = "Panel"
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Size = UDim2.fromOffset(W, H1 + gap + H2 + gap + H3)
	root.Position = UI.savedPos
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Parent = gui

	local function style(btn, radius, color, thickness)
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, radius)
		corner.Parent = btn
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = thickness
		stroke.Color = color
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = btn
		local scale = Instance.new("UIScale")
		scale.Scale = 1
		scale.Parent = btn
		return stroke, scale
	end

	local button = Instance.new("TextButton")
	button.Name = "ToggleButton"
	button.Size = UDim2.new(1, 0, 0, H1)
	button.Position = UDim2.fromOffset(0, 0)
	button.AutoButtonColor = false
	button.Text = ""
	button.Active = true
	button.BorderSizePixel = 0
	button.BackgroundColor3 = COLOR_OFF_BG
	button.Parent = root
	local stroke, scale = style(button, 14, COLOR_OFF, 2.5)

	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.BackgroundTransparency = 1
	status.Size = UDim2.fromScale(1, 1)
	status.Font = Enum.Font.GothamBlack
	status.TextSize = math.floor(18 * sf)
	status.TextColor3 = COLOR_OFF
	status.Text = "AUTO  OFF"
	status.Parent = button

	local function small(name, size, pos)
		local b = Instance.new("TextButton")
		b.Name = name
		b.Size = size
		b.Position = pos
		b.AutoButtonColor = false
		b.Active = true
		b.BorderSizePixel = 0
		b.BackgroundColor3 = COLOR_PANEL
		b.Font = Enum.Font.GothamBold
		b.TextScaled = true
		b.TextColor3 = COLOR_MUTED
		b.Text = name
		b.Parent = root
		local limit = Instance.new("UITextSizeConstraint")
		limit.MaxTextSize = math.floor(15 * sf)
		limit.MinTextSize = 8
		limit.Parent = b
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 6)
		pad.PaddingRight = UDim.new(0, 6)
		pad.Parent = b
		local st, sc = style(b, 10, COLOR_MUTED, 1.5)
		return b, st, sc
	end

	local modeBtn, modeStroke, modeScale = small("RUN", UDim2.new(0.5, -gapL, 0, H2), UDim2.fromOffset(0, H1 + gap))
	local combatBtn, combatStroke, combatScale = small("COMBAT", UDim2.new(0.5, -gapR, 0, H2), UDim2.new(0.5, gapR, 0, H1 + gap))

	UI.gui, UI.root, UI.button, UI.status, UI.stroke = gui, root, button, status, stroke
	UI.modeBtn, UI.combatBtn, UI.modeStroke, UI.combatStroke = modeBtn, combatBtn, modeStroke, combatStroke

	local function track(conn)
		UI.conns[#UI.conns + 1] = conn
		return conn
	end

	track(gui.AncestryChanged:Connect(queueValidate))
	track(root.AncestryChanged:Connect(queueValidate))
	track(button.AncestryChanged:Connect(queueValidate))
	track(gui.DescendantRemoving:Connect(queueValidate))
	track(gui:GetPropertyChangedSignal("Enabled"):Connect(queueValidate))
	track(gui:GetPropertyChangedSignal("DisplayOrder"):Connect(queueValidate))
	track(root:GetPropertyChangedSignal("Visible"):Connect(queueValidate))
	track(root:GetPropertyChangedSignal("Size"):Connect(queueValidate))
	track(button:GetPropertyChangedSignal("Visible"):Connect(queueValidate))
	track(modeBtn:GetPropertyChangedSignal("Visible"):Connect(queueValidate))
	track(combatBtn:GetPropertyChangedSignal("Visible"):Connect(queueValidate))

	local function bindTap(btn, scaleObj, onTap)
		local pressed = nil
		track(btn.InputBegan:Connect(function(input)
			local t = input.UserInputType
			if pressed == nil and (t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1) then
				pressed = input
				TweenService:Create(scaleObj, TWEEN_FAST, { Scale = 0.92 }):Play()
			end
		end))
		track(UserInputService.InputEnded:Connect(function(input)
			if not pressed then
				return
			end
			local isTouch = pressed.UserInputType == Enum.UserInputType.Touch
			local matches = (isTouch and input == pressed) or (not isTouch and input.UserInputType == Enum.UserInputType.MouseButton1)
			if matches then
				pressed = nil
				TweenService:Create(scaleObj, TWEEN_FAST, { Scale = 1 }):Play()
				onTap()
			end
		end))
	end

	bindTap(modeBtn, modeScale, function()
		setMode("Escape")
	end)
	bindTap(combatBtn, combatScale, function()
		setMode("Dodge")
	end)

	local pressInput, pressStart, startCenter, moved = nil, nil, nil, false

	track(button.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if pressInput == nil and (t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1) then
			pressInput = input
			pressStart = input.Position
			startCenter = root.AbsolutePosition + root.AbsoluteSize * 0.5
			moved = false
			TweenService:Create(scale, TWEEN_FAST, { Scale = 0.94 }):Play()
		end
	end))

	track(UserInputService.InputChanged:Connect(function(input)
		if not pressInput then
			return
		end
		local isTouch = pressInput.UserInputType == Enum.UserInputType.Touch
		if (isTouch and input == pressInput) or (not isTouch and input.UserInputType == Enum.UserInputType.MouseMovement) then
			local d = input.Position - pressStart
			if moved or d.Magnitude > 10 then
				moved = true
				local vs = gui.AbsoluteSize
				local half = root.AbsoluteSize * 0.5
				if vs.X > 0 and vs.Y > 0 then
					local x = math.clamp(startCenter.X + d.X, half.X, math.max(half.X, vs.X - half.X))
					local y = math.clamp(startCenter.Y + d.Y, half.Y, math.max(half.Y, vs.Y - half.Y))
					root.Position = UDim2.fromScale(x / vs.X, y / vs.Y)
					UI.savedPos = root.Position
				end
			end
		end
	end))

	track(UserInputService.InputEnded:Connect(function(input)
		if not pressInput then
			return
		end
		local isTouch = pressInput.UserInputType == Enum.UserInputType.Touch
		local matches = (isTouch and input == pressInput) or (not isTouch and input.UserInputType == Enum.UserInputType.MouseButton1)
		if matches then
			local wasMoved = moved
			pressInput = nil
			TweenService:Create(scale, TWEEN_FAST, { Scale = 1 }):Play()
			if not wasMoved then
				setEnabled(not Enabled)
			end
		end
	end))

	local okr, errr = pcall(attachReportUI, gui, root, sf, H1 + gap + H2 + gap, H3)
	if not okr then
		warn("[HumanlikeAutoMans] report UI error: " .. tostring(errr))
	end

	gui.Parent = playerGui
	refreshUI(false)
	UI.building = false
end

local rawBuildUI = buildUI
buildUI = function()
	local ok, err = pcall(rawBuildUI)
	if not ok then
		UI.building = false
		warn("[HumanlikeAutoMans] UI build error: " .. tostring(err))
	end
end

LocalPlayer:SetAttribute("AutoEvasionEnabled", Enabled)
LocalPlayer:SetAttribute("AutoEvasionState", fsm)
LocalPlayer:SetAttribute("AutoEvasionMode", Config.Mode)
LocalPlayer:GetAttributeChangedSignal("AutoEvasionMode"):Connect(function()
	local a = LocalPlayer:GetAttribute("AutoEvasionMode")
	if (a == "Escape" or a == "Dodge") and a ~= Config.Mode then
		setMode(a)
	end
end)

LocalPlayer:GetAttributeChangedSignal("AutoEvasionEnabled"):Connect(function()
	local a = LocalPlayer:GetAttribute("AutoEvasionEnabled")
	if type(a) == "boolean" and a ~= Enabled then
		setEnabled(a)
	end
end)

Workspace.DescendantAdded:Connect(function(inst)
	if inst:IsA("BasePart") then
		bornAt[inst] = os.clock()
		if #fresh < 400 then
			fresh[#fresh + 1] = inst
		end
	end
end)

buildUI()
local playerGuiRoot = LocalPlayer:WaitForChild("PlayerGui")
playerGuiRoot.ChildRemoved:Connect(function(child)
	if child == UI.gui or child.Name == "HumanlikeAutoMansGui" then
		queueValidate()
	end
end)
playerGuiRoot.ChildAdded:Connect(function()
	queueValidate()
end)

local uiWatchAcc = 0
RunService.Heartbeat:Connect(function(dt)
	uiWatchAcc += dt
	if uiWatchAcc < 0.25 then
		return
	end
	uiWatchAcc = 0
	if UI.building and os.clock() - (UI.buildStarted or 0) > 3 then
		UI.building = false
	end
	validateUI()
end)
LocalPlayer.CharacterAdded:Connect(function()
	task.delay(0.2, queueValidate)
	task.delay(1.5, queueValidate)
	task.delay(4, queueValidate)
end)
LocalPlayer.CharacterRemoving:Connect(function()
	queueValidate()
end)
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(queueValidate)

if Config.NpcModel then
	task.spawn(onCharacter, Config.NpcModel)
else
	LocalPlayer.CharacterAdded:Connect(onCharacter)
	if LocalPlayer.Character then
		task.spawn(onCharacter, LocalPlayer.Character)
	else
		cachedReason = "NoCharacter"
	end
end

script.Destroying:Connect(function()
	RunService:UnbindFromRenderStep("HumanlikeAutoMansMove")
	setControl(false)
	setFacing(false)
	destroyUI()
	teardownCharacter()
end)

RunService:BindToRenderStep("HumanlikeAutoMansMove", Enum.RenderPriority.Character.Value + 1, applyMoveSafe)
RunService.Heartbeat:Connect(onHeartbeat)
