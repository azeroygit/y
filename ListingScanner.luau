local Util = require("../Core/Util")

local ListingScanner = {}
ListingScanner.__index = ListingScanner

local FIELD_ALIASES = {
	id = "id", listing = "id", listingid = "id", listing_id = "id",
	seller = "seller", sellerid = "seller", user = "seller", userid = "seller",
	offer = "offered", offered = "offered", give = "offered", gives = "offered", theygive = "offered",
	want = "requested", wanted = "requested", requested = "requested", ask = "requested", askfor = "requested",
	expires = "expires", expiresat = "expires", time = "timestamp", created = "timestamp",
}

local function normalizeField(name)
	local key = string.lower(string.gsub(Util.trim(name), "%s+", ""))
	key = string.gsub(key, "[^%w_]", "")
	return FIELD_ALIASES[key]
end

function ListingScanner.new(options)
	options = options or {}
	return setmetatable({
		reader = options.reader,
		evaluator = options.evaluator,
		clock = options.clock or os.time,
		logger = options.logger,
		maxSeenHistory = tonumber(options.maxSeenHistory) or 500,
		seen = {},
		seenOrder = {},
		inspectedCount = 0,
	}, ListingScanner)
end

function ListingScanner:ParseText(text)
	local blocks = {}
	local current = { index = 1, fields = {}, raw = {} }
	local lines = {}
	for line in string.gmatch(tostring(text or "") .. "\n", "([^\n]*)\n") do
		lines[#lines + 1] = line
	end
	local function push()
		if next(current.fields) ~= nil then
			blocks[#blocks + 1] = current
		end
		current = { index = #blocks + 2, fields = {}, raw = {} }
	end
	for index = 1, #lines do
		local raw = lines[index]
		local line = Util.trim(raw)
		if line == "" or line == "---" or line == "===" then
			push()
		else
			current.raw[#current.raw + 1] = raw
			local handled = false
			if string.find(line, "|") then
				for part in string.gmatch(line, "[^|]+") do
					local key, value = string.match(part, "^%s*([%w_ ]+)%s*[:=]%s*(.-)%s*$")
					if key and value then
						local field = normalizeField(key)
						if field then
							current.fields[field] = value
							handled = true
						end
					end
				end
			end
			if not handled then
				local key, value = string.match(line, "^([%w_ ]+)%s*[:=]%s*(.-)%s*$")
				if key and value then
					local field = normalizeField(key)
					if field then
						current.fields[field] = value
					end
				end
			end
		end
	end
	push()
	return blocks
end

function ListingScanner:Fingerprint(offeredText, requestedText)
	return Util.hashString(string.lower(Util.trim((offeredText or "") .. ">" .. (requestedText or ""))))
end

function ListingScanner:Scan(text, options)
	options = options or {}
	local result = {
		listings = {},
		stats = {
			blocks = 0,
			parsed = 0,
			evaluated = 0,
			duplicates = 0,
			incomplete = 0,
			goodDeals = 0,
			errors = 0,
		},
		errors = {},
		warnings = {},
		scannedAt = self.clock(),
	}
	local blocks = self:ParseText(text)
	result.stats.blocks = #blocks
	if #blocks == 0 then
		result.warnings[#result.warnings + 1] = "No listings found. Paste listing text or import a file; KIRIA AUTOTRADER does not fabricate listings."
		return result
	end
	for index = 1, #blocks do
		local block = blocks[index]
		local fields = block.fields
		if not fields.offered or not fields.requested then
			result.stats.errors = result.stats.errors + 1
			result.errors[#result.errors + 1] = string.format("Block %d needs both offered and requested items", index)
		else
			local offeredItems, offeredErrors = self.reader:ParseText(fields.offered)
			local requestedItems, requestedErrors = self.reader:ParseText(fields.requested)
			for _, err in ipairs(offeredErrors) do
				result.errors[#result.errors + 1] = "offered: " .. err
			end
			for _, err in ipairs(requestedErrors) do
				result.errors[#result.errors + 1] = "requested: " .. err
			end
			if #offeredItems == 0 or #requestedItems == 0 then
				result.stats.errors = result.stats.errors + 1
				result.errors[#result.errors + 1] = string.format("Block %d has no usable items", index)
			else
				local id = fields.id or ("IMP-" .. self:Fingerprint(fields.offered, fields.requested))
				local fingerprint = self:Fingerprint(fields.offered, fields.requested)
				if self.seen[id] or self.seen[fingerprint] then
					result.stats.duplicates = result.stats.duplicates + 1
				else
					local listing = {
						id = id,
						seller = fields.seller,
						offeredItems = offeredItems,
						requestedItems = requestedItems,
						rawOffer = fields.offered,
						rawRequest = fields.requested,
						fingerprint = fingerprint,
						timestamp = tonumber(fields.timestamp) or self.clock(),
						expiresAt = tonumber(fields.expires),
						source = "manual-import",
					}
					listing.evaluation = self.evaluator:EvaluateListing(listing, { now = self.clock() })
					listing.statusLabel = listing.evaluation.statusLabel
					listing.confidence = listing.evaluation.confidence
					listing.potentialProfit = listing.evaluation.potentialProfit
					listing.percent = listing.evaluation.percent
					listing.offeredValue = listing.evaluation.theirValue
					listing.requestedValue = listing.evaluation.yourValue
					listing.listingStatus = listing.confidence == "INCOMPLETE" and "INCOMPLETE DATA" or listing.statusLabel
					if listing.confidence == "INCOMPLETE" then
						result.stats.incomplete = result.stats.incomplete + 1
					end
					if listing.statusLabel == "GOOD DEAL" then
						result.stats.goodDeals = result.stats.goodDeals + 1
					end
					result.listings[#result.listings + 1] = listing
					result.stats.parsed = result.stats.parsed + 1
					result.stats.evaluated = result.stats.evaluated + 1
					self:MarkInspected(id, fingerprint)
				end
			end
		end
	end
	local filters = options.filters or {}
	local filtered = {}
	for index = 1, #result.listings do
		local listing = result.listings[index]
		local pass = true
		if filters.status and filters.status ~= "" then
			pass = pass and listing.listingStatus == filters.status
		end
		if filters.minValue and listing.offeredValue then
			pass = pass and listing.offeredValue >= filters.minValue
		end
		if filters.minProfit and listing.potentialProfit then
			pass = pass and listing.potentialProfit >= filters.minProfit
		end
		if filters.minGainPercent and listing.percent then
			pass = pass and listing.percent >= filters.minGainPercent
		end
		if filters.onlyComplete then
			pass = pass and listing.confidence == "COMPLETE"
		end
		if pass then
			filtered[#filtered + 1] = listing
		end
	end
	table.sort(filtered, function(a, b)
		local ap = a.potentialProfit and a.percent and (a.potentialProfit + a.percent / 1000) or -math.huge
		local bp = b.potentialProfit and b.percent and (b.potentialProfit + b.percent / 1000) or -math.huge
		return ap > bp
	end)
	result.listings = filtered
	result.stats.shown = #filtered
	result.warnings[#result.warnings + 1] = "Listings come only from your manual import; verify availability in Adopt Me before acting."
	if self.logger then
		self.logger:Info("Scanner parsed %d listing(s), %d duplicate(s), %d incomplete", result.stats.parsed, result.stats.duplicates, result.stats.incomplete)
	end
	return result
end

function ListingScanner:MarkInspected(id, fingerprint)
	if not self.seen[id] then
		self.seen[id] = true
		self.seenOrder[#self.seenOrder + 1] = id
	end
	if fingerprint and not self.seen[fingerprint] then
		self.seen[fingerprint] = true
		self.seenOrder[#self.seenOrder + 1] = fingerprint
	end
	self.inspectedCount = self.inspectedCount + 1
	while #self.seenOrder > self.maxSeenHistory do
		local oldest = table.remove(self.seenOrder, 1)
		self.seen[oldest] = nil
	end
end

function ListingScanner:ResetHistory()
	self.seen = {}
	self.seenOrder = {}
	self.inspectedCount = 0
end

function ListingScanner:Stats()
	return {
		inspected = self.inspectedCount,
		seen = #self.seenOrder,
	}
end

return ListingScanner
