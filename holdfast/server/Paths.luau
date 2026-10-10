local RS = game:GetService("ReplicatedStorage")
local Grid = require(RS.Hold.Grid)

local Paths = {}

local N = Grid.N
local CELLS = N * N
local SQRT2 = math.sqrt(2)

Paths.FREE = 0
Paths.NODE = 1
Paths.SOLID = 2
Paths.WALL = 3
Paths.GATE = 4

local kind = table.create(CELLS, 0)
local ref: { any } = table.create(CELLS, false)
Paths.kind = kind
Paths.ref = ref

local flowDist = table.create(CELLS, math.huge)
Paths.flowDist = flowDist
local flowDirty = true
local flowGoals: { number } = {}

local DX = { 1, -1, 0, 0, 1, 1, -1, -1 }
local DZ = { 0, 0, 1, -1, 1, -1, 1, -1 }
local COST = { 1, 1, 1, 1, SQRT2, SQRT2, SQRT2, SQRT2 }

function Paths.reset()
	for i = 1, CELLS do
		kind[i] = 0
		ref[i] = false
	end
	flowDirty = true
end

function Paths.mark(cx: number, cz: number, w: number, h: number, k: number, r: any)
	for x = cx, cx + w - 1 do
		for z = cz, cz + h - 1 do
			if Grid.inBounds(x, z) then
				local i = Grid.idx(x, z)
				kind[i] = k
				ref[i] = r
			end
		end
	end
	if k ~= Paths.NODE then
		flowDirty = true
	end
end

function Paths.clear(cx: number, cz: number, w: number, h: number)
	Paths.mark(cx, cz, w, h, 0, false)
	flowDirty = true
end

function Paths.areaFree(cx: number, cz: number, w: number, h: number): boolean
	for x = cx, cx + w - 1 do
		for z = cz, cz + h - 1 do
			if not Grid.inBounds(x, z) or x < 1 or z < 1 or x > N - 2 or z > N - 2 then
				return false
			end
			if kind[Grid.idx(x, z)] ~= 0 then
				return false
			end
		end
	end
	return true
end

function Paths.allyPass(i: number): boolean
	local k = kind[i]
	return k == 0 or k == 4
end

function Paths.cellAllyPass(cx: number, cz: number): boolean
	if not Grid.inBounds(cx, cz) then
		return false
	end
	return Paths.allyPass(Grid.idx(cx, cz))
end

function Paths.cellFree(cx: number, cz: number): boolean
	if not Grid.inBounds(cx, cz) then
		return false
	end
	return kind[Grid.idx(cx, cz)] == 0
end

local heapI: { number } = {}
local heapF: { number } = {}
local heapN = 0

local function hpush(i: number, f: number)
	heapN += 1
	local k = heapN
	heapI[k] = i
	heapF[k] = f
	while k > 1 do
		local p = k // 2
		if heapF[p] <= heapF[k] then
			break
		end
		heapI[p], heapI[k] = heapI[k], heapI[p]
		heapF[p], heapF[k] = heapF[k], heapF[p]
		k = p
	end
end

local function hpop(): number
	local top = heapI[1]
	heapI[1] = heapI[heapN]
	heapF[1] = heapF[heapN]
	heapN -= 1
	local k = 1
	while true do
		local l, r = k * 2, k * 2 + 1
		local s = k
		if l <= heapN and heapF[l] < heapF[s] then
			s = l
		end
		if r <= heapN and heapF[r] < heapF[s] then
			s = r
		end
		if s == k then
			break
		end
		heapI[s], heapI[k] = heapI[k], heapI[s]
		heapF[s], heapF[k] = heapF[k], heapF[s]
		k = s
	end
	return top
end

local gScore = table.create(CELLS, 0)
local came = table.create(CELLS, 0)
local stamp = table.create(CELLS, 0)
local closedStamp = table.create(CELLS, 0)
local gen = 0

function Paths.nearestPassable(cx: number, cz: number, maxR: number?): (number?, number?)
	if Paths.cellAllyPass(cx, cz) then
		return cx, cz
	end
	for r = 1, maxR or 12 do
		local best, bd = nil, math.huge
		for x = cx - r, cx + r do
			for z = cz - r, cz + r do
				if (math.abs(x - cx) == r or math.abs(z - cz) == r) and Paths.cellAllyPass(x, z) then
					local d = (x - cx) ^ 2 + (z - cz) ^ 2
					if d < bd then
						bd = d
						best = { x, z }
					end
				end
			end
		end
		if best then
			return best[1], best[2]
		end
	end
	return nil, nil
end

function Paths.ringCells(cx: number, cz: number, w: number, h: number): { number }
	local out = {}
	for x = cx - 1, cx + w do
		for z = cz - 1, cz + h do
			if (x == cx - 1 or x == cx + w or z == cz - 1 or z == cz + h) and Paths.cellAllyPass(x, z) then
				table.insert(out, Grid.idx(x, z))
			end
		end
	end
	return out
end

function Paths.find(sx: number, sz: number, goals: { number }, maxIter: number?): { number }?
	if #goals == 0 or not Grid.inBounds(sx, sz) then
		return nil
	end
	gen += 1
	local goalSet = {}
	local gxs, gzs = 0, 0
	for _, g in goals do
		goalSet[g] = true
		local x, z = Grid.fromIdx(g)
		gxs += x
		gzs += z
	end
	local gx, gz = gxs / #goals, gzs / #goals
	local start = Grid.idx(sx, sz)
	if goalSet[start] then
		return { start }
	end
	heapN = 0
	stamp[start] = gen
	gScore[start] = 0
	came[start] = 0
	hpush(start, 0)
	local iter = 0
	local limit = maxIter or 9000
	local bestI, bestH = start, math.huge
	while heapN > 0 do
		local cur = hpop()
		if closedStamp[cur] ~= gen then
			closedStamp[cur] = gen
			if goalSet[cur] then
				local path = {}
				local c = cur
				while c ~= 0 do
					table.insert(path, 1, c)
					c = came[c]
				end
				return path
			end
			iter += 1
			if iter > limit then
				break
			end
			local cx, cz = Grid.fromIdx(cur)
			local hh = math.abs(cx - gx) + math.abs(cz - gz)
			if hh < bestH then
				bestH = hh
				bestI = cur
			end
			for d = 1, 8 do
				local nx, nz = cx + DX[d], cz + DZ[d]
				if Grid.inBounds(nx, nz) then
					local ni = Grid.idx(nx, nz)
					local ok = Paths.allyPass(ni)
					if ok and d > 4 then
						ok = Paths.allyPass(Grid.idx(cx + DX[d], cz)) and Paths.allyPass(Grid.idx(cx, cz + DZ[d]))
					end
					if ok and closedStamp[ni] ~= gen then
						local g = gScore[cur] + COST[d]
						if stamp[ni] ~= gen or g < gScore[ni] then
							stamp[ni] = gen
							gScore[ni] = g
							came[ni] = cur
							local ddx, ddz = math.abs(nx - gx), math.abs(nz - gz)
							local h = math.max(ddx, ddz) + (SQRT2 - 1) * math.min(ddx, ddz)
							hpush(ni, g + h * 1.05)
						end
					end
				end
			end
		end
	end
	if bestI ~= start then
		local path = {}
		local c = bestI
		while c ~= 0 do
			table.insert(path, 1, c)
			c = came[c]
		end
		return path
	end
	return nil
end

function Paths.losClear(ax: number, az: number, bx: number, bz: number): boolean
	local dx, dz = bx - ax, bz - az
	local dist = math.sqrt(dx * dx + dz * dz)
	local steps = math.ceil(dist / (Grid.C * 0.35))
	if steps == 0 then
		return true
	end
	for s = 1, steps do
		local t = s / steps
		local x, z = ax + dx * t, az + dz * t
		for _, o in { { 0.9, 0.9 }, { -0.9, 0.9 }, { 0.9, -0.9 }, { -0.9, -0.9 } } do
			local cx, cz = Grid.toCell(x + o[1], z + o[2])
			if not Paths.cellAllyPass(cx, cz) then
				return false
			end
		end
	end
	return true
end

function Paths.setFlowGoals(goals: { number })
	flowGoals = goals
	flowDirty = true
end

function Paths.markFlowDirty()
	flowDirty = true
end

function Paths.updateFlow(structCost: (any) -> number): boolean
	if not flowDirty then
		return false
	end
	flowDirty = false
	for i = 1, CELLS do
		flowDist[i] = math.huge
	end
	heapN = 0
	for _, g in flowGoals do
		flowDist[g] = 0
		hpush(g, 0)
	end
	gen += 1
	while heapN > 0 do
		local cur = hpop()
		if closedStamp[cur] ~= gen then
			closedStamp[cur] = gen
			local cx, cz = Grid.fromIdx(cur)
			local base = flowDist[cur]
			for d = 1, 8 do
				local nx, nz = cx + DX[d], cz + DZ[d]
				if Grid.inBounds(nx, nz) then
					local ni = Grid.idx(nx, nz)
					local k = kind[ni]
					if k ~= 1 and closedStamp[ni] ~= gen then
						local ok = true
						if d > 4 then
							ok = kind[Grid.idx(cx + DX[d], cz)] == 0 and kind[Grid.idx(cx, cz + DZ[d])] == 0
						end
						if ok then
							local c = COST[d]
							if k ~= 0 and flowDist[ni] ~= 0 then
								c += structCost(ref[ni])
							end
							local nd = base + c
							if nd < flowDist[ni] then
								flowDist[ni] = nd
								hpush(ni, nd)
							end
						end
					end
				end
			end
		end
	end
	return true
end

function Paths.flowStep(cx: number, cz: number): (number?, number?)
	if not Grid.inBounds(cx, cz) then
		return nil, nil
	end
	local here = flowDist[Grid.idx(cx, cz)]
	local best, bx, bz = here, nil, nil
	for d = 1, 8 do
		local nx, nz = cx + DX[d], cz + DZ[d]
		if Grid.inBounds(nx, nz) then
			local ni = Grid.idx(nx, nz)
			local ok = true
			if d > 4 then
				ok = kind[Grid.idx(cx + DX[d], cz)] == 0 and kind[Grid.idx(cx, cz + DZ[d])] == 0
			end
			if ok then
				local v = flowDist[ni] + (if d > 4 then 0.01 else 0)
				if v < best then
					best = v
					bx, bz = nx, nz
				end
			end
		end
	end
	return bx, bz
end

return Paths
