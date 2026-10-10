--[[
	AUTO DODGE FINAL v5.2  (универсальный упреждающий авто-уворот, "заранее мансит")
	LocalScript -> StarterPlayer > StarterPlayerScripts
	(если стоит AutoDodgeUniversal v5.0, удали его: два скрипта сразу будут мешать друг другу)

	ЗАРАНЕЕ: уворот стартует ДО удара. Скрипт берёт момент удара из анимации, вычитает LeadTime
	и учитывает, куда враг и ты сдвинетесь к этому моменту (Anticipate), а не только текущую дистанцию.
	Уходит ПЕРПЕНДИКУЛЯРНО линии атаки врага (куда он смотрит), в сторону, где уже стоишь.

	Опасность ищется пятью способами:
	  1) АНИМАЦИИ врагов: началась атакующая анимация, враг смотрит на тебя и достаёт до тебя
	  2) АТРИБУТЫ врагов: Attacking / UsingSkill / Casting / M1 переключились false -> true
	  3) СНАРЯДЫ и ЗОНЫ: летящий в тебя Part или хитбокс-зона (по имени), включая хитбоксы внутри моделей врагов
	  4) ДВИЖЕНИЕ врагов: дэши, рывки, наскоки. Смотрим на скорость и траекторию, анимация не нужна
	  5) УРОН: если ты потерял здоровье и враг рядом, выходим из серии быстрых ударов
	Ручной вход: player.AutoDodgeThreat:Fire(позиция | Part | Model) -- например, из серверного Remote

	Включение: кнопка "DODGE: ON/OFF" (двигается пальцем) или Config.Key.
	Из других скриптов: game.Players.LocalPlayer:SetAttribute("AutoDodge", true / false)

	НЕ уворачивается и не перехватывает движение, пока ты занят: лечишь/несёшь игрока, держишь
	ProximityPrompt, стоишь в BusyAttributes, держишь Tool из BusyTools, оглушён, сидишь, в рэгдолле.
	Рывок короткий (DodgeTime): это один шаг в сторону, а не "убегание".

	Настройка: Config.Debug = true печатает в Output, какая анимация вызвала уворот (оттуда берёшь
	AnimationId для AttackAnimIds и подбираешь время удара).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ProximityPromptService = game:GetService("ProximityPromptService")

local player = Players.LocalPlayer

--------------------------------------------------------------------
-- НАСТРОЙКИ
--------------------------------------------------------------------
local Config = {
	Key = Enum.KeyCode.B,
	StartEnabled = true,
	ButtonPosition = UDim2.new(1, -110, 0.5, 110),
	Debug = false,

	-- сам уворот
	DodgeDistance = 11,          -- дальность рывка (studs)
	DodgeTime = 0.22,            -- длительность рывка (сек)
	Cooldown = 0.75,             -- КД между уворотами
	DodgeAction = nil,           -- function(direction: Vector3, distance: number): твой дэш; если задана, свой рывок не делаем

	-- кто опасен
	DetectRange = 30,
	TargetPlayers = true,
	TargetNPCs = true,
	IgnoreTeammates = true,
	EnemyFilter = nil,           -- function(model) -> true/false (необязательно)

	-- 1) анимации врагов
	UseAnimations = true,
	MeleeRange = 14,             -- ближе этого атака считается опасной
	RequireFacing = true,        -- враг должен смотреть в твою сторону
	FacingDot = 0.25,            -- -1..1, чем больше, тем строже
	DefaultHitTime = 0.18,       -- через сколько секунд анимации приходит удар (если не задано ниже)
	LeadTime = 0.20,             -- ЗАРАНЕЕ: начинаем рывок за столько секунд до удара (больше = раньше)
	Anticipate = true,           -- учитывать, куда враг и ты сдвинетесь к моменту удара
	AttackAnimIds = {},          -- ["rbxassetid://123"] = 0.25  или  = { Hit = 0.25, Range = 20 }
	IgnoreAnimIds = {},          -- ["rbxassetid://456"] = true
	ActionPriorityIsAttack = true, -- любая не зацикленная анимация с приоритетом Action* считается атакой
	AttackKeywords = { "attack", "atk", "slash", "punch", "kick", "swing", "strike", "m1", "skill", "combo",
		"smash", "stab", "bite", "claw", "shoot", "slam", "uppercut", "heavy", "light" },
	IgnoreKeywords = { "idle", "walk", "run", "jump", "fall", "climb", "swim", "sit", "emote", "dance", "wave",
		"laugh", "cheer", "point", "salute", "tilt", "land", "toolnone", "hurt", "stun", "block", "dodge",
		"dash", "roll", "heal", "carry" },

	-- 2) атрибуты врагов (false -> true)
	AttackAttributes = { "Attacking", "UsingSkill", "Casting", "M1" },

	-- 4) ДВИЖЕНИЕ врагов: дэши, рывки, наскоки (скорость и траектория, анимация не нужна)
	UseMovement = true,
	DashMinSpeed = 28,           -- враг быстрее этого (studs/сек) считается рывком
	DashWalkMultiplier = 1.6,    -- и быстрее его WalkSpeed в столько раз (обычный бег рывком не считается)
	DashReactTime = 0.5,         -- уворачиваемся, если траектория пройдёт мимо тебя не позже чем через столько секунд
	DashHitRadius = 7,           -- насколько близко рывок должен пройти, чтобы считаться угрозой
	DashCooldown = 0.35,         -- пауза между срабатываниями на одного и того же врага

	-- 5) РЕАКЦИЯ НА УРОН: быстрые серии ударов, чтобы не стоять под комбо
	DodgeOnDamage = true,
	DamageDodgeMinPct = 0.04,    -- потеря здоровья (доля от MaxHealth), после которой уворачиваемся
	DamageDodgeRange = 16,       -- враг должен быть ближе этого

	-- 3) снаряды и зоны
	UseProjectiles = true,
	ProjectileMinSpeed = 30,     -- studs/сек, медленнее не считаем снарядом
	ProjectileMaxSize = 14,      -- крупнее (по диагонали) игнорируем
	ProjectileLifetime = 5,      -- сколько секунд следим за новым Part
	ProjectileReactTime = 0.6,   -- уворачиваемся, если попадёт не позже чем через столько секунд
	MaxTracked = 300,            -- сколько новых Part отслеживать одновременно
	UseZones = true,             -- зоны/хитбоксы с "опасным" именем, внутри которых ты оказался
	ThreatNameKeywords = { "hitbox", "damage", "attack", "explosion", "blast", "aoe", "projectile", "bullet",
		"fireball", "slash", "shockwave" },
	ThreatFilter = nil,          -- function(part) -> true/false (false = не считать угрозой)

	-- когда НЕ уворачиваться (атрибут = true на персонаже или на игроке)
	BusyAttributes = { "Healing", "Carrying", "Interacting", "Casting", "Channeling", "Stunned", "Ragdoll", "NoDodge" },
	BusyTools = {},              -- имена Tool в руках, при которых уворота нет, например { "Medkit", "Heal" }
	PauseWhilePromptHeld = true, -- пока зажат ProximityPrompt (лечение, поднять игрока, подбор)
}

-- защита от неверных значений
Config.DodgeTime = math.max(Config.DodgeTime, 0.05)
Config.DodgeDistance = math.max(Config.DodgeDistance, 3)
Config.Cooldown = math.max(Config.Cooldown, 0)
Config.LeadTime = math.max(Config.LeadTime, 0)

--------------------------------------------------------------------
-- СОСТОЯНИЕ
--------------------------------------------------------------------
local enabled = false
local lastDodge = 0
local npcs = {}                                  -- [Model] = Humanoid
local seenTracks = setmetatable({}, { __mode = "k" })
local attrState = setmetatable({}, { __mode = "k" })
local enemyMotion = setmetatable({}, { __mode = "k" }) -- [model] = { pos, fast, cool }
local curNearest, curNearestDist, lastNearest = nil, math.huge, nil
local lastHealth = nil
local tracked = {}                               -- [Part] = данные снаряда/зоны
local trackedCount = 0
local holding = {}                               -- [ProximityPrompt] = время начала удержания
local dodgeFlash = nil                           -- заполняется после создания интерфейса

local function buildSet(enumType, names)
	local set = {}
	for _, n in ipairs(names) do
		local ok, item = pcall(function() return enumType[n] end)
		if ok and item then set[item] = true end
	end
	return set
end

local BAD_STATES = buildSet(Enum.HumanoidStateType,
	{ "Dead", "Physics", "Ragdoll", "FallingDown", "PlatformStanding" })
local ACTION_PRIORITIES = buildSet(Enum.AnimationPriority,
	{ "Action", "Action2", "Action3", "Action4" })

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

--------------------------------------------------------------------
-- ВСПОМОГАТЕЛЬНОЕ
--------------------------------------------------------------------
local lastErr = nil
local function safe(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		local msg = tostring(err)
		if msg ~= lastErr then
			lastErr = msg
			warn("[AutoDodge] " .. msg)
		end
	end
end

local function dbg(...)
	if Config.Debug then
		print("[AutoDodge]", ...)
	end
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function hasKeyword(str, list)
	str = string.lower(str)
	for _, k in ipairs(list) do
		if string.find(str, k, 1, true) then return true end
	end
	return false
end

local function promptBusy()
	local now = os.clock()
	for prompt, t in pairs(holding) do
		if now - t > 20 or not prompt.Parent then
			holding[prompt] = nil
		else
			return true
		end
	end
	return false
end

ProximityPromptService.PromptButtonHoldBegan:Connect(function(prompt) holding[prompt] = os.clock() end)
ProximityPromptService.PromptButtonHoldEnded:Connect(function(prompt) holding[prompt] = nil end)
ProximityPromptService.PromptTriggered:Connect(function(prompt) holding[prompt] = nil end)
ProximityPromptService.PromptHidden:Connect(function(prompt) holding[prompt] = nil end)

local function canDodge(char, hum)
	if hum.Health <= 0 or hum.Sit or hum.PlatformStand then return false end
	if BAD_STATES[hum:GetState()] then return false end
	for _, name in ipairs(Config.BusyAttributes) do
		if char:GetAttribute(name) or player:GetAttribute(name) then return false end
	end
	if Config.PauseWhilePromptHeld and promptBusy() then return false end
	local tool = char:FindFirstChildOfClass("Tool")
	if tool then
		if tool:GetAttribute("NoAutoDodge") then return false end
		for _, name in ipairs(Config.BusyTools) do
			if tool.Name == name then return false end
		end
	end
	return true
end

local function sameTeam(p)
	return Config.IgnoreTeammates and p ~= nil and p ~= player
		and p.Team ~= nil and p.Team == player.Team
end

--------------------------------------------------------------------
-- NPC: собираем один раз и следим за новыми
--------------------------------------------------------------------
local function registerHumanoid(inst)
	if inst:IsA("Humanoid") then
		local model = inst.Parent
		if model and model:IsA("Model") then
			npcs[model] = inst
		end
	end
end

if Config.TargetNPCs then
	for _, d in ipairs(workspace:GetDescendants()) do
		registerHumanoid(d)
	end
	workspace.DescendantAdded:Connect(registerHumanoid)
end

local function forEachEnemy(myRoot, fn)
	local function visit(model, hum)
		if model == player.Character or not hum or hum.Health <= 0 then return end
		if Config.EnemyFilter and not Config.EnemyFilter(model) then return end
		local r = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
		if not r then return end
		if (r.Position - myRoot.Position).Magnitude > Config.DetectRange then return end
		fn(model, r)
	end

	if Config.TargetPlayers then
		for _, p in ipairs(Players:GetPlayers()) do
			local c = p.Character
			if p ~= player and c and not sameTeam(p) then
				visit(c, c:FindFirstChildOfClass("Humanoid"))
			end
		end
	end

	if Config.TargetNPCs then
		for model, hum in pairs(npcs) do
			if model.Parent == nil or hum.Parent == nil then
				npcs[model] = nil
			elseif not Players:GetPlayerFromCharacter(model) then
				visit(model, hum)
			end
		end
	end
end

--------------------------------------------------------------------
-- ВЫБОР НАПРАВЛЕНИЯ И САМ РЫВОК
--------------------------------------------------------------------
local function freeDistance(root, dir, maxDist)
	local hit = workspace:Raycast(root.Position, dir * (maxDist + 2), rayParams)
	if hit then return hit.Distance - 2 end
	return maxDist
end

-- away: куда летит атака (от врага к тебе); bias: в какую сторону от линии атаки ты уже смещён
local function pickDirection(char, root, hum, away, allowBack, bias)
	rayParams.FilterDescendantsInstances = { char }

	away = flat(away)
	if away.Magnitude < 0.05 then
		away = flat(-root.CFrame.LookVector)
	end
	if away.Magnitude < 0.05 then return nil end
	away = away.Unit
	local side = Vector3.new(-away.Z, 0, away.X)

	local cands = { side, -side }
	if allowBack then
		table.insert(cands, (side + away * 0.6).Unit)
		table.insert(cands, (-side + away * 0.6).Unit)
		table.insert(cands, away)
	end

	local bestDir, bestDist, bestScore = nil, 0, -math.huge
	for _, c in ipairs(cands) do
		local free = freeDistance(root, c, Config.DodgeDistance)
		if free >= 3 then
			local dist = math.min(Config.DodgeDistance, free)
			local ground = workspace:Raycast(root.Position + c * dist, Vector3.new(0, -14, 0), rayParams)
			if ground then
				local score = dist + hum.MoveDirection:Dot(c) * 3
				if bias then score = score + bias:Dot(c) * 2 end
				if score > bestScore then
					bestDir, bestDist, bestScore = c, dist, score
				end
			end
		end
	end
	return bestDir, bestDist
end

local dodgeDir, dodgeEnd, dodgeSpeed = nil, 0, 0

local function startDodge(dir, dist)
	if Config.DodgeAction then
		pcall(Config.DodgeAction, dir, dist)
		return
	end
	dodgeDir = dir
	dodgeEnd = os.clock() + Config.DodgeTime
	dodgeSpeed = dist / Config.DodgeTime
end

local function requestDodge(away, allowBack, bias, reason)
	local now = os.clock()
	if now - lastDodge < Config.Cooldown then return end

	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (hum and root) or not canDodge(char, hum) then return end

	local dir, dist = pickDirection(char, root, hum, away, allowBack, bias)
	if not dir then
		dbg("нет свободного места для уворота:", reason)
		return
	end

	lastDodge = now
	dbg("уворот:", reason)
	startDodge(dir, dist)
	if dodgeFlash then dodgeFlash() end
end

-- рывок: скорость задаём до физики, направление движения после управления игрока
local function stepDodge()
	if not dodgeDir then return end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (hum and root) or os.clock() >= dodgeEnd or not canDodge(char, hum) then
		if root and hum then
			local v = root.AssemblyLinearVelocity
			local walk = hum.MoveDirection * hum.WalkSpeed
			root.AssemblyLinearVelocity = Vector3.new(walk.X, v.Y, walk.Z)
		end
		dodgeDir = nil
		return
	end
	local v = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(dodgeDir.X * dodgeSpeed, v.Y, dodgeDir.Z * dodgeSpeed)
end

local function renderDodge()
	if not dodgeDir then return end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum:Move(dodgeDir, false)
	end
end

RunService.Stepped:Connect(function() safe(stepDodge) end)

pcall(function() RunService:UnbindFromRenderStep("AutoDodgeMove") end)
RunService:BindToRenderStep("AutoDodgeMove", Enum.RenderPriority.Last.Value, function()
	safe(renderDodge)
end)

player.CharacterAdded:Connect(function()
	dodgeDir = nil
	lastDodge = 0
end)

--------------------------------------------------------------------
-- 5) РЕАКЦИЯ НА УРОН (быстрые серии ударов)
--------------------------------------------------------------------
local function watchHealth(char)
	local hum = char:WaitForChild("Humanoid", 10)
	if not hum then return end
	lastHealth = hum.Health
	hum.HealthChanged:Connect(function(h)
		local prev = lastHealth
		lastHealth = h
		if not enabled or not Config.DodgeOnDamage or not prev then return end
		if prev - h < hum.MaxHealth * Config.DamageDodgeMinPct then return end
		local e = lastNearest
		local root = char:FindFirstChild("HumanoidRootPart")
		if not (e and e.Parent and root) then return end
		local away = flat(root.Position - e.Position)
		if away.Magnitude > Config.DamageDodgeRange then return end
		safe(requestDodge, away, true, nil, "получен урон")
	end)
end

if player.Character then
	task.spawn(watchHealth, player.Character)
end
player.CharacterAdded:Connect(function(char)
	task.spawn(watchHealth, char)
end)

--------------------------------------------------------------------
-- 1) + 2) АНИМАЦИИ И АТРИБУТЫ ВРАГОВ
--------------------------------------------------------------------
local function getAnimator(model)
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		local a = hum:FindFirstChildOfClass("Animator")
		if a then return a end
	end
	local ac = model:FindFirstChildOfClass("AnimationController")
	return ac and ac:FindFirstChildOfClass("Animator")
end

local function isAttackTrack(track)
	local anim = track.Animation
	if not anim then return false end
	local id = anim.AnimationId
	if Config.IgnoreAnimIds[id] then return false end
	if Config.AttackAnimIds[id] then return true end
	if track.Looped then return false end
	local label = anim.Name .. " " .. track.Name
	if hasKeyword(label, Config.IgnoreKeywords) then return false end
	if hasKeyword(label, Config.AttackKeywords) then return true end
	return Config.ActionPriorityIsAttack and ACTION_PRIORITIES[track.Priority] == true and track.Length > 0.25
end

local function facingMe(eroot, flatTo)
	if not Config.RequireFacing then return true end
	if flatTo.Magnitude < 0.01 then return true end
	local look = flat(eroot.CFrame.LookVector)
	if look.Magnitude < 0.01 then return true end
	return look.Unit:Dot(flatTo.Unit) >= Config.FacingDot
end

-- линия атаки = куда смотрит враг; bias = в какую сторону от неё ты уже смещён
local function attackAxis(eroot, flatTo)
	local look = flat(eroot.CFrame.LookVector)
	if look.Magnitude < 0.01 then return flatTo, nil end
	look = look.Unit
	local perp = flatTo - look * flatTo:Dot(look)
	if perp.Magnitude < 0.5 then return look, nil end
	return look, perp.Unit
end

-- дистанция между вами к моменту удара (через t сек)
local function reachDistance(eroot, myRoot, t, current)
	if not Config.Anticipate then return current end
	t = math.min(t, 0.6)
	local ePos = eroot.Position + eroot.AssemblyLinearVelocity * t
	local mPos = myRoot.Position + myRoot.AssemblyLinearVelocity * t
	return flat(mPos - ePos).Magnitude
end

local function scanEnemy(model, eroot, myRoot, dt)
	local flatTo = flat(myRoot.Position - eroot.Position)
	local dist = flatTo.Magnitude
	local axis, bias = attackAxis(eroot, flatTo)

	if dist < curNearestDist then
		curNearest, curNearestDist = eroot, dist
	end

	-- движение: дэши, рывки, наскоки
	if Config.UseMovement then
		local mrec = enemyMotion[model]
		if not mrec then
			mrec = { pos = eroot.Position, fast = 0, cool = 0 }
			enemyMotion[model] = mrec
		end
		local ev = Vector3.zero
		if dt and dt > 0 then ev = (eroot.Position - mrec.pos) / dt end
		mrec.pos = eroot.Position
		local av = eroot.AssemblyLinearVelocity
		if av.Magnitude > ev.Magnitude then ev = av end

		local ehum = model:FindFirstChildOfClass("Humanoid")
		local walk = ehum and ehum.WalkSpeed or 16
		local fastMin = math.max(Config.DashMinSpeed, walk * Config.DashWalkMultiplier)
		local fv = flat(ev)

		if fv.Magnitude >= fastMin then
			mrec.fast = mrec.fast + 1
			if mrec.fast >= 2 and os.clock() >= mrec.cool then
				-- относительное движение: когда и как близко враг пройдёт рядом с тобой
				local d = flat(eroot.Position - myRoot.Position)
				local w = fv - flat(myRoot.AssemblyLinearVelocity)
				local ww = w:Dot(w)
				if ww > 1 then
					local t = -d:Dot(w) / ww
					if t > 0 and t <= Config.DashReactTime then
						local closest = d + w * t
						local sameHeight = math.abs(eroot.Position.Y - myRoot.Position.Y) < 10
						if sameHeight and closest.Magnitude <= Config.DashHitRadius then
							mrec.cool = os.clock() + Config.DashCooldown
							local line = fv.Unit
							local fromEnemy = -d
							local perp = fromEnemy - line * fromEnemy:Dot(line)
							local b = nil
							if perp.Magnitude > 0.5 then b = perp.Unit end
							requestDodge(line, true, b,
								string.format("рывок %s (%.0f studs/сек)", model.Name, fv.Magnitude))
						end
					end
				end
			end
		else
			mrec.fast = 0
		end
	end

	-- атрибуты
	if #Config.AttackAttributes > 0 then
		local st = attrState[model]
		if not st then
			st = {}
			attrState[model] = st
		end
		for _, name in ipairs(Config.AttackAttributes) do
			local v = model:GetAttribute(name) and true or false
			if v and not st[name] and dist <= Config.MeleeRange and facingMe(eroot, flatTo) then
				requestDodge(axis, true, bias, "атрибут " .. model.Name .. "." .. name)
			end
			st[name] = v
		end
	end

	-- анимации
	if not Config.UseAnimations then return end
	local animator = getAnimator(model)
	if not animator then return end

	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		local tp = track.TimePosition
		local rec = seenTracks[track]
		if not rec then
			rec = { handled = false, last = tp, attack = isAttackTrack(track) }
			seenTracks[track] = rec
		end
		if tp < rec.last - 0.05 then
			rec.handled = false -- анимацию запустили заново
		end
		rec.last = tp

		if rec.attack and not rec.handled then
			local id = track.Animation.AnimationId
			local hitTime, range = Config.DefaultHitTime, Config.MeleeRange
			local info = Config.AttackAnimIds[id]
			if type(info) == "number" then
				hitTime = info
			elseif type(info) == "table" then
				hitTime = info.Hit or hitTime
				range = info.Range or range
			end

			local speed = math.max(track.Speed, 0.1)
			local lead = Config.LeadTime * speed
			if tp >= hitTime - lead then
				rec.handled = true
				local remain = math.max(hitTime - tp, 0) / speed
				local reach = reachDistance(eroot, myRoot, remain, dist)
				if tp <= hitTime + 0.35 and reach <= range and facingMe(eroot, flatTo) then
					requestDodge(axis, true, bias,
						string.format("анимация %s (%s) %s, t=%.2f", track.Animation.Name, id, model.Name, tp))
				end
			end
		end
	end
end

--------------------------------------------------------------------
-- 3) СНАРЯДЫ И ЗОНЫ
--------------------------------------------------------------------
local function untrack(part)
	if tracked[part] then
		tracked[part] = nil
		trackedCount = trackedCount - 1
	end
end

local function onPartAdded(inst)
	if not inst:IsA("BasePart") then return end
	if tracked[inst] or trackedCount >= Config.MaxTracked then return end
	if inst.Size.Magnitude > Config.ProjectileMaxSize then return end
	if inst.Anchored and inst.CanCollide then return end -- похоже на статичную карту
	tracked[inst] = { born = os.clock(), pos = inst.Position, cool = 0, fast = 0, checked = false }
	trackedCount = trackedCount + 1
end

if Config.UseProjectiles then
	workspace.DescendantAdded:Connect(onPartAdded)
end

local function humanoidModelOf(part)
	local anc = part.Parent
	while anc and anc ~= workspace do
		if anc:IsA("Model") and anc:FindFirstChildOfClass("Humanoid") then return anc end
		anc = anc.Parent
	end
	return nil
end

local function isOwnPart(part)
	local char = player.Character
	if char and part:IsDescendantOf(char) then return true end
	local o = part:GetAttribute("Owner")
	if o ~= nil and (o == player.Name or o == player.UserId) then return true end
	local creator = part:FindFirstChild("creator")
	if creator and creator:IsA("ObjectValue") and creator.Value == player then return true end
	return false
end

local function insidePart(part, pos, margin)
	local rel = part.CFrame:PointToObjectSpace(pos)
	local h = part.Size / 2
	return math.abs(rel.X) <= h.X + margin
		and math.abs(rel.Y) <= h.Y + margin + 3
		and math.abs(rel.Z) <= h.Z + margin
end

-- первичная проверка нового Part: свой? чужой хитбокс внутри модели врага? союзник?
local function classifyPart(part, rec)
	rec.nameHit = hasKeyword(part.Name, Config.ThreatNameKeywords)
	if isOwnPart(part) then return false end
	if Config.ThreatFilter and not Config.ThreatFilter(part) then return false end

	local m = humanoidModelOf(part)
	if m then
		if not rec.nameHit then return false end -- обычная часть тела/аксессуар
		local p = Players:GetPlayerFromCharacter(m)
		if sameTeam(p) then return false end
		if Config.EnemyFilter and not Config.EnemyFilter(m) then return false end
		rec.inChar = true
	end
	return true
end

local function updateParts(dt, myRoot)
	local now = os.clock()
	local myPos = myRoot.Position

	for part, rec in pairs(tracked) do
		if not part.Parent or now - rec.born > Config.ProjectileLifetime then
			untrack(part)
		else
			local pos = part.Position
			local vel = Vector3.zero
			if dt > 0 then vel = (pos - rec.pos) / dt end
			rec.pos = pos

			if not rec.checked and now - rec.born > 0.05 then
				rec.checked = true
				if not classifyPart(part, rec) then
					rec.dead = true
					untrack(part)
				end
			end

			if rec.checked and not rec.dead and now >= rec.cool then
				local v = vel
				local av = part.AssemblyLinearVelocity
				if av.Magnitude > v.Magnitude then v = av end

				if not rec.inChar and v.Magnitude >= Config.ProjectileMinSpeed then
					rec.fast = rec.fast + 1
					if rec.fast >= 2 then
						local t = (myPos - pos):Dot(v) / (v.Magnitude * v.Magnitude)
						if t > 0 and t <= Config.ProjectileReactTime then
							local closest = pos + v * t
							local radius = part.Size.Magnitude / 2 + 3.5
							if (closest - myPos).Magnitude <= radius then
								rec.cool = now + 0.6
								requestDodge(v, false, nil, "снаряд " .. part.Name)
							end
						end
					end
				else
					rec.fast = 0
					if Config.UseZones and rec.nameHit and insidePart(part, myPos, 1.5) then
						rec.cool = now + 0.6
						requestDodge(myPos - pos, true, nil, "зона " .. part.Name)
					end
				end
			end
		end
	end
end

--------------------------------------------------------------------
-- РУЧНОЙ ВХОД: player.AutoDodgeThreat:Fire(позиция | Part | Model)
--------------------------------------------------------------------
do
	local old = player:FindFirstChild("AutoDodgeThreat")
	if old then old:Destroy() end
end

local threatEvent = Instance.new("BindableEvent")
threatEvent.Name = "AutoDodgeThreat"
threatEvent.Parent = player

threatEvent.Event:Connect(function(source, allowBack)
	safe(function()
		if not enabled then return end
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if not root then return end

		local pos
		if typeof(source) == "Vector3" then
			pos = source
		elseif typeof(source) == "Instance" then
			if source:IsA("BasePart") then
				pos = source.Position
			elseif source:IsA("Model") then
				pos = source:GetPivot().Position
			end
		end
		if pos then
			requestDodge(root.Position - pos, allowBack ~= false, nil, "внешний сигнал")
		end
	end)
end)

--------------------------------------------------------------------
-- ИНТЕРФЕЙС
--------------------------------------------------------------------
local playerGui = player:WaitForChild("PlayerGui")
do
	local old = playerGui:FindFirstChild("AutoDodgeUniversalGui")
	if old then old:Destroy() end
end

local gui = Instance.new("ScreenGui")
gui.Name = "AutoDodgeUniversalGui"
gui.ResetOnSpawn = false
gui.DisplayOrder = 50
gui.Parent = playerGui

local btn = Instance.new("TextButton")
btn.Name = "Toggle"
btn.Size = UDim2.fromOffset(110, 40)
btn.Position = Config.ButtonPosition
btn.AutoButtonColor = false
btn.Font = Enum.Font.GothamBold
btn.TextSize = 15
btn.TextColor3 = Color3.new(1, 1, 1)
btn.BorderSizePixel = 0
btn.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 10)
corner.Parent = btn

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.new(1, 1, 1)
stroke.Transparency = 0.7
stroke.Thickness = 1.5
stroke.Parent = btn

local function updateUi()
	if enabled then
		btn.Text = "DODGE: ON"
		btn.BackgroundColor3 = Color3.fromRGB(46, 130, 200)
	else
		btn.Text = "DODGE: OFF"
		btn.BackgroundColor3 = Color3.fromRGB(60, 60, 68)
	end
end

dodgeFlash = function()
	btn.Text = "DODGE!"
	task.delay(0.25, function()
		if btn.Parent then updateUi() end
	end)
end

local function setEnabled(v)
	v = v and true or false
	if enabled == v then return end
	enabled = v
	if not enabled then dodgeDir = nil end
	updateUi()
	if player:GetAttribute("AutoDodge") ~= v then
		player:SetAttribute("AutoDodge", v)
	end
end

player:GetAttributeChangedSignal("AutoDodge"):Connect(function()
	setEnabled(player:GetAttribute("AutoDodge"))
end)

-- перетаскивание кнопки; нажатие без движения = переключение
local dragging, moved, dragStart, startPos = false, false, nil, nil

btn.InputBegan:Connect(function(input)
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
		dragging, moved = true, false
		dragStart, startPos = input.Position, btn.Position

		local conn
		conn = input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				conn:Disconnect()
				dragging = false
				if not moved then
					setEnabled(not enabled)
				end
			end
		end)
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if not dragging then return end
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch then
		local delta = input.Position - dragStart
		if delta.Magnitude > 8 then moved = true end
		if moved then
			btn.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y
			)
		end
	end
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Config.Key then
		setEnabled(not enabled)
	end
end)

--------------------------------------------------------------------
-- ГЛАВНЫЙ ЦИКЛ
--------------------------------------------------------------------
local function tick(dt)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (hum and root) or hum.Health <= 0 then return end

	curNearest, curNearestDist = nil, math.huge
	if Config.UseAnimations or #Config.AttackAttributes > 0 or Config.UseMovement or Config.DodgeOnDamage then
		forEachEnemy(root, function(model, eroot)
			scanEnemy(model, eroot, root, dt)
		end)
	end
	lastNearest = curNearest

	if Config.UseProjectiles then
		updateParts(dt, root)
	end
end

RunService.Heartbeat:Connect(function(dt)
	if not enabled then return end
	safe(tick, dt)
end)

updateUi()
if Config.StartEnabled then
	setEnabled(true)
end
