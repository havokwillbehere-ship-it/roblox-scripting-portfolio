local Pack = {}

Pack.Anim = {
	Idle = 0,
	Walk = 1,
	Chop = 2,
	Mine = 3,
	Build = 4,
	Melee = 5,
	Shoot = 6,
	Dead = 7,
}

local REC = 14

export type Row = {
	id: number,
	kind: number,
	slot: number,
	x: number,
	z: number,
	yaw: number,
	anim: number,
	hp: number,
	carry: number,
	carryN: number,
	tool: number,
}

function Pack.encode(rows: { Row }, t: number): buffer
	local n = #rows
	local b = buffer.create(6 + n * REC)
	buffer.writeu16(b, 0, n)
	buffer.writef32(b, 2, t)
	local o = 6
	for _, r in rows do
		buffer.writeu16(b, o, r.id)
		buffer.writeu8(b, o + 2, r.kind)
		buffer.writeu8(b, o + 3, r.slot)
		buffer.writei16(b, o + 4, math.clamp(math.round(r.x * 16), -32768, 32767))
		buffer.writei16(b, o + 6, math.clamp(math.round(r.z * 16), -32768, 32767))
		buffer.writeu8(b, o + 8, math.round((r.yaw % (2 * math.pi)) / (2 * math.pi) * 255))
		buffer.writeu8(b, o + 9, r.anim)
		buffer.writeu8(b, o + 10, math.clamp(math.round(r.hp * 255), 0, 255))
		buffer.writeu8(b, o + 11, r.carry)
		buffer.writeu8(b, o + 12, math.clamp(r.carryN, 0, 255))
		buffer.writeu8(b, o + 13, r.tool)
		o += REC
	end
	return b
end

function Pack.decode(b: buffer): ({ Row }, number)
	local n = buffer.readu16(b, 0)
	local t = buffer.readf32(b, 2)
	local rows = table.create(n)
	local o = 6
	for i = 1, n do
		rows[i] = {
			id = buffer.readu16(b, o),
			kind = buffer.readu8(b, o + 2),
			slot = buffer.readu8(b, o + 3),
			x = buffer.readi16(b, o + 4) / 16,
			z = buffer.readi16(b, o + 6) / 16,
			yaw = buffer.readu8(b, o + 8) / 255 * 2 * math.pi,
			anim = buffer.readu8(b, o + 9),
			hp = buffer.readu8(b, o + 10) / 255,
			carry = buffer.readu8(b, o + 11),
			carryN = buffer.readu8(b, o + 12),
			tool = buffer.readu8(b, o + 13),
		}
		o += REC
	end
	return rows, t
end

return Pack
