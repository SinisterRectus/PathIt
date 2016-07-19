local uv = require('luv')
local format = string.format
local random = math.random
local floor = math.floor
local char = string.char

local host = '127.0.0.1'
local port = 7780

local queue = Deque()

local function encodeNumber(n)
	n = n + 32768
	assert(0 <= n and n <= 65535, 'number out of range')
	return char(floor(n % 256), floor(n / 256 % 256))
end

local function decodeNumber(s)
	local a, b = s:byte(1, 2)
	return a + 256 * b - 32768
end

local function encodeVector(v)
	local x = encodeNumber(v.x)
	local y = encodeNumber(v.y)
	local z = encodeNumber(v.z)
	return x .. y .. z
end

local function decodeVector(s)
	local x = decodeNumber(s:sub(1, 2))
	local y = decodeNumber(s:sub(3, 4))
	local z = decodeNumber(s:sub(5, 6))
	return Vector3(x, y, z)
end

local n = 0
local ready = false
local server = uv.new_tcp()
print('connecting')
server:connect(host, port, function(err)
	assert(not err, err)
	print('connected')
	server:read_start(function(err, data)
		if data then
			ready = data == 'ready'
		else
			print(err)
			server:shutdown()
			server:close()
			print('disconnected')
		end
	end)
	uv.new_idle():start(function()
		n = n + 1
		if n > 10 then return end
		print(n)
		local v1 = Vector3(random(-16384, 16383), random(-16384, 16383), random(-16384, 16383))
		local v2 = Vector3(v1.x + random(-128, 128), v1.y + random(-128, 128), v1.z + random(-128, 128))
		queue:pushRight(encodeVector(v1) .. encodeVector(v2))
	end)
end)

uv.new_idle():start(function()
	if ready and queue:getCount() > 0 then
		ready = false
		server:write(queue:popLeft())
	end
end)

Events:Subscribe('PreTick', function() uv.run('nowait') end)