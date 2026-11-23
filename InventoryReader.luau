local Util = require("../Core/Util")

local InventoryReader = {}
InventoryReader.__index = InventoryReader

function InventoryReader.new(options)
	options = options or {}
	return setmetatable({
		db = options.db,
		jsonDecode = options.jsonDecode,
	}, InventoryReader)
end

local VARIANT_TOKENS = {
	nfr = { variant = "neon", fly = true, ride = true },
	nf = { variant = "neon", fly = true, ride = false },
	nr = { variant = "neon", fly = false, ride = true },
	n = { variant = "neon", fly = false, ride = false },
	mfr = { variant = "mega", fly = true, ride = true },
	mf = { variant = "mega", fly = true, ride = false },
	mr = { variant = "mega", fly = false, ride = true },
	m = { variant = "mega", fly = false, ride = false },
	fr = { variant = "regular", fly = true, ride = true },
	f = { variant = "regular", fly = true, ride = false },
	r = { variant = "regular", fly = false, ride = true },
}

local WORD_TOKENS = {
	neon = { variant = "neon" },
	mega = { variant = "mega" },
	fly = { fly = true },
	flying = { fly = true },
	ride = { ride = true },
	ridable = { ride = true },
	normal = { variant = "regular" },
	regular = { variant = "regular" },
	base = { variant = "regular" },
}

local function tokenize(line)
	local tokens = {}
	local lower = string.lower(line)
	lower = string.gsub(lower, "[,%(%)%[%]{}]", " ")
	for token in string.gmatch(lower, "%S+") do
		tokens[#tokens + 1] = token
	end
	return tokens
end

function InventoryReader:ParseItemLine(line)
	local original = Util.trim(line)
	if original == "" then
		return nil
	end
	local quantity = 1
	local rest = original
	local qtyFront = string.match(rest, "^(%d+)%s*[xX]%s+")
	if qtyFront then
		quantity = math.max(1, tonumber(qtyFront) or 1)
		rest = string.gsub(rest, "^(%d+)%s*[xX]%s+", "", 1)
	else
		local qtyBack = string.match(rest, "[xX]%s*(%d+)%s*$")
		if qtyBack then
			quantity = math.max(1, tonumber(qtyBack) or 1)
			rest = string.gsub(rest, "%s*[xX]%s*(%d+)%s*$", "", 1)
		else
			local qtyCount = string.match(rest, "^%s*(%d+)%s*$")
			if qtyCount then
				quantity = math.max(1, tonumber(qtyCount) or 1)
				rest = ""
			end
		end
	end
	local state = { variant = nil, fly = false, ride = false }
	local tokens = tokenize(rest)
	local kept = {}
	for index = 1, #tokens do
		local token = tokens[index]
		local mapped = VARIANT_TOKENS[token]
		if mapped then
			state.variant = mapped.variant
			if mapped.fly ~= nil then
				state.fly = mapped.fly
			end
			if mapped.ride ~= nil then
				state.ride = mapped.ride
			end
		else
			local word = WORD_TOKENS[token]
			if word then
				if word.variant then
					state.variant = word.variant
				end
				if word.fly then
					state.fly = true
				end
				if word.ride then
					state.ride = true
				end
			else
				kept[#kept + 1] = tokens[index]
			end
		end
	end
	local nameText = table.concat(kept, " ")
	local pet = self.db and self.db:MatchName(nameText) or nil
	local variant = state.variant or (state.fly or state.ride and "regular" or "regular")
	if state.variant == nil then
		if state.fly or state.ride then
			variant = "regular"
		else
			variant = "regular"
		end
	end
	local name = pet and pet.name or Util.trim(nameText)
	if name == "" then
		return nil
	end
	return {
		uid = Util.hashString(string.format("%s|%s|%s|%s|%s", name, variant, tostring(state.fly), tostring(state.ride), tostring(quantity))),
		name = name,
		key = Util.normalizeName(name),
		variant = variant,
		fly = state.fly,
		ride = state.ride,
		quantity = quantity,
		known = pet ~= nil,
		raw = original,
	}
end

function InventoryReader:ParseText(text, options)
	options = options or {}
	local items = {}
	local errors = {}
	local trimmed = Util.trim(text)
	if trimmed == "" then
		return items, errors
	end
	if string.sub(trimmed, 1, 1) == "[" and self.jsonDecode then
		local ok, decoded = pcall(self.jsonDecode, trimmed)
		if ok and type(decoded) == "table" then
			for index = 1, #decoded do
				local entry = decoded[index]
				if type(entry) == "table" and type(entry.name) == "string" then
					local variant = entry.variant or "regular"
					local quantity = math.max(1, tonumber(entry.quantity or entry.qty) or 1)
					local pet = self.db and self.db:MatchName(entry.name) or nil
					items[#items + 1] = {
						uid = Util.hashString(string.format("%s|%s|%s|%s|%s|%d", entry.name, variant, tostring(entry.fly), tostring(entry.ride), tostring(quantity), index)),
						name = pet and pet.name or entry.name,
						key = Util.normalizeName(entry.name),
						variant = variant,
						fly = entry.fly == true,
						ride = entry.ride == true,
						quantity = quantity,
						known = pet ~= nil,
						raw = entry.name,
					}
				else
					errors[#errors + 1] = string.format("entry %d is invalid", index)
				end
			end
			return self:Merge(items), errors
		end
		errors[#errors + 1] = "JSON inventory could not be decoded"
	end
	local lines = {}
	for line in string.gmatch(trimmed .. "\n", "([^\n]*)\n") do
		lines[#lines + 1] = line
	end
	local startIndex = 1
	local first = string.lower(lines[1] or "")
	if string.find(first, "name") and string.find(first, ",") and string.find(first, "variant") then
		startIndex = 2
	end
	for index = startIndex, #lines do
		local line = Util.trim(lines[index])
		if line ~= "" then
			if string.find(line, ";") then
				for part in string.gmatch(line, "[^;]+") do
					local item = self:ParseItemLine(part)
					if item then
						items[#items + 1] = item
					else
						errors[#errors + 1] = "could not parse: " .. Util.trim(part)
					end
				end
			else
				local item = self:ParseItemLine(line)
				if item then
					items[#items + 1] = item
				else
					errors[#errors + 1] = "could not parse: " .. line
				end
			end
		end
	end
	if not options.noMerge then
		items = self:Merge(items)
	end
	return items, errors
end

function InventoryReader:Merge(items)
	local merged = {}
	local byKey = {}
	for index = 1, #items do
		local item = items[index]
		local key = string.format("%s|%s|%s|%s", Util.nameKey(item.name), tostring(item.variant), tostring(item.fly), tostring(item.ride))
		local existing = byKey[key]
		if existing then
			existing.quantity = existing.quantity + item.quantity
		else
			local copy = {}
			for k, v in pairs(item) do
				copy[k] = v
			end
			byKey[key] = copy
			merged[#merged + 1] = copy
		end
	end
	return merged
end

function InventoryReader:CountOwned(inventory, name, variant, fly, ride)
	local key = Util.nameKey(name)
	local total = 0
	for index = 1, #inventory do
		local item = inventory[index]
		if Util.nameKey(item.name) == key
			and (item.variant or "regular") == (variant or "regular")
			and (item.fly == true) == (fly == true)
			and (item.ride == true) == (ride == true)
		then
			total = total + (item.quantity or 1)
		end
	end
	return total
end

function InventoryReader:AutomaticScanStatus()
	return false, "Automatic Adopt Me inventory access is not available through documented, permitted interfaces. Import your pets manually on the Inventory page; values still come only from AMVGG."
end

return InventoryReader
