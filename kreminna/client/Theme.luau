--[[
	Body-camera UI kit (KREMINNA): everything on screen looks like what a helmet camera burns into its
	footage. Monospaced white text with a thin dark outline straight on the picture, no boxes; where a
	surface is needed, a smoked-glass black with white corner brackets (the camera's framing marks).
	Yellow for what matters (the camcorder date-stamp yellow), red only for REC, hostiles and danger.
	Menus are camcorder menus: the selected line goes inverse (black on a white bar) with a > in front.
	Things appear with a quick signal flicker.

	Same API as before, so every screen picks it up: screen, canvas, px, bevel (now: corner brackets),
	content, scanlines, pop, label, panel, window, rule, bar, caption, button, action.
	Extras: Theme.brackets(f, size?, color?), Theme.stamp() (hh:mm:ss of the clock).

	Layout is authored at 1080p and scaled with a UIScale per ScreenGui. Sizes given with PixelSize =
	true were pixel-font sizes (the old kit); px() turns either kind into a mono size that reads the same.
]]

local Players = game:GetService("Players")

local Util = require(script.Parent.Util)
local make = Util.make

local Theme = {}

Theme.Color = {
	Bg = Color3.fromRGB(8, 8, 8),
	Panel = Color3.fromRGB(0, 0, 0),
	Raised = Color3.fromRGB(242, 242, 236), -- the inverse-video bar
	Line = Color3.fromRGB(205, 205, 198),
	LineSoft = Color3.fromRGB(90, 90, 86),
	Text = Color3.fromRGB(242, 242, 236),
	Dim = Color3.fromRGB(184, 184, 178),
	Faint = Color3.fromRGB(128, 128, 124),
	Accent = Color3.fromRGB(255, 208, 64), -- date-stamp yellow
	AccentDim = Color3.fromRGB(170, 136, 40),
	Alert = Color3.fromRGB(255, 59, 48), -- REC red
	Shadow = Color3.fromRGB(0, 0, 0),
	Hi = Color3.fromRGB(242, 242, 236),
}

local MONO = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Medium)
local MONO_BOLD = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Bold)
local MONO_LIGHT = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Regular)
Theme.Font = {
	Pixel = MONO, -- (old name, still used around the game: now the camera font)
	Regular = MONO_LIGHT,
	Medium = MONO,
	Bold = MONO_BOLD,
	Light = MONO_LIGHT,
	Mono = MONO,
	MonoMedium = MONO,
}

-- an old size -> a mono size. The old pixel font was big for its number; plain sizes pass through.
function Theme.px(size: number, pixel: boolean?): number
	if pixel then
		return math.floor(size * 1.45 + 0.5)
	end
	return math.floor(size * 0.95 + 0.5)
end

Theme.UIScale = 1.15

function Theme.screen(name: string, order: number?): ScreenGui
	local gui = make("ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = order or 0,
		Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
	})
	local scale = make("UIScale", { Parent = gui })
	local function fit()
		local cam = workspace.CurrentCamera
		local h = cam and cam.ViewportSize.Y or 1080
		scale.Scale = math.clamp(h / 1080 * Theme.UIScale, 0.7, 1.7)
	end
	fit()
	if workspace.CurrentCamera then
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	end
	return gui
end

-- size of the 1080p-equivalent canvas for the current viewport
function Theme.canvas(): Vector2
	local cam = workspace.CurrentCamera
	local v = cam and cam.ViewportSize or Vector2.new(1920, 1080)
	local s = math.clamp(v.Y / 1080 * Theme.UIScale, 0.7, 1.7)
	return v / s
end

-- the clock as the camera stamps it
function Theme.stamp(): string
	return DateTime.now():FormatLocalTime("HH:mm:ss", "en-us")
end

-- four L-shaped corner marks on f (the camera's framing brackets)
function Theme.brackets(f: GuiObject, size: number?, color: Color3?, thickness: number?, transparency: number?)
	local s, t = size or 10, thickness or 2
	local c = color or Theme.Color.Text
	local holder = make("Frame", { Name = "Brackets", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = f.ZIndex + 1, Parent = f })
	local function bar(size2: UDim2, pos: UDim2)
		make("Frame", { BorderSizePixel = 0, BackgroundColor3 = c, BackgroundTransparency = transparency or 0.1, Size = size2, Position = pos, ZIndex = f.ZIndex + 1,
			Parent = holder })
	end
	for _, cx in { 0, 1 } do
		for _, cy in { 0, 1 } do
			bar(UDim2.fromOffset(s, t), UDim2.new(cx, if cx == 1 then -s else 0, cy, if cy == 1 then -t else 0))
			bar(UDim2.fromOffset(t, s), UDim2.new(cx, if cx == 1 then -t else 0, cy, if cy == 1 then -s else 0))
		end
	end
	return holder
end

-- (was the pixel bevel) every framed box gets the camera's corner brackets
function Theme.bevel(f: GuiObject, hi: Color3?, _lo: Color3?, thickness: number?)
	return Theme.brackets(f, 10, hi, thickness)
end

-- a padded inner frame for a box's contents (the brackets stay on the box's real edge).
-- autoY: the content sizes itself to fit (for a box with AutomaticSize Y)
function Theme.content(f: GuiObject, left: number, right: number, top: number, bottom: number, autoY: boolean?): Frame
	local c = make("Frame", { Name = "Content", BackgroundTransparency = 1, Size = if autoY then UDim2.fromScale(1, 0) else UDim2.fromScale(1, 1),
		AutomaticSize = if autoY then Enum.AutomaticSize.Y else Enum.AutomaticSize.None, Parent = f })
	make("UIPadding", { PaddingLeft = UDim.new(0, left), PaddingRight = UDim.new(0, right), PaddingTop = UDim.new(0, top), PaddingBottom = UDim.new(0, bottom),
		Parent = c })
	return c
end

-- faint video scanlines over a full-screen frame
function Theme.scanlines(parent: Instance, transparency: number?)
	local holder = make("Frame", { Name = "Scanlines", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 50, Parent = parent })
	for i = 0, 1440, 3 do
		make("Frame", { BorderSizePixel = 0, BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = transparency or 0.9,
			Size = UDim2.new(1, 0, 0, 1), Position = UDim2.fromOffset(0, i), ZIndex = 50, Parent = holder })
	end
	return holder
end

-- show / hide like a weak signal catching: on-off-on, with a sideways jolt
function Theme.pop(g: GuiObject, show: boolean, done: (() -> ())?)
	local token = (g:GetAttribute("PopToken") or 0) + 1
	g:SetAttribute("PopToken", token)
	local home = g:GetAttribute("PopHome")
	if typeof(home) ~= "UDim2" then
		home = g.Position
		g:SetAttribute("PopHome", home)
	end
	task.spawn(function()
		local steps = if show then { { true, 6 }, { false, 0 }, { true, -3 }, { true, 0 } } else { { false, 0 }, { true, 4 }, { false, 0 } }
		for _, st in steps do
			if g:GetAttribute("PopToken") ~= token then
				return
			end
			g.Visible = st[1]
			g.Position = (home :: UDim2) + UDim2.fromOffset(st[2], 0)
			task.wait(0.035)
		end
		g.Position = home :: UDim2
		if done then
			done()
		end
	end)
end

-- camera text: mono, light, with a thin dark outline so it reads on snow and in the dark alike.
-- Outline = false for text on a solid bar.
function Theme.label(props: { [string]: any }): TextLabel
	local p = {
		BackgroundTransparency = 1,
		TextColor3 = Theme.Color.Text,
		FontFace = MONO,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		AutomaticSize = Enum.AutomaticSize.None,
		RichText = false,
	}
	for k, v in props do
		p[k] = v
	end
	p.TextSize = Theme.px(p.TextSize, props.PixelSize == true)
	local outline = p.Outline
	p.PixelSize = nil
	p.Outline = nil
	p.LineHeight = p.LineHeight or 1.25
	local l = make("TextLabel", p)
	if outline ~= false then
		make("UIStroke", { Name = "TextOutline", Color = Color3.new(0, 0, 0), Thickness = 1.2, Transparency = 0.25, Parent = l })
	end
	return l
end

-- a surface where one is needed: smoked glass with the corner brackets
function Theme.panel(props: { [string]: any }, stroke: boolean?): Frame
	local p = {
		BackgroundColor3 = Theme.Color.Panel,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
	}
	for k, v in props do
		p[k] = v
	end
	local f = make("Frame", p)
	if stroke ~= false then
		Theme.brackets(f)
	end
	return f
end

-- a window: darker glass, brackets, a header line (a small red square, the title, a hairline under
-- it, the clock on the right), hidden until popped
function Theme.window(props: { [string]: any }, title: string?): Frame
	local p = {
		BackgroundColor3 = Theme.Color.Panel,
		BackgroundTransparency = 0.18,
		BorderSizePixel = 0,
		Visible = false,
	}
	for k, v in props do
		p[k] = v
	end
	local w = make("Frame", p)
	Theme.brackets(w, 14)
	if title then
		local strip = make("Frame", { Name = "TitleStrip", BackgroundTransparency = 1, Size = UDim2.new(1, -32, 0, 30), Position = UDim2.fromOffset(16, 8), Parent = w })
		make("Frame", { BorderSizePixel = 0, BackgroundColor3 = Theme.Color.Alert, Size = UDim2.fromOffset(8, 8), Position = UDim2.new(0, 0, 0.5, -4), Parent = strip })
		Theme.label({ Name = "Title", Text = string.upper(title), TextSize = 13, TextColor3 = Theme.Color.Dim, Position = UDim2.fromOffset(16, 0),
			Size = UDim2.new(1, -120, 1, 0), Parent = strip })
		local clock = Theme.label({ Name = "Clock", Text = Theme.stamp(), TextSize = 12, TextColor3 = Theme.Color.Faint, TextXAlignment = Enum.TextXAlignment.Right,
			Size = UDim2.new(1, 0, 1, 0), Parent = strip })
		make("Frame", { BorderSizePixel = 0, BackgroundColor3 = Theme.Color.Text, BackgroundTransparency = 0.7, Size = UDim2.new(1, 0, 0, 1),
			Position = UDim2.new(0, 0, 1, 2), Parent = strip })
		task.spawn(function()
			while clock.Parent do
				clock.Text = Theme.stamp()
				task.wait(1)
			end
		end)
	end
	return w
end

function Theme.rule(props: { [string]: any }): Frame
	local p = {
		BackgroundColor3 = Theme.Color.Text,
		BackgroundTransparency = 0.65,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 1),
	}
	for k, v in props do
		p[k] = v
	end
	if p.Size.Y.Offset > 1 and p.Size.Y.Scale == 0 then
		p.Size = UDim2.new(p.Size.X.Scale, p.Size.X.Offset, 0, 1)
	end
	return make("Frame", p)
end

-- a meter like the camera's battery: an outline with thin blocks inside; returns frame + setter
function Theme.bar(props: { [string]: any }, color: Color3?): (Frame, (number) -> ())
	local p = {
		BackgroundColor3 = Theme.Color.Shadow,
		BackgroundTransparency = 0.6,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(120, 8),
	}
	for k, v in props do
		p[k] = v
	end
	if p.Size.Y.Offset < 8 and p.Size.Y.Scale == 0 then
		p.Size = UDim2.new(p.Size.X.Scale, p.Size.X.Offset, 0, 8)
	end
	local back = make("Frame", p)
	make("UIStroke", { Color = Theme.Color.Text, Thickness = 1, Transparency = 0.2, Parent = back })
	local fill = make("Frame", {
		Name = "Fill",
		BackgroundColor3 = color or Theme.Color.Text,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(2, 2),
		Size = UDim2.new(0, 0, 1, -4),
		Parent = back,
	})
	local STEPS = 24
	for i = 1, STEPS - 1 do
		make("Frame", { BorderSizePixel = 0, BackgroundColor3 = Theme.Color.Shadow, BackgroundTransparency = 0.2, Size = UDim2.new(0, 1, 1, 0),
			Position = UDim2.new(i / STEPS, 0, 0, 0), ZIndex = back.ZIndex + 2, Parent = back })
	end
	return back, function(v: number)
		local k = math.floor(math.clamp(v, 0, 1) * STEPS + 0.5) / STEPS
		fill.Size = UDim2.new(k, -4 * k, 1, -4)
	end
end

-- a small caption with the red camera square in front
function Theme.caption(text: string, props: { [string]: any }?): Frame
	local f = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(360, 16) })
	make("Frame", { BackgroundColor3 = Theme.Color.Alert, BorderSizePixel = 0, Size = UDim2.fromOffset(7, 7), Position = UDim2.new(0, 0, 0.5, -3), Parent = f })
	Theme.label({
		Name = "Text",
		Text = string.upper(text),
		TextSize = 13,
		TextColor3 = Theme.Color.Dim,
		Size = UDim2.new(1, -16, 1, 0),
		Position = UDim2.fromOffset(16, 0),
		Parent = f,
	})
	if props then
		for k, v in props do
			(f :: any)[k] = v
		end
	end
	return f
end

-- the blink every cursor shares
local blinkOn = true
task.spawn(function()
	while true do
		task.wait(0.45)
		blinkOn = not blinkOn
	end
end)

--[[
	Camcorder menu line: dim text; under the mouse (or selected) it goes inverse, black on a white bar,
	with a > in front. opts = { text, size, textSize, onClick, align, index, audio, position, parent }
]]
function Theme.button(opts): (TextButton, (boolean) -> ())
	local Audio = opts.audio
	local btn = make("TextButton", {
		Name = opts.name or opts.text,
		AutoButtonColor = false,
		BackgroundColor3 = Theme.Color.Raised,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = "",
		Size = opts.size or UDim2.fromOffset(240, 34),
		Position = opts.position or UDim2.new(),
		Parent = opts.parent,
	})
	local h = (opts.size and opts.size.Y.Offset) or 34
	local textSize = math.clamp(math.floor((opts.textSize or 15) * 0.85), 12, 30)
	local cursor = Theme.label({ Name = "Cursor", Text = ">", TextSize = textSize, FontFace = MONO_BOLD, TextColor3 = Theme.Color.Shadow, TextTransparency = 1,
		Outline = false, Size = UDim2.new(0, 18, 1, 0), Position = UDim2.fromOffset(10, 0), Parent = btn })
	local left = 32
	local index
	if opts.index then
		index = Theme.label({ Name = "Index", Text = opts.index, TextSize = math.max(11, math.floor(textSize * 0.6)), TextColor3 = Theme.Color.Faint,
			Size = UDim2.new(0, 30, 1, 0), Position = UDim2.fromOffset(left, 0), Parent = btn })
		left += 34
	end
	local label = Theme.label({
		Name = "Label",
		Text = string.upper(opts.text),
		TextSize = textSize,
		FontFace = MONO,
		TextColor3 = Theme.Color.Dim,
		TextXAlignment = opts.align or Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, -left - 10, 1, 0),
		Position = UDim2.fromOffset(left, 0),
		Parent = btn,
	})
	local outline = label:FindFirstChild("TextOutline") :: UIStroke?
	local selected, hovered, enabled = false, false, true
	local function refresh()
		local on = (selected or hovered) and enabled
		btn.BackgroundTransparency = if on then 0.05 else 1
		label.TextColor3 = (not enabled and Theme.Color.Faint) or (on and Theme.Color.Shadow) or Theme.Color.Dim
		label.FontFace = if on then MONO_BOLD else MONO
		if outline then
			outline.Enabled = not on
		end
		if index then
			index.TextColor3 = if on then Color3.fromRGB(90, 90, 86) else Theme.Color.Faint
			local io = index:FindFirstChild("TextOutline") :: UIStroke?
			if io then
				io.Enabled = not on
			end
		end
		cursor.TextTransparency = if on then 0 else 1
	end
	task.spawn(function()
		while btn.Parent do
			if (selected or hovered) and enabled then
				cursor.TextTransparency = if blinkOn then 0 else 1
			end
			task.wait(0.1)
		end
	end)
	btn.MouseEnter:Connect(function()
		hovered = true
		refresh()
		if Audio and enabled then
			Audio.ui("hover")
		end
	end)
	btn.MouseLeave:Connect(function()
		hovered = false
		refresh()
	end)
	btn.Activated:Connect(function()
		if not enabled then
			return
		end
		if Audio then
			Audio.ui("click")
		end
		if opts.onClick then
			opts.onClick()
		end
	end)
	local api = function(isSelected: boolean)
		selected = isSelected
		refresh()
	end
	btn:SetAttribute("Enabled", true)
	btn:GetAttributeChangedSignal("Enabled"):Connect(function()
		enabled = btn:GetAttribute("Enabled") ~= false
		refresh()
	end)
	local _ = h
	return btn, api
end

-- a command (TAKE / CLOSE / ACCEPT): a thin white frame round the word; primary is solid white with
-- black text; under the mouse it goes inverse
function Theme.action(opts): TextButton
	local Audio = opts.audio
	local btn = make("TextButton", {
		Name = opts.name or "Action",
		AutoButtonColor = false,
		BackgroundColor3 = Theme.Color.Raised,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = string.upper(opts.text or ""),
		TextColor3 = Theme.Color.Text,
		FontFace = MONO_BOLD,
		TextSize = 14,
		Size = opts.size or UDim2.fromOffset(104, 28),
		Position = opts.position or UDim2.new(),
		AnchorPoint = opts.anchor or Vector2.zero,
		Parent = opts.parent,
	})
	local frame = make("UIStroke", { Color = Theme.Color.Text, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = btn })
	local hovered = false
	local function style()
		local state = btn:GetAttribute("State") or "normal"
		local solid = (state == "primary") ~= hovered
		if state == "disabled" then
			btn.BackgroundTransparency = 1
			btn.TextColor3 = Theme.Color.Faint
			frame.Color = Theme.Color.LineSoft
			return
		end
		frame.Color = Theme.Color.Text
		if state == "active" then
			btn.BackgroundColor3 = Theme.Color.Accent
			btn.BackgroundTransparency = 0
			btn.TextColor3 = Theme.Color.Shadow
		elseif solid then
			btn.BackgroundColor3 = Theme.Color.Raised
			btn.BackgroundTransparency = 0
			btn.TextColor3 = Theme.Color.Shadow
		else
			btn.BackgroundTransparency = 0.55
			btn.BackgroundColor3 = Theme.Color.Shadow
			btn.TextColor3 = Theme.Color.Text
		end
	end
	btn:GetAttributeChangedSignal("State"):Connect(style)
	style()
	btn.MouseEnter:Connect(function()
		if btn:GetAttribute("State") ~= "disabled" then
			hovered = true
			style()
			if Audio then
				Audio.ui("hover")
			end
		end
	end)
	btn.MouseLeave:Connect(function()
		hovered = false
		style()
	end)
	btn.Activated:Connect(function()
		if btn:GetAttribute("State") == "disabled" then
			return
		end
		if Audio then
			Audio.ui("click")
		end
		if opts.onClick then
			opts.onClick()
		end
	end)
	return btn
end

return Theme
