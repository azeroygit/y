local Json = {}

local function decodeError(message, position)
	error(string.format("JSON decode error at %d: %s", position, message), 0)
end

local escapes = {
	['"'] = '"',
	["\\"] = "\\",
	["/"] = "/",
	["b"] = "\b",
	["f"] = "\f",
	["n"] = "\n",
	["r"] = "\r",
	["t"] = "\t",
}

local function utf8Char(code)
	if code < 0x80 then
		return string.char(code)
	elseif code < 0x800 then
		return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
	elseif code < 0x10000 then
		return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
	else
		return string.char(
			0xF0 + math.floor(code / 0x40000),
			0x80 + math.floor(code / 0x1000) % 0x40,
			0x80 + math.floor(code / 0x40) % 0x40,
			0x80 + code % 0x40
		)
	end
end

function Json.decode(text)
	assert(type(text) == "string", "JSON input must be a string")
	local position = 1
	local length = #text

	local function skipWhitespace()
		while position <= length do
			local char = string.sub(text, position, position)
			if char == " " or char == "\t" or char == "\n" or char == "\r" then
				position = position + 1
			else
				break
			end
		end
	end

	local function parseString()
		position = position + 1
		local buffer = {}
		while position <= length do
			local char = string.sub(text, position, position)
			if char == '"' then
				position = position + 1
				return table.concat(buffer)
			elseif char == "\\" then
				position = position + 1
				local esc = string.sub(text, position, position)
				if esc == "u" then
					local hex = string.sub(text, position + 1, position + 4)
					local code = tonumber(hex, 16)
					if not code then
						decodeError("invalid unicode escape", position)
					end
					buffer[#buffer + 1] = utf8Char(code)
					position = position + 5
				else
					local mapped = escapes[esc]
					if mapped == nil then
						decodeError("invalid escape", position)
					end
					buffer[#buffer + 1] = mapped
					position = position + 1
				end
			else
				buffer[#buffer + 1] = char
				position = position + 1
			end
		end
		decodeError("unterminated string", position)
	end

	local parseValue

	local function parseNumber()
		local start = position
		if string.sub(text, position, position) == "-" then
			position = position + 1
		end
		while position <= length and string.find(string.sub(text, position, position), "[%d]") do
			position = position + 1
		end
		if string.sub(text, position, position) == "." then
			position = position + 1
			while position <= length and string.find(string.sub(text, position, position), "[%d]") do
				position = position + 1
			end
		end
		local exponent = string.sub(text, position, position)
		if exponent == "e" or exponent == "E" then
			position = position + 1
			local sign = string.sub(text, position, position)
			if sign == "+" or sign == "-" then
				position = position + 1
			end
			while position <= length and string.find(string.sub(text, position, position), "[%d]") do
				position = position + 1
			end
		end
		local number = tonumber(string.sub(text, start, position - 1))
		if not number then
			decodeError("invalid number", start)
		end
		return number
	end

	local function parseArray()
		position = position + 1
		local result = {}
		skipWhitespace()
		if string.sub(text, position, position) == "]" then
			position = position + 1
			return result
		end
		while true do
			result[#result + 1] = parseValue()
			skipWhitespace()
			local char = string.sub(text, position, position)
			if char == "," then
				position = position + 1
				skipWhitespace()
			elseif char == "]" then
				position = position + 1
				return result
			else
				decodeError("expected ',' or ']'", position)
			end
		end
	end

	local function parseObject()
		position = position + 1
		local result = {}
		skipWhitespace()
		if string.sub(text, position, position) == "}" then
			position = position + 1
			return result
		end
		while true do
			skipWhitespace()
			if string.sub(text, position, position) ~= '"' then
				decodeError("expected object key", position)
			end
			local key = parseString()
			skipWhitespace()
			if string.sub(text, position, position) ~= ":" then
				decodeError("expected ':'", position)
			end
			position = position + 1
			skipWhitespace()
			result[key] = parseValue()
			skipWhitespace()
			local char = string.sub(text, position, position)
			if char == "," then
				position = position + 1
			elseif char == "}" then
				position = position + 1
				return result
			else
				decodeError("expected ',' or '}'", position)
			end
		end
	end

	parseValue = function()
		skipWhitespace()
		local char = string.sub(text, position, position)
		if char == '"' then
			return parseString()
		elseif char == "{" then
			return parseObject()
		elseif char == "[" then
			return parseArray()
		elseif char == "t" and string.sub(text, position, position + 3) == "true" then
			position = position + 4
			return true
		elseif char == "f" and string.sub(text, position, position + 4) == "false" then
			position = position + 5
			return false
		elseif char == "n" and string.sub(text, position, position + 3) == "null" then
			position = position + 4
			return nil
		elseif char == "-" or string.find(char, "[%d]") then
			return parseNumber()
		end
		decodeError("unexpected character '" .. tostring(char) .. "'", position)
	end

	local result = parseValue()
	skipWhitespace()
	if position <= length then
		decodeError("trailing characters", position)
	end
	return result
end

local ESCAPE = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function encodeString(value)
	local escaped = string.gsub(value, '[%z\1-\31\\"]', function(char)
		return ESCAPE[char] or string.format("\\u%04x", string.byte(char))
	end)
	return '"' .. escaped .. '"'
end

function Json.encode(value)
	local valueType = type(value)
	if value == nil then
		return "null"
	elseif valueType == "boolean" then
		return tostring(value)
	elseif valueType == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return "null"
		end
		return string.format("%.14g", value)
	elseif valueType == "string" then
		return encodeString(value)
	elseif valueType == "table" then
		local isArray = true
		local count = 0
		for key in pairs(value) do
			count = count + 1
			if type(key) ~= "number" then
				isArray = false
			end
		end
		if isArray and count == #value then
			local parts = {}
			for index = 1, #value do
				parts[index] = Json.encode(value[index])
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts = {}
		local keys = {}
		for key in pairs(value) do
			keys[#keys + 1] = key
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		for index = 1, #keys do
			local key = keys[index]
			parts[#parts + 1] = encodeString(tostring(key)) .. ":" .. Json.encode(value[key])
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "null"
end

return Json
