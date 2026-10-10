--[[
	Rounds fly with muzzle velocity and gravity, raycast in 1/120 s sub-steps, so long shots
	drop and take time to arrive. The shooter's client resolves impacts and reports them;
	the server validates them against the recorded shot.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = ReplicatedStorage:WaitForChild("SniperKit")
local Config = require(Kit:WaitForChild("Config"))
local Util = require(script.Parent.Util)
local Effects = require(script.Parent.Effects)
local Audio = require(script.Parent.Audio)

local Ballistics = {}
Ballistics.Impact = Util.signal() -- (info)
Ballistics.excluded = {} :: { Instance }

local remotes
local bullets = {}
local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude

local function materialKind(m: Enum.Material): string
	if m == Enum.Material.Metal or m == Enum.Material.DiamondPlate or m == Enum.Material.CorrodedMetal then
		return "metal"
	elseif m == Enum.Material.Wood or m == Enum.Material.WoodPlanks then
		return "wood"
	end
	return "dirt"
end

local function refreshFilter()
	local list = { Effects.folder }
	local char = Players.LocalPlayer.Character
	if char then
		table.insert(list, char)
	end
	for _, x in Ballistics.excluded do
		table.insert(list, x)
	end
	-- the squad's own sandbag walls and bushes: cover against the soldiers, not something to shoot into
	-- (you fire over and past them)
	local dep = workspace:FindFirstChild("Deployables")
	if dep then
		table.insert(list, dep)
	end
	params.FilterDescendantsInstances = list
end

-- local = true for the player's own rounds (reported to the server, traced)
function Ballistics.fire(origin: Vector3, direction: Vector3, rifle, isLocal: boolean)
	refreshFilter()
	table.insert(bullets, {
		origin = origin,
		pos = origin,
		vel = direction.Unit * rifle.velocity,
		age = 0,
		rifle = rifle,
		isLocal = isLocal,
		-- (your own rounds: the way they flew, for the bullet-cam)
		path = if isLocal then { origin } else nil,
	})
end

local function isSteel(part: BasePart): boolean
	return string.sub(part.Name, 1, 5) == "Steel"
end

local function onImpact(b, result: RaycastResult)
	local part = result.Instance :: BasePart
	local pos = result.Position
	local dist = (pos - b.origin).Magnitude
	local model = part:FindFirstAncestorOfClass("Model")
	local hum = model and model:FindFirstChildOfClass("Humanoid")
	if hum then
		Effects.impact(pos, -b.vel.Unit, "body")
		if b.isLocal then
			Audio.at(pos, Audio.ids.ImpactBody, 0.7, 1)
			remotes.Hit:FireServer(part, pos, b.rifle.id)
		end
		if b.path then
			table.insert(b.path, pos)
		end
		Ballistics.Impact:Fire({ kind = "body", part = part, position = pos, distance = dist, isLocal = b.isLocal, origin = b.origin, path = b.path,
			flight = b.age, velocity = b.vel })
	elseif isSteel(part) then
		Effects.ding(part, pos)
		Audio.at(pos, Audio.ids.ImpactMetal, 1, 1.35 + math.random() * 0.1, 6000)
		if b.isLocal then
			remotes.Ding:FireServer(part, pos)
		end
		Ballistics.Impact:Fire({ kind = "steel", part = part, position = pos, distance = dist, isLocal = b.isLocal })
	else
		local kind = materialKind(result.Material)
		Effects.impact(pos, result.Normal, kind)
		Audio.at(pos, kind == "metal" and Audio.ids.ImpactMetal or Audio.ids.ImpactDirt, 0.5, 1)
		Ballistics.Impact:Fire({ kind = "miss", position = pos, distance = dist, isLocal = b.isLocal })
	end
end

function Ballistics.init()
	remotes = Kit:WaitForChild("Remotes")
	RunService.Heartbeat:Connect(function(dt)
		local g = Vector3.new(0, -Config.Gravity, 0)
		for i = #bullets, 1, -1 do
			local b = bullets[i]
			local steps = math.max(1, math.ceil(dt * 120))
			local h = dt / steps
			local done = false
			local start = b.pos
			for _ = 1, steps do
				local nextPos = b.pos + b.vel * h + g * (0.5 * h * h)
				local seg = nextPos - b.pos
				local result = workspace:Raycast(b.pos, seg, params)
				if result then
					onImpact(b, result)
					b.pos = result.Position
					done = true
					break
				end
				b.vel += g * h
				b.pos = nextPos
				b.age += h
				if b.path and #b.path < 400 then
					table.insert(b.path, nextPos)
				end
				if b.age > 4 or b.pos.Y < -100 then
					done = true
					break
				end
			end
			-- trace starts a little way out so it never crosses the scope picture up close
			if b.isLocal and (b.pos - b.origin).Magnitude > 40 then
				Effects.trace(start, b.pos)
			end
			if done then
				table.remove(bullets, i)
			end
		end
	end)
end

-- launch angle above the line of sight that brings the round back onto it at `metres`
function Ballistics.zeroAngle(rifle, metres: number): number
	local d = metres / Config.MetersPerStud
	return Config.Gravity * d / (2 * rifle.velocity * rifle.velocity)
end

-- how far below the line of sight (radians) the round is at `metres` with the rifle zeroed at `zero`
function Ballistics.holdover(rifle, zero: number, metres: number): number
	local d = metres / Config.MetersPerStud
	local t = d / rifle.velocity
	local drop = 0.5 * Config.Gravity * t * t
	return drop / d - Ballistics.zeroAngle(rifle, zero)
end

return Ballistics
