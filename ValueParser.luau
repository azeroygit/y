local Util = require("../Core/Util")

local ValueParser = {}
ValueParser.__index = ValueParser

ValueParser.AMVGG_URL = "https://amvgg.com/values/pets"
ValueParser.SOURCE = "AMVGG"

function ValueParser.new(options)
	options = options or {}
	return setmetatable({
		jsonDecode = options.jsonDecode,
		jsonEncode = options.jsonEncode,
		minPetCount = tonumber(options.minPetCount) or 1,
		lastMode = nil,
	}, ValueParser)
end

local function decodeJson(self, text)
	if type(self.jsonDecode) ~= "function" then
		return nil, "json decoder unavailable"
	end
	local ok, result = pcall(self.jsonDecode, text)
	if not ok then
		return nil, tostring(result)
	end
	if type(result) ~= "table" then
		return nil, "decoded value is not a table"
	end
	return result
end

function ValueParser:DecodeNextPayload(html)
	local texts = {}
	local searchFrom = 1
	local marker = "self.__next_f.push("
	while true do
		local startPos = string.find(html, marker, searchFrom, true)
		if not startPos then
			break
		end
		local argsStart = startPos + #marker
		local closePos = string.find(html, ")</script>", argsStart, true)
		if not closePos then
			break
		end
		local literal = string.sub(html, argsStart, closePos - 1)
		local decoded = decodeJson(self, literal)
		if type(decoded) == "table" and decoded[1] == 1 and type(decoded[2]) == "string" then
			texts[#texts + 1] = decoded[2]
		end
		searchFrom = closePos + 10
	end
	return table.concat(texts, "")
end

local function findBalanced(text, startIndex)
	local depth = 0
	local inString = false
	local escaped = false
	for index = startIndex, #text do
		local char = string.sub(text, index, index)
		if inString then
			if escaped then
				escaped = false
			elseif char == "\\" then
				escaped = true
			elseif char == '"' then
				inString = false
			end
		else
			if char == '"' then
				inString = true
			elseif char == "[" or char == "{" then
				depth = depth + 1
			elseif char == "]" or char == "}" then
				depth = depth - 1
				if depth == 0 then
					return index
				end
			end
		end
	end
	return nil
end

function ValueParser:ExtractPetsArray(text)
	local searchFrom = 1
	while true do
		local keyPos = string.find(text, '"pets":', searchFrom, true)
		if not keyPos then
			return nil, "pets array not found"
		end
		local arrayStart = string.find(text, "[", keyPos + 7, true)
		if not arrayStart then
			return nil, "pets array malformed"
		end
		local arrayEnd = findBalanced(text, arrayStart)
		if arrayEnd then
			local literal = string.sub(text, arrayStart, arrayEnd)
			local decoded, err = decodeJson(self, literal)
			if decoded then
				return decoded
			end
			searchFrom = arrayEnd + 1
		else
			return nil, "unbalanced pets array"
		end
	end
end

local function numberOrNil(value)
	if type(value) == "number" then
		return value
	elseif type(value) == "string" then
		return tonumber(value)
	end
	return nil
end

local function timestampOrNil(value)
	if type(value) == "string" then
		return (string.gsub(value, "^%$D", ""))
	end
	return nil
end

function ValueParser:NormalizePet(raw)
	if type(raw) ~= "table" or type(raw.name) ~= "string" or raw.name == "" then
		return nil
	end
	local record = {
		id = raw.id,
		name = raw.name,
		key = Util.nameKey(raw.name),
		origin = raw.origin,
		category = raw.category,
		updatedAt = timestampOrNil(raw.lastUpdatedAt),
		demand = {
			regular = raw.regularDemand,
			fly = raw.fDemand,
			ride = raw.rDemand,
			base = raw.npRegularDemand,
			neon = raw.neonDemand,
			neonFly = raw.nfDemand,
			neonRide = raw.nrDemand,
			neonBase = raw.npNeonDemand,
			mega = raw.megaDemand,
			megaFly = raw.mfDemand,
			megaRide = raw.mrDemand,
			megaBase = raw.npMegaDemand,
		},
		values = {
			regular = numberOrNil(raw.regularValue),
			fly = numberOrNil(raw.fValue),
			ride = numberOrNil(raw.rValue),
			base = numberOrNil(raw.npRegularValue),
			neon = numberOrNil(raw.neonValue),
			neonFly = numberOrNil(raw.nfValue),
			neonRide = numberOrNil(raw.nrValue),
			neonBase = numberOrNil(raw.npNeonValue),
			mega = numberOrNil(raw.megaValue),
			megaFly = numberOrNil(raw.mfValue),
			megaRide = numberOrNil(raw.mrValue),
			megaBase = numberOrNil(raw.npMegaValue),
		},
	}
	record.regular = record.values.regular
	record.neon = record.values.neon
	record.mega = record.values.mega
	return record
end

function ValueParser:NormalizePets(rawPets)
	local pets = {}
	local skipped = 0
	for index = 1, #rawPets do
		local record = self:NormalizePet(rawPets[index])
		if record then
			pets[#pets + 1] = record
		else
			skipped = skipped + 1
		end
	end
	return pets, skipped
end

function ValueParser:ParsePayload(payload, meta)
	if type(payload) ~= "string" or payload == "" then
		return nil, "empty payload"
	end
	local rawPets, err = self:ExtractPetsArray(payload)
	if not rawPets then
		return nil, err
	end
	if #rawPets < self.minPetCount then
		return nil, string.format("too few pets in payload (%d < %d)", #rawPets, self.minPetCount)
	end
	local pets, skipped = self:NormalizePets(rawPets)
	if #pets < self.minPetCount then
		return nil, string.format("too few valid pets after normalization (%d < %d)", #pets, self.minPetCount)
	end
	local result = {
		source = ValueParser.SOURCE,
		url = (meta and meta.url) or ValueParser.AMVGG_URL,
		fetchedAt = (meta and meta.fetchedAt) or os.time(),
		mode = "flight",
		pets = pets,
		count = #pets,
		skipped = skipped,
	}
	self.lastMode = "flight"
	return result
end

local function unescapeHtml(text)
	text = string.gsub(text, "&amp;", "&")
	text = string.gsub(text, "&#39;", "'")
	text = string.gsub(text, "&quot;", '"')
	text = string.gsub(text, "&lt;", "<")
	text = string.gsub(text, "&gt;", ">")
	return text
end

function ValueParser:ParseCards(html)
	if type(html) ~= "string" or html == "" then
		return nil, "empty html"
	end
	local positions = {}
	local searchFrom = 1
	while true do
		local startPos = string.find(html, "data-pet-name=", searchFrom, true)
		if not startPos then
			break
		end
		positions[#positions + 1] = startPos
		searchFrom = startPos + 1
	end
	if #positions < self.minPetCount then
		return nil, string.format("too few pet cards (%d < %d)", #positions, self.minPetCount)
	end
	local pets = {}
	for index = 1, #positions do
		local startPos = positions[index]
		local endPos = positions[index + 1] or #html
		local block = string.sub(html, startPos, endPos - 1)
		local title = string.match(block, 'title="([^"]+)"')
		local valueText = string.match(block, "Value</span><span[^>]*>([%d%.]+)</span>")
		if not valueText then
			valueText = string.match(block, ">Value<[^>]*>.-<span[^>]*>([%d%.]+)</span>")
		end
		local name = title and unescapeHtml(title) or nil
		local value = tonumber(valueText)
		if name and value then
			local stars = 0
			for _ in string.gmatch(block, "★") do
				stars = stars + 1
			end
			pets[#pets + 1] = {
				name = name,
				key = Util.nameKey(name),
				origin = nil,
				category = nil,
				updatedAt = nil,
				demand = { regular = stars > 0 and tostring(stars) or nil },
				values = { regular = value },
				regular = value,
			}
		end
	end
	if #pets < self.minPetCount then
		return nil, string.format("too few parsed cards (%d < %d)", #pets, self.minPetCount)
	end
	local result = {
		source = ValueParser.SOURCE,
		url = ValueParser.AMVGG_URL,
		fetchedAt = os.time(),
		mode = "cards",
		pets = pets,
		count = #pets,
		skipped = 0,
	}
	self.lastMode = "cards"
	return result
end

function ValueParser:ParseHtml(html, meta)
	if type(html) ~= "string" or html == "" then
		return nil, "empty response body"
	end
	local payload = self:DecodeNextPayload(html)
	if payload ~= "" then
		local dataset, err = self:ParsePayload(payload, meta)
		if dataset then
			dataset.url = (meta and meta.url) or ValueParser.AMVGG_URL
			return dataset
		end
		local fallback, fallbackErr = self:ParseCards(html)
		if fallback then
			fallback.url = (meta and meta.url) or ValueParser.AMVGG_URL
			return fallback
		end
		return nil, string.format("%s; card fallback: %s", tostring(err), tostring(fallbackErr))
	end
	local dataset, err = self:ParseCards(html)
	if dataset then
		dataset.url = (meta and meta.url) or ValueParser.AMVGG_URL
		return dataset
	end
	return nil, err
end

return ValueParser
