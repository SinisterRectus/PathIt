local meta = {}

function meta:__call(...)
	local obj = setmetatable({}, self)
	obj:__init(...)
	return obj
end

function meta:__tostring()
	return 'class: ' .. self.__name
end

local default = {}

function default:__tostring()
	return 'instance of class: ' .. self.__name
end

return function(name, base)

	local class = setmetatable({}, meta)

	for k, v in pairs(default) do
		class[k] = v
	end

	if base then
		for k, v in pairs(base) do
			class[k] = v
		end
	end

	class.__name = name
	class.__base = base
	class.__index = class

	return class

end
