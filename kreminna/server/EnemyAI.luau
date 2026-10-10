--[[
	Hostile riflemen. Server-side brains at 10 Hz; clients animate them from these attributes:
		State     Patrol | Alert | Draw | Aim | Search | Ready | Holster | Dead
		          (Ready = rifle in hand on safety, low-ready carry, still patrolling)
		StateAt   server time the state began (workspace:GetServerTimeNow())
		AimAt     world point they aim at / look toward
		Look      head yaw (radians) while looking around
		Suspicion 0..1 (shown as "?" above the head; 1 = noticed, "!")
		ShotAt    server time of the last shot (clients kick the rifle)

	Noticing: a player inside the view cone with line of sight fills suspicion, faster up close and
	when moving. Hearing a shot, a round passing close or a squad mate dropping adds to it and turns
	them toward the sound. Once noticed they shout, pull the rifle off their back, aim and fire.
	Shots are hitscan with travel time and a spread that tightens with every shot at the same target.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = ReplicatedStorage:WaitForChild("SniperKit")
local Config = require(Kit:WaitForChild("Config"))
local Poses = require(Kit:WaitForChild("EnemyPoses"))
local EnemyRig = require(script.Parent.EnemyRig)

local E = Config.Enemy
local T = Poses.Times

local EnemyAI = {}
EnemyAI.respawnHold = 0 -- os.clock() until which nobody respawns (KABOOM!)

local folder: Folder
local remotes
local npcs = {}
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local GROUND_Y = 0 -- top of the baseplate
local SUSPECT = 0.35 -- suspicion at which a soldier at work stops, pulls his rifle and looks about
local FIELD_RANGE = 620 -- studs: how far out a camp soldier can make you out at all
local DEBUG = game:GetService("ServerStorage"):FindFirstChild("SnipersTestMarker") ~= nil

local function now(): number
	return workspace:GetServerTimeNow()
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function setState(n, state: string)
	if n.state == state then
		return
	end
	if DEBUG then
		print(string.format("[Snipers] npc%d %s -> %s (sus %.2f, seen %.1fs ago)", n.index, n.state, state, n.suspicion, now() - (n.lastSeenAt or 0)))
	end
	n.state = state
	n.stateAt = now()
	n.model:SetAttribute("State", state)
	n.model:SetAttribute("StateAt", n.stateAt)
end

-- voice lines: Spot, Fire, Hit, Death, Search, Clear (clients pick the clip and the soldier's pitch)
local function say(n, line: string, chance: number?)
	local t = os.clock()
	if (n.saidAt or 0) > t - 2.2 or (chance and math.random() > chance) then
		return
	end
	n.saidAt = t
	remotes.EnemyVoice:FireAllClients(n.model, line)
end

local function face(n, point: Vector3?)
	local hrp = n.hrp
	if point then
		local d = flat(point - hrp.Position)
		if d.Magnitude > 0.1 then
			n.hum.AutoRotate = false
			n.align.CFrame = CFrame.lookAt(Vector3.zero, d.Unit)
			n.align.Enabled = true
		end
	else
		n.align.Enabled = false
		n.hum.AutoRotate = true
	end
end

local function stop(n)
	n.hum:MoveTo(n.hrp.Position)
	n.moving = false
end

local function walkTo(n, p: Vector3, speed: number)
	n.hum.WalkSpeed = speed
	face(n, nil)
	n.hum:MoveTo(Vector3.new(p.X, if n.field then p.Y else GROUND_Y, p.Z))
	n.moving = true
end

-- the path -----------------------------------------------------------------------------------------

-- waypoints come from Workspace.Path (parts named WP1, WP2, ... that can be moved in Studio),
-- or Config.Enemy.Path when that folder is missing. A dirt strip is laid along them at runtime.
local path: { Vector3 } = {}

local function loadPath()
	path = {}
	local f = workspace:FindFirstChild("Path")
	if f then
		local wps = {}
		for _, c in f:GetChildren() do
			local num = tonumber(string.match(c.Name, "^WP(%d+)$"))
			if num and c:IsA("BasePart") then
				table.insert(wps, { num, c })
			end
		end
		table.sort(wps, function(x, y)
			return x[1] < y[1]
		end)
		for _, w in wps do
			local p = w[2] :: BasePart
			table.insert(path, Vector3.new(p.Position.X, GROUND_Y, p.Position.Z))
			p.Transparency = 1
			p.CanCollide = false
			p.CanQuery = false
			for _, d in p:GetDescendants() do
				if d:IsA("BillboardGui") or d:IsA("SurfaceGui") then
					d.Enabled = false
				end
			end
		end
	end
	if #path < 2 then
		path = {}
		for _, p in E.Path do
			table.insert(path, Vector3.new(p.X, GROUND_Y, p.Z))
		end
	end
end

local function buildStrip()
	local holder = workspace:FindFirstChild("Path")
	if not holder then
		holder = Instance.new("Folder")
		holder.Name = "Path"
		holder.Parent = workspace
	end
	local old = holder:FindFirstChild("Strip")
	if old then
		old:Destroy()
	end
	local strip = Instance.new("Folder")
	strip.Name = "Strip"
	local W = E.PathWidth
	local function piece(size: Vector3, cf: CFrame, shape: Enum.PartType?)
		local p = Instance.new("Part")
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Ground
		p.Color = Color3.fromRGB(112, 94, 68)
		p.Size = size
		p.CFrame = cf
		if shape then
			p.Shape = shape
		end
		p.Parent = strip
	end
	for i, a in path do
		local b = path[(i % #path) + 1]
		local mid = (a + b) / 2
		local lift = Vector3.new(0, 0.06, 0)
		piece(Vector3.new(W, 0.12, (b - a).Magnitude), CFrame.lookAt(mid + lift, b + lift))
		piece(Vector3.new(0.12, W, W), CFrame.new(a + Vector3.new(0, 0.061, 0)) * CFrame.Angles(0, 0, math.rad(90)), Enum.PartType.Cylinder)
	end
	strip.Parent = holder
end

-- spawning ---------------------------------------------------------------------------------------

local spawnNpc

local function onDied(n)
	say(n, "Death")
	setState(n, "Dead")
	n.dead = true
	n.align.Enabled = false
	EnemyRig.ragdoll(n.model)
	if n.field then
		-- the camp's men don't come back; the body lies there a while
		task.delay(90, function()
			if n.model then
				n.model:Destroy()
			end
		end)
		return
	end
	task.delay(E.Respawn, function()
		-- (not while KABOOM!'s aftermath is on: nobody walks out of that)
		while os.clock() < EnemyAI.respawnHold do
			task.wait(1)
		end
		if n.model then
			n.model:Destroy()
		end
		spawnNpc(n.index)
	end)
end

function spawnNpc(index: number)
	local sq = E.Squad[index]
	local i0 = ((sq.start - 1) % #path) + 1
	local i1 = ((i0 - 1 + sq.dir) % #path) + 1
	local a, b = path[i0], path[i1]
	local right = flat(b - a).Unit:Cross(Vector3.yAxis) * E.KeepRight
	local feet = CFrame.lookAt(a + right, b + right)
	-- every soldier looks different from the others that are alive
	local taken = {}
	for _, o in npcs do
		if not o.dead and o.model then
			taken[o.model:GetAttribute("Outfit") or ""] = true
		end
	end
	-- seeded per soldier: Random.new() objects made in the same instant share a seed (identical twins)
	local seed = math.floor(math.random(1, 2 ^ 30) + index * 7919 + os.clock() * 1000)
	local model = EnemyRig.build("Hostile", feet, Random.new(seed), taken)
	local n = register(model, index, false)
	n.wp = i1
	n.dir = sq.dir
end

-- a brain for a soldier model (built here, or handed over: off the back of a truck)
function register(model: Model, index: number, field: boolean)
	local n = {
		index = index,
		field = field,
		model = model,
		hrp = model:FindFirstChild("HumanoidRootPart") :: BasePart,
		head = model:FindFirstChild("Head") :: BasePart,
		hum = model:FindFirstChildOfClass("Humanoid") :: Humanoid,
		align = (model:FindFirstChild("HumanoidRootPart") :: BasePart):FindFirstChild("Facing") :: AlignOrientation,
		wp = 1,
		dir = 1,
		pauseUntil = 0,
		lookPlan = {},
		state = "",
		stateAt = 0,
		suspicion = 0,
		target = nil :: Player?,
		lastSeenPos = nil :: Vector3?,
		lastSeenAt = 0,
		shots = 0,
		nextShot = 0,
		dead = false,
		hearAt = nil :: Vector3?,
		meetReadyAt = now() + 8,
	}
	n.hum.MaxHealth = E.Health
	n.hum.Health = E.Health
	model:SetAttribute("Suspicion", 0)
	model:SetAttribute("Look", 0)
	model:SetAttribute("AimAt", n.hrp.Position + n.hrp.CFrame.LookVector * 50)
	model:SetAttribute("ShotAt", 0)
	model:SetAttribute("Target", 0)
	setState(n, "Patrol")
	model.Parent = folder
	n.hrp:SetNetworkOwner(nil)
	n.hum.Died:Once(function()
		onDied(n)
	end)
	npcs[index] = n
	return n
end

-- perception ---------------------------------------------------------------------------------------

local function visibleParts(n, char: Model): (boolean, Vector3?)
	local eye = n.head.Position + Vector3.new(0, 0.1, 0)
	rayParams.FilterDescendantsInstances = { folder }
	-- crouched or prone the body is lowered but the (invisible) root box still stands: don't count it
	local pl = Players:GetPlayerFromCharacter(char)
	local down = pl and (pl:GetAttribute("Stance") or "stand") ~= "stand"
	for _, name in (if down then { "Head", "UpperTorso", "LowerTorso" } else { "Head", "UpperTorso", "Torso", "HumanoidRootPart" }) do
		local p = char:FindFirstChild(name) :: BasePart?
		if p then
			local r = workspace:Raycast(eye, p.Position - eye, rayParams)
			if r and r.Instance:IsDescendantOf(char) then
				return true, p.Position
			end
		end
	end
	return false, nil
end

local function aliveChar(p: Player): (Model?, Humanoid?)
	local c = p.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	if c and h and h.Health > 0 and c:FindFirstChild("HumanoidRootPart") then
		return c, h
	end
	return nil, nil
end

local function facingDir(n): Vector3
	local look = n.model:GetAttribute("Look") or 0
	return (n.hrp.CFrame * CFrame.Angles(0, look, 0)).LookVector
end

-- how much harder this man is to make out (Config.Economy.Concealment): the ghillie suit (more so lying
-- down), a deployed ghillie bush close by, a sandbag wall close by when he is down behind it. Multiplies
-- the spotting rate; walls and bushes in the way also block the sight line itself (they are parts)
local CON = Config.Economy and Config.Economy.Concealment
function EnemyAI.concealment(p: Player, pos: Vector3, stance: any): number
	if not CON then
		return 1
	end
	local k = 1
	if p:GetAttribute("Ghillie") then
		k *= CON.Ghillie
		if stance == "prone" then
			k *= CON.GhillieProne
		end
	end
	local dep = workspace:FindFirstChild("Deployables")
	if dep then
		local nearBush, nearBags = false, false
		for _, m in dep:GetChildren() do
			local c = m:GetAttribute("Centre")
			if typeof(c) == "Vector3" then
				local flat = Vector3.new(c.X - pos.X, 0, c.Z - pos.Z).Magnitude
				local kind = m:GetAttribute("Kind")
				if kind == "bush" and flat < CON.BushRadius then
					nearBush = true
				elseif kind == "sandbag" and flat < CON.SandbagRadius and stance ~= "stand" and stance ~= nil then
					nearBags = true
				end
			end
		end
		if nearBush then
			k *= CON.Bush
		end
		if nearBags then
			k *= CON.Sandbags
		end
	end
	return k
end

-- the fight is on: one of them is up and engaging someone, or a shot was fired not long ago. Men posted
-- up on the roofs (Perch) hold their fire and say nothing until then: they don't start it
local lastShotAt = -math.huge
local function fightOn(): boolean
	if now() - lastShotAt < 90 then
		return true
	end
	for _, o in npcs do
		if not o.dead and not o.model:GetAttribute("Perch") and (o.state == "Alert" or o.state == "Aim" or (o.state == "Draw" and not o.confused)) then
			return true
		end
	end
	return false
end

local function perceive(n, dt: number)
	if n.model:GetAttribute("Perch") and not fightOn() then
		n.suspicion = math.max(0, n.suspicion - 0.2 * dt)
		n.model:SetAttribute("Suspicion", math.floor(n.suspicion * 50 + 0.5) / 50)
		return false
	end
	local best, bestScore, bestPos = nil, 0, nil
	for _, p in Players:GetPlayers() do
		local char = aliveChar(p)
		if char then
			local root = char:FindFirstChild("HumanoidRootPart") :: BasePart
			local to = root.Position - n.head.Position
			local dist = to.Magnitude
			local range = if n.field then FIELD_RANGE else E.ViewRange
			if dist < range then
				local engaged = n.target == p and (n.state == "Aim" or n.state == "Draw" or n.state == "Alert")
				local ang = math.acos(math.clamp(flat(facingDir(n)):Dot(flat(to).Unit), -1, 1))
				if engaged or dist < 25 or ang < E.Fov then
					local vis, pos = visibleParts(n, char)
					if vis then
						local rate
						if n.field then
							-- out in the forest a still man far off is hard to make out: you should see
							-- them well before they see you. Close up, moving, standing in the open: quick.
							rate = 1.1 * (1 - dist / range) ^ 2.6 + (dist < 40 and 1.5 or 0)
						else
							rate = 0.9 * (1 - dist / E.ViewRange) ^ 1.8 + (dist < 60 and 2 or 0)
						end
						local speed = root.AssemblyLinearVelocity.Magnitude
						if speed > 17 then
							rate *= 2.2 -- running
						elseif speed > 4 then
							rate *= 1.5
						end
						local stance = p:GetAttribute("Stance")
						if stance == "crouch" then
							rate *= if n.field then 0.5 else 0.6
						elseif stance == "prone" then
							rate *= if n.field then 0.22 else 0.3
						end
						if ang > E.Fov * 0.55 then
							rate *= 0.4 -- the corner of his eye
						end
						rate *= EnemyAI.concealment(p, pos, stance)
						if engaged then
							rate = 10
						end
						if rate > bestScore then
							best, bestScore, bestPos = p, rate, pos
						end
					end
				end
			end
		end
	end
	if best then
		n.suspicion = math.min(1, n.suspicion + bestScore * dt)
		n.suspectPos = bestPos
		if n.suspicion >= 1 then
			n.target = best
			n.lastSeenPos = bestPos
			n.lastSeenAt = now()
		end
	else
		local decay = (n.state == "Patrol" or n.state == "Ready") and 0.12 or 0.04
		n.suspicion = math.max(0, n.suspicion - decay * dt)
	end
	n.model:SetAttribute("Suspicion", math.floor(n.suspicion * 50 + 0.5) / 50)
	return best ~= nil
end

local function alert(n, target: Player?, pos: Vector3?)
	if n.dead then
		return
	end
	n.suspicion = 1
	if target then
		n.target = target
		n.model:SetAttribute("Target", target.UserId)
	end
	if pos then
		n.lastSeenPos = pos
		n.lastSeenAt = now()
	end
	if n.state == "Patrol" or n.state == "Holster" or n.state == "Search" or n.state == "Ready" then
		if n.onConfused then
			n.onConfused(n) -- up off the crate, cards away
		end
		stop(n)
		n.shots = 0
		n.targetLostAt = nil
		say(n, "Spot")
		if n.state == "Search" or n.state == "Ready" then
			setState(n, "Aim") -- rifle already in hand: just bring it up
			n.nextShot = now() + T.Raise + T.Settle
			if n.model:GetAttribute("Perch") then
				n.nextShot += 2.5 -- (a long shot off a roof: he takes his time)
			end
		else
			setState(n, "Alert")
		end
		-- the men at his table are up with him, looking where he is looking (each still has to
		-- see you for himself before he fires)
		if n.group and pos then
			for _, o in n.group do
				if o ~= n and not o.dead and (o.state == "Patrol" or o.state == "Ready") then
					o.suspicion = math.max(o.suspicion, 0.75)
					confuse(o, pos)
				end
			end
		end
	end
end

-- shooting -----------------------------------------------------------------------------------------

local function gauss(): number
	return math.sqrt(-2 * math.log(math.max(math.random(), 1e-6))) * math.cos(2 * math.pi * math.random())
end

-- can't be hurt (Config.Invincible): the place's owner, Studio, listed UserIds; and nobody while KABOOM!
-- plays (watching the cutscene, then waiting for it to land)
local function invincible(p: Player): boolean
	if p:GetAttribute("Nuked") then
		return true
	end
	local I = Config.Invincible
	if not I then
		return false
	end
	return (I.studio and RunService:IsStudio())
		or (I.owner and game.CreatorType == Enum.CreatorType.User and p.UserId == game.CreatorId)
		or I.users[p.UserId] == true
end

local function regionOf(name: string): string
	if name == "Head" or name == "Helmet" then
		return "head"
	elseif name == "UpperTorso" or name == "LowerTorso" or name == "Torso" or name == "HumanoidRootPart" then
		return "torso"
	end
	return "limb"
end

local function fire(n, char: Model)
	local hrp = n.hrp
	local cf = hrp.CFrame
	local origin = (cf * CFrame.new(Poses.Eye + Vector3.new(0, -0.05, -3.1))).Position
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart
	local aimPart = (math.random() < 0.15 and char:FindFirstChild("Head") or char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso") or root) :: BasePart
	local aim = aimPart.Position
	local dist = (aim - origin).Magnitude
	-- lead a moving target a little (imperfectly)
	aim += root.AssemblyLinearVelocity * (dist / E.Velocity) * 0.6
	local sigma = 0.0032 + 0.011 * math.exp(-0.65 * n.shots)
	if root.AssemblyLinearVelocity.Magnitude > 4 then
		sigma += 0.004
	end
	local dir = CFrame.lookAt(origin, aim) * CFrame.Angles(gauss() * sigma, gauss() * sigma, 0)
	local ray = dir.LookVector * 3000
	rayParams.FilterDescendantsInstances = { folder }
	local result = workspace:Raycast(origin, ray, rayParams)
	local hitPos = result and result.Position or origin + ray
	local normal = result and result.Normal or Vector3.yAxis
	local hitPlayer: Player? = nil
	local hitHum: Humanoid? = nil
	local region = "torso"
	if result then
		local model = result.Instance:FindFirstAncestorOfClass("Model")
		local hum = model and model:FindFirstChildOfClass("Humanoid")
		local pl = model and Players:GetPlayerFromCharacter(model)
		if hum and pl then
			hitPlayer, hitHum = pl, hum
			region = regionOf(result.Instance.Name)
		end
	end
	n.shots += 1
	n.model:SetAttribute("ShotAt", now())
	remotes.EnemyShot:FireAllClients(n.model, origin, hitPos, normal, hitPlayer and hitPlayer.UserId or 0, result and result.Material or Enum.Material.Air)
	local travel = (hitPos - origin).Magnitude / E.Velocity
	if hitPlayer and hitHum and not invincible(hitPlayer) then
		local dmg = E.Damage[region]
		task.delay(travel, function()
			if hitHum.Health > 0 then
				hitHum:TakeDamage(dmg)
				remotes.PlayerHit:FireClient(hitPlayer, dmg, origin, region, math.floor(dist * Config.MetersPerStud + 0.5))
			end
		end)
	end
end

-- brains -------------------------------------------------------------------------------------------

local function wrap(i: number): number
	return ((i - 1) % #path) + 1
end

-- the point he is walking to: the waypoint, shifted to the right of his direction of travel
local function pathPoint(n): Vector3
	local p = path[n.wp]
	local prev = path[wrap(n.wp - n.dir)]
	local d = flat(p - prev)
	if d.Magnitude < 0.1 then
		return p
	end
	return p + d.Unit:Cross(Vector3.yAxis) * E.KeepRight
end

local function gesture(n, kind: string)
	n.model:SetAttribute("Gesture", kind)
	n.model:SetAttribute("GestureAt", now())
end

-- two soldiers meet face to face: both stop, one talks, the other nods (and maybe answers)
local function meet(a, b, t: number)
	if math.random() < 0.5 then
		a, b = b, a
	end
	for _, n in { a, b } do
		local other = n == a and b or a
		stop(n)
		face(n, other.hrp.Position)
		n.model:SetAttribute("Look", 0)
		n.model:SetAttribute("AimAt", other.head.Position)
		n.pauseUntil = t + 3.6
		n.lookPlan = {}
		n.meetReadyAt = t + E.MeetCooldown
	end
	say(a, "Greet")
	gesture(a, "talk")
	task.delay(0.9, function()
		if not b.dead then
			gesture(b, "nod")
		end
	end)
	task.delay(1.6, function()
		if not b.dead and math.random() < 0.6 then
			say(b, "Reply")
			gesture(b, "talk")
		end
	end)
end

local function tryMeet(n, t: number): boolean
	if t < (n.meetReadyAt or 0) then
		return false
	end
	local look = flat(n.hrp.CFrame.LookVector)
	for _, o in npcs do
		if o ~= n and not o.dead and (o.state == "Patrol" or o.state == "Ready") and t >= (o.meetReadyAt or 0) and t >= o.pauseUntil then
			local to = flat(o.hrp.Position - n.hrp.Position)
			if to.Magnitude < E.MeetDistance and to.Magnitude > 0.5 then
				local olook = flat(o.hrp.CFrame.LookVector)
				if look.Magnitude > 0.1 and olook.Magnitude > 0.1 and look.Unit:Dot(olook.Unit) < -0.3 and to.Unit:Dot(look.Unit) > 0.4 then
					meet(n, o, t)
					return true
				end
			end
		end
	end
	return false
end

local function patrol(n, t: number)
	if n.suspicion > 0.3 and n.suspectPos then
		-- something caught their eye: stop and stare at it
		stop(n)
		face(n, n.suspectPos)
		n.model:SetAttribute("Look", 0)
		n.model:SetAttribute("AimAt", n.suspectPos)
		n.pauseUntil = t + 1.5
		return
	end
	if n.hearAt then
		stop(n)
		face(n, n.hearAt)
		n.model:SetAttribute("AimAt", n.hearAt)
		n.pauseUntil = t + 3
		n.hearAt = nil
		return
	end
	if t < n.pauseUntil then
		-- stopped: looking around at a bend (meetings leave lookPlan empty, so they keep eye contact)
		local plan = n.lookPlan
		if plan.nextAt and t >= plan.nextAt then
			plan.nextAt = t + 1.2 + math.random() * 1.6
			if math.random() < 0.35 then
				face(n, n.hrp.Position + Vector3.new(math.random(-30, 30), 0, 100))
				n.model:SetAttribute("Look", 0)
			else
				n.model:SetAttribute("Look", (math.random() - 0.5) * 2.2)
			end
		end
		return
	end
	n.model:SetAttribute("Look", 0)
	if tryMeet(n, t) then
		return
	end
	local target = pathPoint(n)
	local d = flat(target - n.hrp.Position).Magnitude
	if d < 2.5 then
		if math.random() < 0.3 then
			-- stop at this bend for a look around
			stop(n)
			n.pauseUntil = t + 3 + math.random() * 3
			n.lookPlan = { nextAt = t + 0.6 }
		end
		n.wp = wrap(n.wp + n.dir)
		return
	end
	walkTo(n, target, E.WalkSpeed)
	n.model:SetAttribute("AimAt", n.hrp.Position + flat(target - n.hrp.Position).Unit * 50 + Vector3.new(0, 2, 0))
end

local function engaged(n, t: number, sees: boolean)
	local char = n.target and aliveChar(n.target)
	local st = n.state
	local age = t - n.stateAt
	if char then
		local root = char:FindFirstChild("HumanoidRootPart") :: BasePart
		if sees then
			n.lastSeenPos = root.Position
			n.lastSeenAt = t
		end
		local look = n.lastSeenPos or root.Position
		face(n, look)
		n.model:SetAttribute("AimAt", sees and (root.Position + Vector3.new(0, 1.2, 0)) or look)
	end
	if st == "Alert" then
		if age >= T.Alert then
			setState(n, "Draw")
		end
	elseif st == "Draw" then
		if age >= T.Draw then
			setState(n, "Aim")
			n.nextShot = t + T.Settle + math.random() * 0.4
			if n.model:GetAttribute("Perch") then
				n.nextShot += 2.5
			end
			say(n, "Fire", 0.5)
		end
	elseif st == "Aim" then
		if not char then
			-- target down (or gone): keep the rifle on him a moment, then safety on, low ready
			n.targetLostAt = n.targetLostAt or t
			if t - n.targetLostAt > 3.5 then
				n.target = nil
				n.suspicion = 0
				n.targetLostAt = nil
				n.model:SetAttribute("Target", 0)
				say(n, "Clear")
				setState(n, "Ready")
				n.readyUntil = t + 90
				n.pauseUntil = t + 2
				n.lookPlan = { nextAt = t + 0.5 }
			end
			return
		end
		if sees and t >= n.nextShot then
			fire(n, char)
			n.nextShot = t + E.FireInterval[1] + math.random() * (E.FireInterval[2] - E.FireInterval[1])
		end
		if not sees and t - n.lastSeenAt > 5 then
			setState(n, "Search")
			say(n, "Search")
			n.searchUntil = t + 12
			local toward = n.lastSeenPos and flat(n.lastSeenPos - n.hrp.Position) or Vector3.zero
			n.searchPos = n.hrp.Position + (toward.Magnitude > 1 and toward.Unit * 30 or Vector3.zero)
		end
	end
end

local function search(n, t: number, sees: boolean)
	if sees and n.target then
		setState(n, "Aim")
		n.nextShot = t + T.Settle
		return
	end
	-- (a man posted up on a roof searches from where he is: he doesn't walk off the edge)
	if n.searchPos and flat(n.searchPos - n.hrp.Position).Magnitude > 3 and not n.model:GetAttribute("Perch") then
		walkTo(n, n.searchPos, E.SearchSpeed)
		n.model:SetAttribute("AimAt", n.searchPos + Vector3.new(0, 2, 0))
	else
		stop(n)
		n.model:SetAttribute("Look", math.sin(t * 0.9) * 1.1)
	end
	if t > (n.searchUntil or 0) then
		n.target = nil
		n.suspicion = 0
		n.model:SetAttribute("Target", 0)
		setState(n, "Ready")
		n.readyUntil = t + 60
		n.pauseUntil = t + 1
		n.lookPlan = { nextAt = t + 0.3 }
	end
end

local function step(n, dt: number)
	if n.dead or not n.model.Parent then
		return
	end
	local t = now()
	local sees = perceive(n, dt)
	local st = n.state
	if st == "Draw" and n.confused then
		-- heard something, saw nothing: rifle off the back, then hold it ready and look about
		face(n, n.confusedAt)
		if t - n.stateAt >= T.Draw then
			setState(n, "Ready")
			n.pauseUntil = t + 1
			n.lookPlan = { nextAt = t + 0.5 }
		end
		return
	end
	if st == "Patrol" or st == "Ready" then
		if n.suspicion >= 1 then
			n.confused = false
			alert(n, n.target, n.lastSeenPos)
		elseif st == "Patrol" and n.job and n.suspicion >= SUSPECT and n.suspectPos then
			-- caught a glimpse of something: up off his seat, rifle out, looking that way and about.
			-- The men at his table get up with him.
			confuse(n, n.suspectPos)
			if n.group then
				for _, o in n.group do
					if o ~= n and not o.dead and o.state == "Patrol" then
						o.suspicion = math.max(o.suspicion, n.suspicion * 0.8)
						confuse(o, n.suspectPos)
					end
				end
			end
		elseif st == "Ready" and t > (n.readyUntil or 0) and n.suspicion < 0.05 then
			-- a long quiet spell: sling it again
			stop(n)
			setState(n, "Holster")
		elseif n.job and st == "Ready" then
			-- confused: stay put, rifle ready, eyes on where it came from, then all around
			stop(n)
			local plan = n.lookPlan
			if not plan.nextAt or t >= plan.nextAt then
				n.lookPlan = { nextAt = t + 1.4 + math.random() * 2 }
				if n.confusedAt and math.random() < 0.5 then
					face(n, n.confusedAt)
					n.model:SetAttribute("Look", (math.random() - 0.5) * 0.6)
				else
					n.model:SetAttribute("Look", (math.random() - 0.5) * 2.4)
				end
			end
		elseif n.job then
			n.job(n, t)
		else
			patrol(n, t)
		end
	elseif st == "Alert" or st == "Draw" or st == "Aim" then
		engaged(n, t, sees and n.suspicion >= 1)
	elseif st == "Search" then
		search(n, t, sees and n.suspicion >= 1)
	elseif st == "Holster" then
		face(n, nil)
		if t - n.stateAt >= T.Holster then
			setState(n, "Patrol")
			n.confused = false
			n.pauseUntil = t + 1
			n.lookPlan = { nextAt = t + 0.3 }
		end
	end
end

-- soldiers with a job (the camp): a shot they hear but can't place makes them stop what they're
-- doing, pull the rifle and look about; quiet for a while and they go back to it
function confuse(n, origin: Vector3)
	if not n.job then
		return
	end
	local t = now()
	n.confusedAt = origin
	if n.state == "Patrol" then
		if n.onConfused then
			n.onConfused(n) -- stand up, put the crate down
		end
		stop(n)
		n.confused = true
		say(n, "Search", 0.5)
		setState(n, "Draw")
	end
	n.readyUntil = math.max(n.readyUntil or 0, t + 30 + math.random() * 20)
end

-- events from the rest of the server -----------------------------------------------------------------

-- where he thinks a shot came from: roughly that way, less sure the farther off it was
function guess(n, origin: Vector3): Vector3
	local err = (origin - n.head.Position).Magnitude * 0.18 * math.random()
	local a = math.random() * math.pi * 2
	return origin + Vector3.new(math.cos(a), 0, math.sin(a)) * err
end

-- a player fired: everyone in earshot turns toward it; a round passing close is a giveaway
function EnemyAI.onPlayerShot(player: Player, origin: Vector3, dir: Vector3)
	lastShotAt = now()
	-- the round stops at the first soldier it passes close to; only he gets the near miss
	local closest, closestAlong = nil, math.huge
	for _, n in npcs do
		if not n.dead then
			local rel = n.head.Position - origin
			local along = rel:Dot(dir)
			if along > 0 and along < closestAlong and (rel - dir * along).Magnitude < 18 then
				closest, closestAlong = n, along
			end
		end
	end
	for _, n in npcs do
		if not n.dead then
			if n == closest and not n.field then
				alert(n, player, origin)
			elseif n == closest then
				-- a round cracked past him: he knows roughly where from and is looking hard that way,
				-- but he still has to see you (stay in the open and he will, quickly)
				n.suspicion = math.max(n.suspicion, 0.8)
				n.hearAt = guess(n, origin)
				if n.state == "Patrol" or n.state == "Ready" or (n.state == "Draw" and n.confused) then
					confuse(n, n.hearAt)
				else
					face(n, n.hearAt)
				end
			elseif n.state == "Patrol" or n.state == "Ready" or (n.state == "Draw" and n.confused) then
				local d = (n.head.Position - origin).Magnitude
				if d < 2600 then
					n.suspicion = math.min(0.6, n.suspicion + (d < 900 and 0.3 or 0.15))
					n.hearAt = guess(n, origin)
					confuse(n, n.hearAt)
				end
			end
		end
	end
end

-- a player's round hit one of them
function EnemyAI.onHit(model: Model, player: Player, killed: boolean, origin: Vector3?)
	for _, n in npcs do
		if not n.dead then
			if n.model == model and not killed then
				say(n, "Hit")
				alert(n, player, origin)
			elseif killed and (n.hrp.Position - model:GetPivot().Position).Magnitude < 800 then
				-- a squad mate dropped: they know roughly which way it came from, not where you are;
				-- up, rifles out, looking for you
				if n.state == "Patrol" or n.state == "Ready" then
					n.suspicion = math.max(n.suspicion, 0.55)
					if origin then
						n.hearAt = guess(n, origin)
						confuse(n, n.hearAt)
					end
				end
			end
		end
	end
end

function EnemyAI.isEnemy(model: Model): boolean
	return model.Parent == folder
end

function EnemyAI.init(remoteTable, rangeFolder: Folder)
	remotes = remoteTable
	folder = Instance.new("Folder")
	folder.Name = "Enemies"
	folder.Parent = rangeFolder
	if Config.isField() then
		-- the Trenches place: CampLife puts the garrison in (spawnAt / adopt), the brains run here
		startLoop()
		return
	end
	if not E.Enabled then
		-- switched off in Config.Enemy.Enabled: nothing spawns, the code stays ready
		print("[Snipers] field soldiers are switched off (Config.Enemy.Enabled = false)")
		return
	end
	loadPath()
	buildStrip()
	for i in E.Squad do
		spawnNpc(i)
	end
	startLoop()
end

-- the camp (Trenches place) -------------------------------------------------------------------------

local nextIndex = 1000

-- a soldier standing at feet with a job (job(n, t) runs while he is calm)
function EnemyAI.spawnAt(feet: CFrame, job, rng: Random?)
	nextIndex += 1
	local taken = {}
	for _, o in npcs do
		if not o.dead and o.model then
			taken[o.model:GetAttribute("Outfit") or ""] = true
		end
	end
	local model = EnemyRig.build("Hostile", feet, rng or Random.new(nextIndex * 7919 + math.random(1, 99999)), taken)
	local n = register(model, nextIndex, true)
	n.job = job
	return n
end

-- take over a soldier model that was riding (off the back of a truck)
function EnemyAI.adopt(model: Model, job)
	nextIndex += 1
	local hrp = model:FindFirstChild("HumanoidRootPart") :: BasePart
	hrp.Anchored = false
	model:SetAttribute("Pose", nil)
	local n = register(model, nextIndex, true)
	n.job = job
	return n
end

-- stop thinking for him (he climbed into a truck)
function EnemyAI.release(n)
	npcs[n.index] = nil
	n.align.Enabled = false
	n.hrp.Anchored = true
end

-- the camp has been warned (a truck crew radioed in): everyone not already fighting stops what he
-- is doing, pulls his rifle and looks about, towards where it was
function EnemyAI.alarmAt(pos: Vector3)
	for _, n in npcs do
		if not n.dead and (n.state == "Patrol" or n.state == "Ready") then
			n.suspicion = math.max(n.suspicion, 0.6)
			n.hearAt = pos
			confuse(n, pos)
		end
	end
end

-- is anyone in the camp fighting or hunting right now?
function EnemyAI.alarm(): boolean
	for _, n in npcs do
		if not n.dead and (n.state == "Alert" or n.state == "Aim" or n.state == "Search" or (n.state == "Draw" and not n.confused)) then
			return true
		end
	end
	return false
end

function startLoop()
	task.spawn(function()
		local last = os.clock()
		while true do
			task.wait(0.1)
			local t = os.clock()
			local dt = t - last
			last = t
			for _, n in npcs do
				local ok, err = pcall(step, n, dt)
				if not ok then
					warn("[Snipers] enemy AI error:", err)
				end
			end
		end
	end)
end

EnemyAI.npcs = npcs
EnemyAI.util = { walkTo = walkTo, stop = stop, face = face, gesture = gesture, setState = setState, say = say, now = now }
return EnemyAI
