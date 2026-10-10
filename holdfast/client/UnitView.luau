local RS = game:GetService("ReplicatedStorage")

local Config = require(RS.Hold.Config)
local Pack = require(RS.Hold.Pack)
local Rig = require(script.Parent.Rig)
local Sfx = require(script.Parent.Sfx)
local State = require(script.Parent.State)
local Theme = require(script.Parent.Theme)

local UnitView = {}

local A = Pack.Anim
local camera = workspace.CurrentCamera
local folder = Instance.new("Folder")
folder.Name = "HoldUnits"
folder.Parent = workspace

UnitView.views = {} :: { [number]: any }
local views = UnitView.views
local fx: any = nil

function UnitView.setFx(f: any)
	fx = f
end

local function enemyKind(k: number): boolean
	local def = Config.Units[Config.UnitKinds[k] or ""]
	return def ~= nil and def.enemy == true
end

local function makeBar(v: any)
	local bb = Instance.new("BillboardGui")
	bb.Name = "Hp"
	bb.Size = UDim2.fromOffset(34, 7)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 1.6 * v.rig.s, 0)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.Adornee = v.rig.head
	local back = Instance.new("Frame")
	back.BorderSizePixel = 0
	back.BackgroundColor3 = Theme.C.ink
	back.Size = UDim2.fromScale(1, 1)
	back.Parent = bb
	local fill = Instance.new("Frame")
	fill.BorderSizePixel = 0
	fill.Position = UDim2.fromOffset(1, 1)
	fill.Size = UDim2.new(1, -2, 1, -2)
	fill.BackgroundColor3 = Theme.C.hp
	fill.Parent = back
	local shine = Instance.new("Frame")
	shine.BorderSizePixel = 0
	shine.BackgroundColor3 = Color3.new(1, 1, 1)
	shine.BackgroundTransparency = 0.6
	shine.Size = UDim2.new(1, 0, 0, 1)
	shine.Parent = fill
	bb.Parent = v.rig.model
	v.bar = bb
	v.barFill = fill
end

local function makeDisc(v: any)
	local d = Instance.new("Part")
	d.Name = "Sel"
	d.Shape = Enum.PartType.Cylinder
	d.Anchored = true
	d.CanCollide = false
	d.CanQuery = false
	d.CanTouch = false
	d.CastShadow = false
	d.Material = Enum.Material.Neon
	d.Transparency = 0.45
	d.Size = Vector3.new(0.08, 3.4 * v.rig.s, 3.4 * v.rig.s)
	d.Color = if v.enemy then Theme.C.bad else Theme.C.good
	d.Parent = v.rig.model
	v.disc = d
end

local function create(row: Pack.Row): any
	local kind = Config.UnitKinds[row.kind] or "Worker"
	local rig = Rig.new(kind, row.slot, row.id, folder)
	local v = {
		id = row.id, kind = kind, def = Config.Units[kind], slot = row.slot, enemy = enemyKind(row.kind), rig = rig,
		x = row.x, z = row.z, yaw = row.yaw, tx = row.x, tz = row.z, tyaw = row.yaw,
		anim = row.anim, animT = math.random(), walk = math.random() * 6, hp = row.hp, lastPhase = 0,
		mine = row.slot == State.slot() and not enemyKind(row.kind),
	}
	Rig.setTool(rig, row.tool)
	Rig.setCarry(rig, row.carry)
	views[row.id] = v
	return v
end

local function destroy(v: any)
	views[v.id] = nil
	if v.dead then
		task.delay(2.5, function()
			v.rig.model:Destroy()
		end)
	else
		v.rig.model:Destroy()
	end
end

local function die(v: any)
	if v.dead then
		return
	end
	v.dead = true
	if v.bar then
		v.bar:Destroy()
		v.bar = nil
	end
	if v.disc then
		v.disc:Destroy()
		v.disc = nil
	end
	Rig.breakApart(v.rig)
	Sfx.at("Oof", Vector3.new(v.x, 3, v.z), if v.enemy then 0.85 else 1.05)
end

function UnitView.onSnap(b: buffer)
	local rows = Pack.decode(b)
	local seen = {}
	for _, row in rows do
		local v = views[row.id]
		if not v then
			v = create(row)
		end
		seen[row.id] = true
		if not v.dead then
			if (row.x - v.tx) ^ 2 + (row.z - v.tz) ^ 2 > 400 then
				v.x, v.z = row.x, row.z
			end
			v.tx, v.tz, v.tyaw = row.x, row.z, row.yaw
			if row.anim ~= v.anim then
				v.anim = row.anim
				v.animT = 0
				v.lastPhase = 0
				if row.anim == A.Dead then
					die(v)
				end
			end
			if row.hp < v.hp - 0.001 and fx then
				fx.hitBurst(Vector3.new(v.x, 2.6 * v.rig.s, v.z), v.enemy)
			end
			v.hp = row.hp
			v.carry = row.carry
			v.carryN = row.carryN
			v.tool = row.tool
			Rig.setTool(v.rig, row.tool)
			Rig.setCarry(v.rig, row.carry)
		end
	end
	for id, v in views do
		if not seen[id] then
			destroy(v)
		end
	end
end

local function angleLerp(a: number, b: number, t: number): number
	local d = (b - a + math.pi) % (2 * math.pi) - math.pi
	return a + d * t
end

local function ease(t: number): number
	return t * t * (3 - 2 * t)
end

local function swing(f: number, hi: number, lo: number, rest: number): (number, boolean)
	if f < 0.55 then
		return rest + (hi - rest) * ease(f / 0.55), false
	elseif f < 0.68 then
		local k = (f - 0.55) / 0.13
		return hi + (lo - hi) * k * k, false
	end
	return lo + (rest - lo) * ease((f - 0.68) / 0.32), true
end

local function animPose(v: any, dt: number): any
	local a = { bob = 0 }
	local t = v.animT
	local anim = v.anim
	local s = v.rig.s
	if anim == A.Walk then
		local ph = v.walk * 1.5 / s
		local sw = math.sin(ph)
		local amp = if v.carry and v.carry > 0 then 0.35 else 0.75
		a.ra, a.la = sw * amp, -sw * amp
		a.rl, a.ll = -sw * 0.8, sw * 0.8
		a.bob = math.abs(math.cos(ph)) * 0.18 * s
		if v.carry == 1 then
			a.ra, a.raz = 2.9, 0.1
		end
	elseif anim == A.Chop or anim == A.Mine then
		local speed = if State.team:GetAttribute("R_Tools") then 1.5 else 1
		local period = (if anim == A.Chop then 1.0 else 1.5) / speed
		local f = (t % period) / period
		local r, after = swing(f, 2.7, 0.35, 0.6)
		a.ra = r
		a.la = r * 0.9
		a.laz = 0.35
		a.raz = -0.15
		a.tp = if f > 0.55 and f < 0.8 then 0.18 else 0.04
		a.rl, a.ll = 0.15, -0.15
		if after and v.lastPhase < 0.68 then
			local pos = Vector3.new(v.x, 1.5, v.z) + CFrame.Angles(0, v.yaw, 0).LookVector * 2.4
			if anim == A.Chop then
				Sfx.at("Chop", pos)
				if fx then
					fx.chips(pos, "wood")
				end
			else
				Sfx.at(if v.tool == 2 and v.carry == 4 then "MineIron" else "Mine", pos)
				if fx then
					fx.chips(pos, "stone")
				end
			end
		end
		v.lastPhase = f
	elseif anim == A.Build then
		local period = 0.6
		local f = (t % period) / period
		local r, after = swing(f, 2.0, 0.5, 0.9)
		a.ra = r
		a.la = 0.4
		a.tp = 0.12
		if after and v.lastPhase < 0.68 then
			local pos = Vector3.new(v.x, 1.5, v.z) + CFrame.Angles(0, v.yaw, 0).LookVector * 2.2
			Sfx.at("Hammer", pos)
			if fx then
				fx.chips(pos, "wood")
			end
		end
		v.lastPhase = f
	elseif anim == A.Melee then
		local period = v.def.cd
		local f = (t % period) / period
		local r, after = swing(f, 2.8, 0.15, 0.5)
		a.ra = r
		a.la = 0.5
		a.laz = -0.25
		a.tp = if f > 0.55 and f < 0.75 then 0.15 else 0
		a.rl, a.ll = 0.3, -0.25
		if after and v.lastPhase < 0.68 then
			local pos = Vector3.new(v.x, 2, v.z) + CFrame.Angles(0, v.yaw, 0).LookVector * 2.6
			Sfx.at("Swing", pos)
			Sfx.at("Hit", pos, nil, 0.25)
		end
		v.lastPhase = f
	elseif anim == A.Shoot then
		local period = v.def.cd
		local f = (t % period) / period
		if v.kind == "Slinger" then
			a.ra = f * math.pi * 4
			a.la = 0.3
		else
			a.la = math.pi / 2
			a.laz = 0.1
			local pull = math.min(1, f / 0.7)
			a.ra = math.pi / 2 - 0.1
			a.raz = 0.6 * pull
			a.hy = 0.1
		end
		v.lastPhase = f
	else
		local br = math.sin(t * 2 + v.id)
		a.ra = 0.05 + br * 0.04
		a.la = 0.05 - br * 0.04
		a.bob = br * 0.03 * s
		if v.kind == "Archer" then
			a.la = 0.5
		end
	end
	return a
end

local partsBuf: { BasePart } = {}
local cfBuf: { CFrame } = {}

function UnitView.update(dt: number)
	table.clear(partsBuf)
	table.clear(cfBuf)
	local camPos = camera.CFrame.Position
	local k = 1 - math.exp(-dt * 14)
	local frame = (UnitView.frame or 0) + 1
	UnitView.frame = frame
	for _, v in views do
		if v.dead then
			continue
		end
		local ox, oz = v.x, v.z
		v.x += (v.tx - v.x) * k
		v.z += (v.tz - v.z) * k
		v.yaw = angleLerp(v.yaw, v.tyaw, math.min(1, k * 1.3))
		v.walk += math.sqrt((v.x - ox) ^ 2 + (v.z - oz) ^ 2) / 2.2
		v.animT += dt
		local pos = Vector3.new(v.x, 0, v.z)
		local sp, onScreen = camera:WorldToViewportPoint(pos + Vector3.new(0, 2.5 * v.rig.s, 0))
		v.sx, v.sy, v.on = sp.X, sp.Y, onScreen and sp.Z > 0
		local far = (pos - camPos).Magnitude > 260
		if not v.on and frame % 6 ~= v.id % 6 then
			continue
		end
		if far and frame % 2 ~= v.id % 2 then
			continue
		end
		local a = animPose(v, dt)
		local root = CFrame.new(v.x, 0, v.z) * CFrame.Angles(0, v.yaw, 0)
		local base = #cfBuf
		Rig.pose(v.rig, root, a, cfBuf)
		for i, p in v.rig.parts do
			partsBuf[base + i] = p
		end
		local selected = State.selSet[v.id] or (State.selInfo and State.selInfo.unit == v.id)
		if selected then
			if not v.disc then
				makeDisc(v)
			end
			v.disc.CFrame = CFrame.new(v.x, 0.06, v.z) * CFrame.Angles(0, 0, math.pi / 2)
		elseif v.disc then
			v.disc:Destroy()
			v.disc = nil
		end
		local showBar = v.hp > 0 and (selected or v.hp < 0.999 or UnitView.hover == v.id)
		if showBar then
			if not v.bar then
				makeBar(v)
			end
			v.barFill.Size = UDim2.new(math.max(0, v.hp), -2, 1, -2)
			v.barFill.BackgroundColor3 = if v.enemy then Theme.C.bad elseif v.hp < 0.35 then Theme.C.warn else Theme.C.hp
		elseif v.bar then
			v.bar:Destroy()
			v.bar = nil
		end
	end
	if #partsBuf > 0 then
		workspace:BulkMoveTo(partsBuf, cfBuf, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

function UnitView.pick(sx: number, sy: number, radius: number, filter: ((any) -> boolean)?): any
	local best, bd = nil, radius * radius
	for _, v in views do
		if not v.dead and v.on and (not filter or filter(v)) then
			local d = (v.sx - sx) ^ 2 + (v.sy - sy) ^ 2
			if d < bd then
				bd = d
				best = v
			end
		end
	end
	return best
end

function UnitView.inRect(x0: number, y0: number, x1: number, y1: number, filter: ((any) -> boolean)?): { any }
	local out = {}
	local ax, bx = math.min(x0, x1), math.max(x0, x1)
	local ay, by = math.min(y0, y1), math.max(y0, y1)
	for _, v in views do
		if not v.dead and v.on and v.sx >= ax and v.sx <= bx and v.sy >= ay and v.sy <= by and (not filter or filter(v)) then
			table.insert(out, v)
		end
	end
	return out
end

function UnitView.clear()
	for _, v in views do
		v.rig.model:Destroy()
	end
	table.clear(views)
end

return UnitView
