--[[
	The bullet-cam: a headshot kill from 50 m or more is replayed from the round's point of view. The
	camera rides behind the bullet as it leaves the muzzle, spinning round it, the world blurred past it,
	slowing right down for the last few metres into the head; a red burst, a beat, and a white flash back
	to the bodycam.

	How: every round you fire records its real path (Ballistics: drop and all). When one of them hits a
	head from far enough away, the man it hit is copied as he stood at that moment (a still "ghost" of
	every part); if the server then confirms it as a headshot kill, the replay plays with the ghost in
	his place (the real body, already falling, is hidden meanwhile). Nothing else in the world stops: it's
	only your screen, about two and a half seconds, your controls held while it runs.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")

local Kit = ReplicatedStorage:WaitForChild("SniperKit")
local Config = require(Kit:WaitForChild("Config"))
local Util = require(script.Parent.Util)
local Theme = require(script.Parent.Theme)
local Audio = require(script.Parent.Audio)
local Ballistics = require(script.Parent.Ballistics)

local make = Util.make
local C = Theme.Color
local Ids = Audio.ids
local MPS = Config.MetersPerStud

local BulletCam = {}
BulletCam.playing = false
BulletCam.MIN_METRES = 50

local player = Players.LocalPlayer
local deps

local HEAD = { Head = true, Helmet = true, HelmetBrim = true, Hood = true }

-- the last long head hit, waiting for the server to say it killed
type Joint = { motor: boolean, a: BasePart, b: BasePart, c0: CFrame, c1: CFrame, name: string }
type Shot = { model: Model, ghost: { BasePart }, joints: { Joint }, path: { Vector3 }, hit: Vector3, part: BasePart, at: number }
local pending: Shot? = nil

local function dropShot(s: Shot?)
	if s then
		for _, p in s.ghost do
			p:Destroy()
		end
	end
end

-- the man as he stood when the round arrived: every part copied, still, and how they were joined (so
-- the copy can go down as a ragdoll: loose at the joints, his kit stuck on, the rifle coming away)
local function snapshot(model: Model): ({ BasePart }, { Joint })
	local out, map = {}, {}
	local rifle = model:FindFirstChild("Rifle")
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
			local c = d:Clone()
			for _, x in c:GetChildren() do
				if x:IsA("JointInstance") or x:IsA("WeldConstraint") or x:IsA("Constraint") or x:IsA("Attachment") or x:IsA("Script") or x:IsA("LocalScript") then
					x:Destroy()
				end
			end
			c.Anchored = true
			c.CanCollide = false
			c.CanQuery = false
			c.CanTouch = false
			c.CFrame = d.CFrame
			c.LocalTransparencyModifier = 0
			c:SetAttribute("Head", HEAD[d.Name] == true)
			c:SetAttribute("Rifle", rifle ~= nil and d:IsDescendantOf(rifle))
			map[d] = c
			table.insert(out, c)
		end
	end
	local joints = {}
	for _, d in model:GetDescendants() do
		if d:IsA("JointInstance") and d.Enabled and d.Part0 and d.Part1 and map[d.Part0] and map[d.Part1] then
			table.insert(joints, { motor = d:IsA("Motor6D"), a = map[d.Part0], b = map[d.Part1], c0 = d.C0, c1 = d.C1, name = d.Name })
		elseif d:IsA("WeldConstraint") and d.Enabled and d.Part0 and d.Part1 and map[d.Part0] and map[d.Part1] then
			table.insert(joints, { motor = false, a = map[d.Part0], b = map[d.Part1], c0 = CFrame.identity, c1 = CFrame.identity, name = "WeldConstraint" })
		end
	end
	return out, joints
end

local BODY = { Head = true, UpperTorso = true, LowerTorso = true, LeftUpperArm = true, RightUpperArm = true, LeftLowerArm = true, RightLowerArm = true,
	LeftUpperLeg = true, RightUpperLeg = true, LeftLowerLeg = true, RightLowerLeg = true, LeftHand = true, RightHand = true, LeftFoot = true, RightFoot = true }

-- the round lands: the copy goes loose at every joint and is thrown back the way the round was going,
-- the head whipping back, the arms flung up and back, the rifle torn out of his hands
local function ragdoll(s: Shot, dir: Vector3): (BasePart?, BasePart?)
	local push = Vector3.new(dir.X, 0, dir.Z)
	push = if push.Magnitude > 0.01 then push.Unit else Vector3.xAxis
	local topple = -push:Cross(Vector3.yAxis) -- (spin that tips him over backwards)
	for _, p in s.ghost do
		p.Anchored = false
		p.CanCollide = BODY[p.Name] == true or (p:GetAttribute("Rifle") and p.Size.Magnitude > 0.8)
		p.Massless = not BODY[p.Name] and not p:GetAttribute("Rifle")
	end
	for _, j in s.joints do
		local rifleA, rifleB = j.a:GetAttribute("Rifle"), j.b:GetAttribute("Rifle")
		if rifleA ~= rifleB then
			continue -- (the rifle comes away from him)
		end
		if j.motor then
			-- (two pieces joined here overlap at the joint: they mustn't push each other apart)
			make("NoCollisionConstraint", { Part0 = j.a, Part1 = j.b, Parent = j.b })
			local a0 = make("Attachment", { CFrame = j.c0, Parent = j.a })
			local a1 = make("Attachment", { CFrame = j.c1, Parent = j.b })
			make("BallSocketConstraint", { Attachment0 = a0, Attachment1 = a1, LimitsEnabled = true, UpperAngle = if j.name == "Neck" then 50 else 75,
				TwistLimitsEnabled = true, TwistLowerAngle = -45, TwistUpperAngle = 45, Parent = j.b })
		else
			make("WeldConstraint", { Part0 = j.a, Part1 = j.b, Parent = j.b })
		end
	end
	local limbs, rifleParts = {}, {}
	for _, p in s.ghost do
		if string.find(p.Name, "Arm") or string.find(p.Name, "Hand") then
			table.insert(limbs, p)
		elseif p:GetAttribute("Rifle") then
			table.insert(rifleParts, p)
		end
	end
	-- (his arms were up across his chest round the rifle: they mustn't shove off his own body)
	for _, p in s.ghost do
		if p.Name == "UpperTorso" or p.Name == "LowerTorso" or p.Name == "Head" then
			for _, l in limbs do
				make("NoCollisionConstraint", { Part0 = p, Part1 = l, Parent = l })
			end
		end
	end
	for _, r in rifleParts do
		if r.CanCollide then
			r.CanCollide = false
			task.delay(0.45, function()
				if r.Parent then
					r.CanCollide = true
				end
			end)
			for _, l in limbs do
				make("NoCollisionConstraint", { Part0 = r, Part1 = l, Parent = r })
			end
		end
	end
	local torso, gun
	for _, p in s.ghost do
		local n = p.Name
		if n == "Head" then
			p.AssemblyLinearVelocity = push * 78 + Vector3.new(0, 16, 0)
			p.AssemblyAngularVelocity = topple * 14
		elseif n == "UpperTorso" then
			torso = p
			p.AssemblyLinearVelocity = push * 46 + Vector3.new(0, 10, 0)
			p.AssemblyAngularVelocity = topple * 9
		elseif n == "LowerTorso" then
			p.AssemblyLinearVelocity = push * 26 + Vector3.new(0, 5, 0)
		elseif string.find(n, "Arm") or string.find(n, "Hand") then
			p.AssemblyLinearVelocity = push * 42 + Vector3.new(0, 7, 0)
		elseif string.find(n, "Leg") or string.find(n, "Foot") then
			p.AssemblyLinearVelocity = push * 10 + Vector3.new(0, 2, 0)
		elseif p:GetAttribute("Rifle") and not gun then
			gun = p
			local side = Vector3.new(-push.Z, 0, push.X) * (math.random() - 0.5) * 14
			p.AssemblyLinearVelocity = push * 12 + side + Vector3.new(0, 18, 0)
			p.AssemblyAngularVelocity = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 16
		end
	end
	return torso, gun
end

-- where the round is along its recorded path at k (0 muzzle .. 1 impact), and which way it's going
local function along(path: { Vector3 }, k: number): (Vector3, Vector3)
	local n = #path
	if n < 2 then
		return path[1], Vector3.zAxis
	end
	local lens = { 0 }
	for i = 2, n do
		lens[i] = lens[i - 1] + (path[i] - path[i - 1]).Magnitude
	end
	local want = math.clamp(k, 0, 1) * lens[n]
	for i = 2, n do
		if lens[i] >= want then
			local seg = lens[i] - lens[i - 1]
			local f = if seg > 0 then (want - lens[i - 1]) / seg else 0
			local dir = (path[i] - path[i - 1])
			return path[i - 1]:Lerp(path[i], f), if dir.Magnitude > 0 then dir.Unit else Vector3.zAxis
		end
	end
	return path[n], (path[n] - path[n - 1]).Unit
end

local function controls(on: boolean)
	local ok, pm = pcall(function()
		return require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule"))
	end)
	if ok and pm then
		local c = pm:GetControls()
		if on then
			c:Enable()
		else
			c:Disable()
		end
	end
end

local function play(s: Shot, metres: number)
	BulletCam.playing = true
	local cam = workspace.CurrentCamera
	local saved = { type = cam.CameraType, fov = cam.FieldOfView, subject = cam.CameraSubject }
	-- only the replay on the screen
	local hidden = {}
	for _, g in player.PlayerGui:GetChildren() do
		if g:IsA("ScreenGui") and g.Enabled then
			g.Enabled = false
			table.insert(hidden, g)
		end
	end
	local gui = Theme.screen("SnipersBulletCam", 280)
	local barH = 0.1
	local top = make("Frame", { BorderSizePixel = 0, BackgroundColor3 = Color3.new(0, 0, 0), Size = UDim2.fromScale(1, 0), Parent = gui })
	local bottom = make("Frame", { BorderSizePixel = 0, BackgroundColor3 = Color3.new(0, 0, 0), AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0), Parent = gui })
	TweenService:Create(top, TweenInfo.new(0.25), { Size = UDim2.fromScale(1, barH) }):Play()
	TweenService:Create(bottom, TweenInfo.new(0.25), { Size = UDim2.fromScale(1, barH) }):Play()
	local caption = Theme.label({ Text = string.format("HEADSHOT  ·  %d M", metres), TextSize = 22, FontFace = Theme.Font.Bold, TextColor3 = C.Accent,
		TextTransparency = 1, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 1 - barH / 2, 0),
		Size = UDim2.fromOffset(700, 30), Parent = gui })
	Theme.label({ Text = "● REPLAY  ·  ROUND CAM", TextSize = 12, TextColor3 = C.Alert, Position = UDim2.fromOffset(40, 18), Size = UDim2.fromOffset(400, 18),
		Parent = gui })
	local flash = make("Frame", { BorderSizePixel = 0, BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 20,
		Parent = gui })
	-- the world blurred behind the round, a little colder and harder
	local dof = make("DepthOfFieldEffect", { Name = "BulletCamDof", FarIntensity = 0.8, NearIntensity = 0.15, FocusDistance = 3.5, InFocusRadius = 3,
		Parent = Lighting })
	local grade = make("ColorCorrectionEffect", { Name = "BulletCamGrade", Saturation = -0.25, Contrast = 0.18, TintColor = Color3.fromRGB(236, 240, 255),
		Parent = Lighting })
	-- the rest of the world goes quiet; the round's own sound
	local master = Audio.groups.master
	local vol = master.Volume
	TweenService:Create(master, TweenInfo.new(0.2), { Volume = vol * 0.25 }):Play()
	local whoosh = make("Sound", { SoundId = Util.pick(Ids.WhizBy), Volume = 1.2, PlaybackSpeed = 0.32, Parent = SoundService })
	whoosh:Play()
	Audio.play(Ids.Heartbeat, 0.6, 0.8)
	-- you, held where you are
	controls(false)
	if deps.Weapon then
		deps.Weapon.menu = true
	end
	-- the man as he stood; the real one (already going down) hidden till it's over
	for _, d in s.model:GetDescendants() do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = 1
		end
	end
	local folder = make("Folder", { Name = "BulletCamGhost", Parent = workspace })
	for _, p in s.ghost do
		p.Parent = folder
	end
	-- the round itself: a copper-jacketed bullet, its wake in the air behind it
	local bullet = make("Part", { Name = "Round", Size = Vector3.new(0.13, 0.13, 0.55), Color = Color3.fromRGB(196, 132, 76), Material = Enum.Material.Metal,
		Reflectance = 0.25, Anchored = true, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false, Parent = folder })
	local tip = make("Part", { Name = "Tip", Shape = Enum.PartType.Ball, Size = Vector3.new(0.13, 0.13, 0.13), Color = Color3.fromRGB(196, 132, 76), Material = Enum.Material.Metal,
		Reflectance = 0.25, Anchored = true, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false, Parent = folder })
	local a0 = make("Attachment", { Position = Vector3.new(0, 0.05, 0.25), Parent = bullet })
	local a1 = make("Attachment", { Position = Vector3.new(0, -0.05, 0.25), Parent = bullet })
	make("Trail", { Attachment0 = a0, Attachment1 = a1, Lifetime = 0.35, FaceCamera = true, LightInfluence = 0.5, MinLength = 0.05,
		Color = ColorSequence.new(Color3.fromRGB(240, 240, 240)), WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 6) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) }), Parent = bullet })

	cam.CameraType = Enum.CameraType.Scriptable
	-- the flight in slow motion: off the muzzle quickly, then slower and slower into the head
	local FLIGHT = 1.9
	local t0 = os.clock()
	local hitDone = false
	local function k(t: number): number
		local u = math.clamp(t / FLIGHT, 0, 1)
		-- fast out of the barrel, crawling at the end (the last 4% takes the last third of the time)
		return if u < 0.65 then (u / 0.65) * 0.96 else 0.96 + 0.04 * math.sin((u - 0.65) / 0.35 * math.pi / 2)
	end
	local headPos = s.hit
	local fallTorso: BasePart? = nil
	local hitCam: CFrame? = nil
	RunService:BindToRenderStep("Snipers_BulletCam", Enum.RenderPriority.Last.Value + 20, function()
		local t = os.clock() - t0
		local tc = math.min(t, FLIGHT) -- (everything holds still from the moment it hits)
		local pos, dir = along(s.path, k(tc))
		bullet.CFrame = CFrame.lookAt(pos, pos + dir)
		tip.CFrame = bullet.CFrame * CFrame.new(0, 0, -0.3)
		-- behind it and a little to the side, circling round it as it spins
		local u = math.clamp(tc / FLIGHT, 0, 1)
		local spin = 7 * (1 - (1 - u) ^ 2) -- (circling fast off the muzzle, slowing to a stop at the head)
		local right = dir:Cross(Vector3.yAxis)
		right = if right.Magnitude > 1e-3 then right.Unit else Vector3.xAxis
		local up = right:Cross(dir).Unit
		local orbit = (right * math.cos(spin) + up * math.sin(spin)) * 0.9
		local back = 2.6 + 1.4 * (1 - math.clamp(tc / FLIGHT, 0, 1)) -- (closing in as it nears him)
		local camPos = pos - dir * back + orbit
		local flightCam = CFrame.lookAt(camPos, pos + dir * 4, up) * CFrame.Angles(0, 0, math.sin(tc * 2.2) * 0.25 * (1 - u))
		cam.CFrame = flightCam
		cam.FieldOfView = 58 - 18 * math.clamp(tc / FLIGHT, 0, 1)
		-- after the hit: the camera eases back and watches him go down
		if hitDone and hitCam then
			local v = math.clamp((t - FLIGHT) / 0.7, 0, 1)
			local e = 1 - (1 - v) ^ 3
			local focus = if fallTorso and fallTorso.Parent then fallTorso.Position else headPos
			local side = dir:Cross(Vector3.yAxis)
			side = if side.Magnitude > 1e-3 then side.Unit else Vector3.xAxis
			local wide = headPos - Vector3.new(dir.X, 0, dir.Z).Unit * 9 + side * 4 + Vector3.new(0, 3, 0)
			local from = (hitCam :: CFrame).Position
			cam.CFrame = CFrame.lookAt(from:Lerp(wide, e), focus)
			cam.FieldOfView = 40 + 14 * e
			dof.FocusDistance = (focus - cam.CFrame.Position).Magnitude
			return
		end
		dof.FocusDistance = (pos - camPos).Magnitude
		if not hitDone and t >= FLIGHT then
			hitDone = true
			-- in: a red burst, the head snaps back, the hit's thud slowed down
			Audio.play(Ids.ImpactBody, 1.2, 0.5)
			local burst = make("Part", { Name = "Burst", Size = Vector3.new(0.2, 0.2, 0.2), Transparency = 1, Anchored = true, CanCollide = false, CanQuery = false,
				CanTouch = false, CFrame = CFrame.lookAt(headPos, headPos + dir), Parent = folder })
			local mist = make("ParticleEmitter", { Texture = "rbxasset://textures/particles/smoke_main.dds", Rate = 0, Lifetime = NumberRange.new(0.6, 1.2),
				Speed = NumberRange.new(2, 7), SpreadAngle = Vector2.new(35, 35), EmissionDirection = Enum.NormalId.Front, Drag = 3,
				Color = ColorSequence.new(Color3.fromRGB(120, 14, 14), Color3.fromRGB(70, 10, 10)),
				Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 2.4) }),
				Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) }), Parent = burst })
			mist:Emit(26)
			hitCam = cam.CFrame
			-- the round's whoosh ends where the round does
			TweenService:Create(whoosh, TweenInfo.new(0.06), { Volume = 0 }):Play()
			task.delay(0.07, function()
				whoosh:Stop()
			end)
			TweenService:Create(master, TweenInfo.new(0.25), { Volume = vol * 0.85 }):Play() -- (the world's sound back for the fall)
			local torso, gun = ragdoll(s, dir)
			fallTorso = torso
			-- him hitting the ground, the rifle clattering down after
			task.delay(0.55, function()
				Audio.at(if torso then torso.Position else headPos, Ids.BodyFall, 1.1, 0.9, 400)
				Audio.at(if torso then torso.Position else headPos, Ids.ClothRustle, 0.8, 0.8, 400)
			end)
			task.delay(0.75, function()
				Audio.at(if gun then gun.Position else headPos, Ids.ImpactMetal, 0.55, 1.5, 400)
			end)
			bullet.Transparency = 1
			tip.Transparency = 1
		end
	end)
	task.wait(0.15)
	TweenService:Create(caption, TweenInfo.new(0.4), { TextTransparency = 0 }):Play()
	task.wait(FLIGHT + 1.9) -- (the hit, and him going down)
	-- snap back: a white flash and the bodycam tearing
	flash.BackgroundTransparency = 0
	RunService:UnbindFromRenderStep("Snipers_BulletCam")
	folder:Destroy()
	dof:Destroy()
	grade:Destroy()
	whoosh:Destroy()
	for _, d in s.model:GetDescendants() do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = 0
		end
	end
	cam.CameraType = Enum.CameraType.Custom
	cam.CameraSubject = saved.subject
	cam.FieldOfView = saved.fov
	if deps.View then
		deps.View.apply()
	end
	for _, g in hidden do
		if g.Parent then
			g.Enabled = true
		end
	end
	TweenService:Create(master, TweenInfo.new(0.35), { Volume = vol }):Play()
	controls(true)
	if deps.Weapon then
		deps.Weapon.menu = false
	end
	if deps.Bodycam and deps.Bodycam.glitch then
		deps.Bodycam.glitch(3)
	end
	TweenService:Create(flash, TweenInfo.new(0.35), { BackgroundTransparency = 1 }):Play()
	task.wait(0.4)
	gui:Destroy()
	BulletCam.playing = false
end

function BulletCam.init(d)
	deps = d
	-- a long head hit: keep the man as he stood, until the server says whether it killed
	Ballistics.Impact:Connect(function(info)
		if not info.isLocal or info.kind ~= "body" or not info.path or not info.part or not HEAD[info.part.Name] then
			return
		end
		if info.distance * MPS < BulletCam.MIN_METRES or BulletCam.playing then
			return
		end
		local model = info.part:FindFirstAncestorOfClass("Model")
		if not model or Players:GetPlayerFromCharacter(model) then
			return
		end
		dropShot(pending)
		local ghost, joints = snapshot(model)
		pending = { model = model, ghost = ghost, joints = joints, path = table.clone(info.path), hit = info.position, part = info.part, at = os.clock() }
	end)
	Kit:WaitForChild("Remotes"):WaitForChild("Confirm").OnClientEvent:Connect(function(c)
		local s = pending
		if type(c) ~= "table" or c.kind ~= "kill" or not c.head or c.by or not s then
			return
		end
		pending = nil
		if os.clock() - s.at > 2.5 or (tonumber(c.distance) or 0) < BulletCam.MIN_METRES then
			dropShot(s)
			return
		end
		-- not while something else has the camera
		local busy = (deps.Drone and deps.Drone.busy and deps.Drone.busy()) or (deps.Airstrike and deps.Airstrike.busy and deps.Airstrike.busy())
			or (deps.Kaboom and deps.Kaboom.busy())
			or (deps.Intro and deps.Intro.playing) or (deps.Freecam and deps.Freecam.active) or player:GetAttribute("MissionOver")
		if busy then
			dropShot(s)
			return
		end
		task.spawn(play, s, math.floor(tonumber(c.distance) or 0))
	end)
end

return BulletCam
