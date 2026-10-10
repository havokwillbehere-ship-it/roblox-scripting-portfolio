--[[
	Moving players between the two places of KREMINNA:
		bunker (lobby place)  --top of the stairs-->  Trenches (Config.Places.Trenches)
		Trenches              --killed----------->    bunker
	TeleportData carries the rifle each player picked and the kit he carries (Profile.kit). Teleports can't run in Studio, so the callers
	fall back (the stairs drop you on the local test field, a death in Trenches respawns you there).
]]

local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("SniperKit"):WaitForChild("Config"))

local Travel = {}
Travel.onFailed = nil :: ((Player) -> ())?

-- the stairs lead to the Trenches place (live servers only)
function Travel.enabled(): boolean
	return Config.Places.Trenches ~= 0 and not RunService:IsStudio() and not Config.isField()
end

local function teleport(placeId: number, players: { Player }, data: { [string]: any }, reserve: boolean): boolean
	local options = Instance.new("TeleportOptions")
	if reserve then
		options.ShouldReserveServer = true
	end
	options:SetTeleportData(data)
	for attempt = 1, 3 do
		local ok, err = pcall(function()
			return TeleportService:TeleportAsync(placeId, players, options)
		end)
		if ok then
			return true
		end
		warn(string.format("[KREMINNA] teleport to %d, attempt %d failed: %s", placeId, attempt, tostring(err)))
		task.wait(attempt * 1.5)
	end
	return false
end

-- send a squad up together, each with their rifle
function Travel.toTrenches(players: { Player }, kits: { [string]: any }?): boolean
	local loadouts = {}
	for _, p in players do
		loadouts[tostring(p.UserId)] = p:GetAttribute("Loadout")
	end
	return teleport(Config.Places.Trenches, players, { loadouts = loadouts, kits = kits or {}, lobby = game.PlaceId }, Config.Places.SameExperience)
end

-- back down to the bunker (false in Studio or when there is nowhere to go back to); extra goes in
-- the TeleportData too (the mission's pay: { earned = n })
function Travel.toLobby(player: Player, extra: { [string]: any }?): boolean
	if RunService:IsStudio() then
		return false
	end
	local id = Config.Places.Lobby
	if id == 0 then
		local join = player:GetJoinData()
		local td = join.TeleportData
		id = (type(td) == "table" and tonumber(td.lobby)) or join.SourcePlaceId or 0
	end
	if id == 0 then
		return false
	end
	local data = { loadout = player:GetAttribute("Loadout") }
	for k, v in extra or {} do
		data[k] = v
	end
	return teleport(id, { player }, data, false)
end

-- a DirectJoin mission over: on to a fresh server of this same place (a new city, everyone alive
-- again). Everybody leaving this server goes to the same new one, so a squad stays together
local againCode: string? = nil
function Travel.again(player: Player, data: { [string]: any }?): boolean
	if RunService:IsStudio() then
		return false
	end
	if not againCode then
		local ok, code = pcall(function()
			return TeleportService:ReserveServer(game.PlaceId)
		end)
		if not ok then
			warn("[KREMINNA] could not reserve a fresh server: " .. tostring(code))
			return false
		end
		againCode = code
	end
	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = againCode :: string
	options:SetTeleportData(data or {})
	for attempt = 1, 3 do
		local ok, err = pcall(function()
			return TeleportService:TeleportAsync(game.PlaceId, { player }, options)
		end)
		if ok then
			return true
		end
		warn(string.format("[KREMINNA] teleport to a fresh server, attempt %d failed: %s", attempt, tostring(err)))
		task.wait(attempt * 1.5)
	end
	return false
end

-- what a player carried up with him (Profile.kit), if he came up the stairs
function Travel.arrivingKit(player: Player): { [string]: any }?
	local td = player:GetJoinData().TeleportData
	if type(td) == "table" and type(td.kits) == "table" and type(td.kits[tostring(player.UserId)]) == "table" then
		return td.kits[tostring(player.UserId)]
	end
	return nil
end

-- the rifle a player brought with them through a teleport, if any
function Travel.arrivingLoadout(player: Player): string?
	local td = player:GetJoinData().TeleportData
	if type(td) ~= "table" then
		return nil
	end
	if type(td.loadouts) == "table" and type(td.loadouts[tostring(player.UserId)]) == "string" then
		return td.loadouts[tostring(player.UserId)]
	end
	if type(td.loadout) == "string" then
		return td.loadout
	end
	return nil
end

-- the teleport was accepted but the player never left (place down, full, not allowed...)
TeleportService.TeleportInitFailed:Connect(function(player: Player, result, message)
	warn(string.format("[KREMINNA] teleport failed for %s: %s %s", player.Name, tostring(result), tostring(message)))
	if Travel.onFailed then
		Travel.onFailed(player)
	end
end)

return Travel
