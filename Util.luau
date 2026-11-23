local Util = {}

function Util.deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in pairs(value) do
		copy[Util.deepCopy(key)] = Util.deepCopy(item)
	end
	return setmetatable(copy, getmetatable(value))
end

function Util.shallowCopy(value)
	local copy = {}
	for key, item in pairs(value) do
		copy[key] = item
	end
	return copy
end

function Util.deepMerge(base, overrides)
	if type(base) ~= "table" or type(overrides) ~= "table" then
		return Util.deepCopy(overrides)
	end
	local result = Util.deepCopy(base)
	for key, value in pairs(overrides) do
		if type(value) == "table" and type(result[key]) == "table" then
			result[key] = Util.deepMerge(result[key], value)
		else
			result[key] = Util.deepCopy(value)
		end
	end
	return result
end

function Util.clamp(value, minimum, maximum)
	if value < minimum then
		return minimum
	elseif value > maximum then
		return maximum
	end
	return value
end

function Util.round(value, decimals)
	local factor = 10 ^ (decimals or 0)
	return math.floor(value * factor + 0.5) / factor
end

function Util.formatNumber(value, decimals)
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return "N/A"
	end
	local places = decimals
	if places == nil then
		places = math.abs(value) >= 100 and 0 or (math.abs(value) >= 10 and 1 or 2)
	end
	local text = string.format("%." .. tostring(places) .. "f", value)
	if string.find(text, "%.") then
		text = string.gsub(text, "0+$", "")
		text = string.gsub(text, "%.$", "")
	end
	return text
end

function Util.formatPercent(value, decimals)
	if type(value) ~= "number" or value ~= value then
		return "N/A"
	end
	local places = decimals or 1
	local sign = value > 0 and "+" or ""
	return sign .. string.format("%." .. tostring(places) .. "f", value) .. "%"
end

function Util.formatDuration(seconds)
	seconds = math.max(0, math.floor(tonumber(seconds) or 0))
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	local rest = seconds % 60
	if hours > 0 then
		return string.format("%dh %02dm", hours, minutes)
	elseif minutes > 0 then
		return string.format("%dm %02ds", minutes, rest)
	end
	return string.format("%ds", rest)
end

function Util.formatTime(timestamp)
	if type(timestamp) ~= "number" or timestamp <= 0 then
		return "never"
	end
	local ok, text = pcall(function()
		return os.date("%Y-%m-%d %H:%M:%S", math.floor(timestamp))
	end)
	return ok and text or tostring(timestamp)
end

function Util.normalizeName(name)
	local text = tostring(name or "")
	text = string.lower(text)
	text = string.gsub(text, "[^%w]+", " ")
	text = string.gsub(text, "^%s+", "")
	text = string.gsub(text, "%s+$", "")
	return text
end

function Util.nameKey(name)
	return string.gsub(Util.normalizeName(name), "%s+", "")
end

function Util.hashString(text)
	local hash = 2166136261
	for index = 1, #text do
		hash = bit32.bxor(hash, string.byte(text, index))
		hash = bit32.band(hash * 16777619, 4294967295)
	end
	return string.format("%08x", hash)
end

function Util.join(list, separator)
	local parts = {}
	for index = 1, #list do
		parts[index] = tostring(list[index])
	end
	return table.concat(parts, separator or ", ")
end

function Util.trim(text)
	text = tostring(text or "")
	text = string.gsub(text, "^%s+", "")
	text = string.gsub(text, "%s+$", "")
	return text
end

function Util.split(text, separator)
	local parts = {}
	local pattern = "([^" .. separator .. "]+)"
	for piece in string.gmatch(tostring(text or ""), pattern) do
		parts[#parts + 1] = piece
	end
	return parts
end

function Util.sortedKeys(map)
	local keys = {}
	for key in pairs(map) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	return keys
end

function Util.isEmpty(value)
	if value == nil then
		return true
	end
	if type(value) == "string" then
		return #value == 0
	end
	if type(value) == "table" then
		return next(value) == nil
	end
	return false
end

return Util
