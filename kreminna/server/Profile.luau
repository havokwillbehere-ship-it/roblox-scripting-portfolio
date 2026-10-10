--[[
	Your stash, kept by the bunker's place (DataStore "KreminnaProfile", key u<UserId>):

		money     what you have to spend
		rifles    { [rifleId] = true }   bought once, kept
		ammo      { [ammoId] = rounds }  per calibre (Config.Economy.Ammo)
		items     { bandage, sandbag, bush = count }
		ghillie   owned; wearGhillie: switched on in your inventory
		runs      the last few missions paid out (so a pay can never be credited twice)

	A new profile starts from Config.Economy.Start, plus whatever the old bank (KreminnaBank) held.

	Profile.arrive(player)          on joining the bunker: load, then the mission you came back from
	                                (TeleportData: earned, kit = what you didn't use, run = its id)
	Profile.kit(player)             what he carries up the stairs (taken out of the stash and saved)
	Profile.refund(player, kit)     the teleport failed: it goes back
	Profile.request(player, ...)    the client's "Economy" remote: Buy / Loadout / Ghillie
	The client is sent a snapshot ("Profile", data) whenever it changes; Money is also an attribute.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = ReplicatedStorage:WaitForChild("SniperKit")
local Config = require(Kit:WaitForChild("Config"))
local E = Config.Economy

local Profile = {}

local store, oldBank = nil, nil
pcall(function()
	store = DataStoreService:GetDataStore("KreminnaProfile")
	oldBank = DataStoreService:GetDataStore("KreminnaBank")
end)

type Data = {
	money: number,
	rifles: { [string]: boolean },
	ammo: { [string]: number },
	items: { [string]: number },
	ghillie: boolean,
	wearGhillie: boolean,
	runs: { string },
}

local profiles: { [Player]: Data } = {}
local remote: RemoteEvent

local function fresh(): Data
	return {
		money = E.Start.money,
		rifles = table.clone(E.Start.rifles),
		ammo = table.clone(E.Start.ammo),
		items = table.clone(E.Start.items),
		ghillie = false,
		wearGhillie = false,
		runs = {},
	}
end

-- whatever was saved, made whole (missing fields filled, numbers sane)
local function clean(d: any): Data
	local f = fresh()
	if type(d) ~= "table" then
		return f
	end
	f.money = math.max(0, math.floor(tonumber(d.money) or f.money))
	if type(d.rifles) == "table" then
		for id, v in d.rifles do
			if Config.RifleById[id] and v then
				f.rifles[id] = true
			end
		end
	end
	if type(d.ammo) == "table" then
		for id, n in d.ammo do
			if E.Ammo[id] then
				f.ammo[id] = math.max(0, math.floor(tonumber(n) or 0))
			end
		end
	end
	if type(d.items) == "table" then
		for id, n in d.items do
			if E.Items[id] and E.Items[id].kind ~= "outfit" then
				f.items[id] = math.max(0, math.floor(tonumber(n) or 0))
			end
		end
	end
	f.ghillie = d.ghillie == true
	f.wearGhillie = f.ghillie and d.wearGhillie == true
	f.runs = if type(d.runs) == "table" then d.runs else {}
	f.rifles.hunter = true -- (the starter rifle is always yours)
	return f
end

local function key(player: Player): string
	return "u" .. player.UserId
end

-- the snapshot the client draws its stores and inventory from
local function send(player: Player)
	local d = profiles[player]
	if not d then
		return
	end
	player:SetAttribute("Money", d.money)
	player:SetAttribute("Ghillie", d.wearGhillie)
	if remote then
		remote:FireClient(player, "Profile", {
			money = d.money,
			rifles = d.rifles,
			ammo = d.ammo,
			items = d.items,
			ghillie = d.ghillie,
			wearGhillie = d.wearGhillie,
			loadout = player:GetAttribute("Loadout"),
		})
	end
end

-- write it out (UpdateAsync with our copy: this server is the only one editing it while he is here)
local pending: { [Player]: boolean } = {}
local function save(player: Player)
	local d = profiles[player]
	if not d or not store then
		return
	end
	local ok, err = pcall(function()
		store:UpdateAsync(key(player), function()
			return d
		end)
	end)
	if not ok then
		warn("[KREMINNA] profile: could not save " .. player.Name .. ": " .. tostring(err))
	end
end

-- saved a moment after a change (a few purchases in a row make one write)
local function dirty(player: Player)
	send(player)
	if pending[player] then
		return
	end
	pending[player] = true
	task.delay(3, function()
		pending[player] = nil
		if player.Parent then
			save(player)
		end
	end)
end

function Profile.get(player: Player): Data?
	return profiles[player]
end

function Profile.arrive(player: Player)
	local loaded: any = nil
	if store then
		local ok, result = pcall(function()
			return store:GetAsync(key(player))
		end)
		if ok then
			loaded = result
		else
			warn("[KREMINNA] profile: could not load " .. player.Name .. ": " .. tostring(result))
		end
	end
	local d = clean(loaded)
	if loaded == nil and oldBank then
		-- first time on the new stash: bring the old bank balance over
		local ok, old = pcall(function()
			return oldBank:GetAsync(key(player))
		end)
		if ok and tonumber(old) then
			d.money += math.max(0, math.floor(tonumber(old) :: number))
		end
	end
	if not player.Parent then
		return
	end
	-- back from a mission: the pay and what he didn't use, once per mission
	local td = player:GetJoinData().TeleportData
	if type(td) == "table" then
		local run = if type(td.run) == "string" then td.run else nil
		if run == nil or not table.find(d.runs, run) then
			local earned = math.clamp(math.floor(tonumber(td.earned) or 0), 0, 100000)
			d.money += earned
			if earned > 0 then
				player:SetAttribute("LastEarned", earned)
			end
			local back = td.kit
			if type(back) == "table" then
				local rifle = Config.RifleById[tostring(back.rifle or "")]
				local ammoId = rifle and E.RifleAmmo[rifle.id]
				if ammoId then
					d.ammo[ammoId] = (d.ammo[ammoId] or 0) + math.clamp(math.floor(tonumber(back.rounds) or 0), 0, E.Carry.rounds)
				end
				for _, id in E.CarryItems do
					d.items[id] = (d.items[id] or 0) + math.clamp(math.floor(tonumber(back[id]) or 0), 0, E.Carry[id])
				end
			end
			if run then
				table.insert(d.runs, run)
				while #d.runs > 12 do
					table.remove(d.runs, 1)
				end
			end
		end
	end
	profiles[player] = d
	-- the rifle you brought back (or any you own) is your loadout
	local want = player:GetAttribute("Loadout")
	if type(want) ~= "string" or not d.rifles[want] then
		player:SetAttribute("Loadout", "hunter")
	end
	send(player)
	save(player)
end

-- what he takes up: his loadout rifle, its calibre up to the carry limit, and the rest up to theirs.
-- Taken out of the stash now (and saved) so it can't be spent twice
function Profile.kit(player: Player): { [string]: any }
	local d = profiles[player]
	local rifleId = player:GetAttribute("Loadout")
	if not d then
		return { rifle = rifleId or "hunter", rounds = 0, bandage = 0, sandbag = 0, bush = 0, drone = 0, airstrike = 0, kaboom = 0, ghillie = false }
	end
	if type(rifleId) ~= "string" or not d.rifles[rifleId] then
		rifleId = "hunter"
	end
	local ammoId = E.RifleAmmo[rifleId]
	local kit = { rifle = rifleId, ghillie = d.ghillie and d.wearGhillie }
	kit.rounds = math.min(d.ammo[ammoId] or 0, E.Carry.rounds)
	d.ammo[ammoId] = (d.ammo[ammoId] or 0) - kit.rounds
	for _, id in E.CarryItems do
		kit[id] = math.min(d.items[id] or 0, E.Carry[id])
		d.items[id] = (d.items[id] or 0) - kit[id]
	end
	send(player)
	save(player)
	return kit
end

function Profile.refund(player: Player, kit: { [string]: any }?)
	local d = profiles[player]
	if not d or type(kit) ~= "table" then
		return
	end
	local ammoId = E.RifleAmmo[kit.rifle or ""]
	if ammoId then
		d.ammo[ammoId] = (d.ammo[ammoId] or 0) + (kit.rounds or 0)
	end
	for _, id in E.CarryItems do
		d.items[id] = (d.items[id] or 0) + (kit[id] or 0)
	end
	dirty(player)
end

-- out there (the Trenches, or the bunker's test field): what he carries, as attributes the game reads
--   Loadout, Rounds (the server counts them down per shot), Bandages, Sandbags, Bushes, Ghillie
function Profile.apply(player: Player, kit: { [string]: any })
	if type(kit.rifle) == "string" and Config.RifleById[kit.rifle] then
		player:SetAttribute("Loadout", kit.rifle)
	end
	player:SetAttribute("Rounds", math.max(0, math.floor(tonumber(kit.rounds) or 0)))
	player:SetAttribute("Bandages", math.max(0, math.floor(tonumber(kit.bandage) or 0)))
	player:SetAttribute("Sandbags", math.max(0, math.floor(tonumber(kit.sandbag) or 0)))
	player:SetAttribute("Bushes", math.max(0, math.floor(tonumber(kit.bush) or 0)))
	player:SetAttribute("Drones", math.max(0, math.floor(tonumber(kit.drone) or 0)))
	player:SetAttribute("Airstrikes", math.max(0, math.floor(tonumber(kit.airstrike) or 0)))
	player:SetAttribute("Kabooms", math.max(0, math.floor(tonumber(kit.kaboom) or 0)))
	player:SetAttribute("DroneBattery", nil)
	player:SetAttribute("Ghillie", kit.ghillie == true)
end

-- the Studio test field / a Trenches arrival without a kit (Studio): a fixed kit to play with
function Profile.testKit(player: Player): { [string]: any }
	local k = table.clone(E.TestKit)
	k.rifle = player:GetAttribute("Loadout") or "hunter"
	k.ghillie = player:GetAttribute("Ghillie") == true
	return k
end

-- back in the bunker: nothing counted any more, the suit as his inventory has it
function Profile.home(player: Player)
	for _, a in { "Rounds", "Sandbags", "Bushes", "Drones", "DroneBattery", "Airstrikes", "Kabooms", "Nuked" } do
		player:SetAttribute(a, nil)
	end
	local d = profiles[player]
	player:SetAttribute("Ghillie", d ~= nil and d.wearGhillie)
end

-- what he still has on him (going home: it goes back in the stash)
function Profile.carried(player: Player): { [string]: any }
	return {
		rifle = player:GetAttribute("Loadout"),
		rounds = player:GetAttribute("Rounds") or 0,
		bandage = player:GetAttribute("Bandages") or 0,
		sandbag = player:GetAttribute("Sandbags") or 0,
		bush = player:GetAttribute("Bushes") or 0,
		drone = player:GetAttribute("Drones") or 0,
		airstrike = player:GetAttribute("Airstrikes") or 0,
		kaboom = player:GetAttribute("Kabooms") or 0,
	}
end

-- the stores and the inventory --------------------------------------------------------------------

local function spend(player: Player, d: Data, price: number): boolean
	if d.money < price then
		if remote then
			remote:FireClient(player, "Denied", "NOT ENOUGH MONEY")
		end
		return false
	end
	d.money -= price
	return true
end

function Profile.request(player: Player, action: any, a: any, b: any)
	local d = profiles[player]
	if not d or player:GetAttribute("InField") then
		return
	end
	if action == "Buy" then
		if a == "rifle" and type(b) == "string" and Config.RifleById[b] then
			if d.rifles[b] then
				return
			end
			if spend(player, d, E.RiflePrice[b] or 0) then
				d.rifles[b] = true
				player:SetAttribute("Loadout", b) -- bought it to use it
				remote:FireClient(player, "Bought", b)
			end
		elseif a == "ammo" and type(b) == "string" and E.Ammo[b] then
			local box = E.Ammo[b]
			if spend(player, d, box.price) then
				d.ammo[b] = (d.ammo[b] or 0) + box.box
				remote:FireClient(player, "Bought", b)
			end
		elseif a == "item" and type(b) == "string" and E.Items[b] then
			local item = E.Items[b]
			if item.kind == "outfit" then
				if d.ghillie then
					return
				end
				if spend(player, d, item.price) then
					d.ghillie = true
					d.wearGhillie = true
					remote:FireClient(player, "Bought", b)
				end
			elseif spend(player, d, item.price) then
				d.items[b] = (d.items[b] or 0) + 1
				remote:FireClient(player, "Bought", b)
			end
		end
		dirty(player)
	elseif action == "Loadout" then
		if type(a) == "string" and d.rifles[a] then
			player:SetAttribute("Loadout", a)
			dirty(player)
		end
	elseif action == "Ghillie" then
		d.wearGhillie = d.ghillie and a == true
		dirty(player)
	elseif action == "Sync" then
		send(player)
	end
end

function Profile.init(r: RemoteEvent)
	remote = r
	r.OnServerEvent:Connect(Profile.request)
	Players.PlayerRemoving:Connect(function(p)
		if profiles[p] then
			save(p)
			profiles[p] = nil
		end
		pending[p] = nil
	end)
	game:BindToClose(function()
		for p in profiles do
			task.spawn(save, p)
		end
		task.wait(2)
	end)
end

return Profile
