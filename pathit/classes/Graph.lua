local time = os.time
local open = io.open
local band = bit.band
local format = string.format
local min, max = math.min, math.max
local wrap, yield = coroutine.wrap, coroutine.yield
local floor, random = math.floor, math.random

local uv = require('uv')

local class = require('../class')
local enums = require('../enums')
local codecs = require('../codecs')
local config = require('../config')
local constants = require('../constants')

local Cell = require('./Cell')
local Deque = require('./Deque')
local Stream = require('./Stream')

local HUGE = math.huge
local MAP_OFFSET = constants.MAP_OFFSET

local directions = {
	{0x01, 0,-1}, -- forward
	{0x02, 0, 1}, -- backward
	{0x04,-1, 0}, -- left
	{0x08, 1, 0}, -- right
	{0x10,-1,-1}, -- forward left
	{0x20, 1, 1}, -- backward right
	{0x40, 1,-1}, -- forward right
	{0x80,-1, 1}, -- backward left
}

local Graph = class('Graph')

function Graph:__init()
	self.cells = {}
	self.cellCount = 0
	self.nodeCount = 0
	self.queue = Deque()
end

function Graph:addCell(cellX, cellY, count)
	local cells = self.cells
	local cell = Cell(cellX, cellY, count)
	cells[cellX] = cells[cellX] or {}
	cells[cellX][cellY] = cell
	return cell
end

function Graph:getCell(cellX, cellY)
	local cells = self.cells
	return cells[cellX] and cells[cellX][cellY] or nil
end

function Graph:getCellXYByPositionXZ(x, z)
	local cellSize = config.cellSize
	return floor((x + MAP_OFFSET) / cellSize), floor((z + MAP_OFFSET) / cellSize)
end

function Graph:getCellByPositionXZ(x, z)
	return self:getCell(self:getCellXYByPositionXZ(x, z))
end

function Graph:getRandomCell()
	local n, r = 1, random(self.cellCount)
	for cell in self:getCells() do
		if n == r then return cell end
		n = n + 1
	end
end

function Graph:getRandomNode()
	local n, r = 1, random(self.nodeCount)
	for node in self:getNodes() do
		if n == r then return node end
		n = n + 1
	end
end

function Graph:getCells()
	return wrap(function()
		for cellX, v in pairs(self.cells) do
			for cellY, cell in pairs(v) do
				yield(cell)
			end
		end
	end)
end

function Graph:getNodes()
	return wrap(function()
		for cell in self:getCells() do
			for node in cell:getNodes() do
				yield(node)
			end
		end
	end)
end

function Graph:getNearestCell(position)

	-- return the occupied cell if it is loaded
	local cell = self:getCellByPositionXZ(position.x, position.z)
	if cell then return cell end

	-- otherwise, find the nearest loaded cell
	local nearestDistance, nearestCell = HUGE
	for cell in self:getCells() do
		local distance = position:euclideanDistanceSquared(cell:getCenter())
		if distance < nearestDistance then
			nearestDistance = distance
			nearestCell = cell
		end
	end

	-- should only fail if no cells are loaded
	assert(nearestCell, 'No cell discovered')
	return nearestCell

end

function Graph:getNearestNode(position)

	local nearestCell = self:getNearestCell(position)
	local nearestNode = nearestCell:getNearestNode(position)

	-- should only fail if no nodes are loaded
	assert(nearestNode, 'No node discovered')
	return nearestNode

end

function Graph:getNeighbors(node)
	return wrap(function()
		local x, y, z, n = node.x, node.y, node.z, node.n
		local nodeSize = config.nodeSize
		for _, direction in ipairs(directions) do
			if band(n, direction[1]) > 0 then
				local nextX = x + direction[2] * nodeSize
				local nextZ = z + direction[3] * nodeSize
				local nextCell = self:getCellByPositionXZ(nextX, nextZ)
				if nextCell then
					local neighbor = nextCell:getNode(nextX, y, nextZ)
					if neighbor then yield(neighbor) end
				end
			end
		end
	end)
end

function Graph:unloadCell(cellX, cellY)
	local cells = self.cells
	local cell = cells[cellX] and cells[cellX][cellY]
	if not cell then return end
	cells[cellX][cellY] = nil
	if not next(cells[cellX]) then cells[cellX] = nil end
	self.cellCount = self.cellCount - 1
	self.nodeCount = self.nodeCount - cell.nodeCount
end

function Graph:loadCell(cellX, cellY)

	local path = format('./cells/%s_%s.cell', cellX, cellY)
	local file = open(path, 'rb')
	if not file then return end

	local stream = Stream(file)

	assert(stream:readByte() == cellX, 'Cell X mismatch')
	assert(stream:readByte() == cellY, 'Cell Y mismatch')

	local cellSize = config.cellSize
	local nodeSize = config.nodeSize

	assert(2 ^ stream:readByte() == cellSize, 'Cell size mismatch')
	assert(2 ^ stream:readByte() == nodeSize, 'Node size mismatch')

	local count = stream:readShort()
	local rootX = MAP_OFFSET - cellX * cellSize
	local rootZ = MAP_OFFSET - cellY * cellSize

	local cell = self:addCell(cellX, cellY, count)

	for i = 1, count do
		local x = stream:readByte()
		local z = stream:readByte()
		local y = stream:readShort()
		local n = stream:readByte()
		x = x * nodeSize - rootX
		z = z * nodeSize - rootZ
		cell:addNode(x, y, z, n)
	end

	stream:close()
	assert(cell.nodeCount == count, 'Nodes not loaded properly')

	self.cellCount = self.cellCount + 1
	self.nodeCount = self.nodeCount + cell.nodeCount

	return cell

end

function Graph:getPath(start, goal)

	local count = 0
	local frontier, visited = {}, {}
	local cameFrom, costSoFar = {}, {}

	costSoFar[start] = 0
	frontier[start] = start:getHeuristicCost(goal)

	while next(frontier) and count < config.visitedLimit do

		-- naive priority queue
		local lowest, current = HUGE
		for node, priority in pairs(frontier) do
			if priority < lowest then
				lowest = priority
				current = node
			end
		end

		frontier[current] = nil
		visited[current] = true
		count = count + 1

		if current == goal then
			local path = {current}
			while cameFrom[current] do
				current = cameFrom[current]
				path[#path + 1] = current
			end
			return path, visited
		end

		for neighbor in self:getNeighbors(current) do
			if not visited[neighbor] then
				local newCost = costSoFar[current] + current:getConnectedCost(neighbor)
				if not frontier[neighbor] or newCost < costSoFar[neighbor] then
					cameFrom[neighbor] = current
					costSoFar[neighbor] = newCost
					frontier[neighbor] = newCost + neighbor:getHeuristicCost(goal)
				end
			end
		end

	end

	return nil, visited -- no path found

end

function Graph:startServer(host, port)
	p('Starting path server...')
	local server = uv.new_tcp()
	server:bind(host, port)
	server:listen(256, function(err)
		assert(not err, err)
		local client = uv.new_tcp()
		server:accept(client)
		p('Path client connected')
		client:read_start(function(err, data)
			if data then
				self:processData(data, client)
			else
				client:shutdown()
				client:close()
				p('Path client disconnected: ' .. err)
			end
		end)
		client:write('ready')
	end)
	p(format('Listening for connections at %s on port %s', host, port))
	self.server = server

end

function Graph:processData(data, client)

	local v1 = codecs.decodeVector(data:sub(1, 6))
	local v2 = codecs.decodeVector(data:sub(7, 12))
	local cellX1, cellY1 = self:getCellXYByPositionXZ(v1.x, v1.z)
	local cellX2, cellY2 = self:getCellXYByPositionXZ(v2.x, v2.z)
	local minX, maxX = min(cellX1, cellX2), max(cellX1, cellX2)
	local minY, maxY = min(cellY1, cellY2), max(cellY1, cellY2)

	if maxX - minX > 1 or maxY - minY > 1 then
		client:write('too far')
	else
		for x = minX, maxX do
			for y = minY, maxY do
				local cell = self:getCell(x, y)
				if cell then
					cell.lastVisited = time()
				else
					cell = self:loadCell(x, y)
				end
			end
		end
		local n1 = self:getNearestNode(v1)
		local n2 = self:getNearestNode(v2)
		local path, visited = self:getPath(n1, n2)
		p(path and #path, table.count(visited))
	end

	self:manageMemory()
	client:write('ready')

end


function Graph:manageMemory()

	if self.cellCount > config.cellLimit then
		local time, oldest = HUGE
		for cell in self:getCells() do
			if cell.lastVisited < time then
				time = cell.lastVisited
				oldest = cell
			end
		end
		self:unloadCell(oldest.x, oldest.y)
	end

end

return Graph