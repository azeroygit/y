local Util = require("../Core/Util")

local OfferQueue = {}
OfferQueue.__index = OfferQueue

OfferQueue.Status = {
	PENDING = "PENDING",
	ACCEPTED = "ACCEPTED",
	DECLINED = "DECLINED",
	EXPIRED = "EXPIRED",
	CANCELLED = "CANCELLED",
	UNKNOWN = "UNKNOWN",
}

local VALID_TRANSITIONS = {
	PENDING = { ACCEPTED = true, DECLINED = true, EXPIRED = true, CANCELLED = true, UNKNOWN = true },
	UNKNOWN = { ACCEPTED = true, DECLINED = true, EXPIRED = true, CANCELLED = true },
	ACCEPTED = {},
	DECLINED = {},
	EXPIRED = { UNKNOWN = true },
	CANCELLED = {},
}

function OfferQueue.new(options)
	options = options or {}
	return setmetatable({
		clock = options.clock or os.time,
		timeoutSeconds = tonumber(options.timeoutSeconds) or 600,
		onEvent = options.onEvent,
		offers = {},
		order = {},
		nextId = 1,
		fingerprints = {},
	}, OfferQueue)
end

function OfferQueue:Fingerprint(offer)
	local parts = { tostring(offer.listingId or "") }
	local offered = {}
	for index = 1, #(offer.offeredItems or {}) do
		local item = offer.offeredItems[index]
		offered[#offered + 1] = string.format("%s:%s:%s:%s",
			Util.nameKey(item.name), tostring(item.variant), tostring(item.fly), tostring(item.ride))
	end
	local requested = {}
	for index = 1, #(offer.requestedItems or {}) do
		local item = offer.requestedItems[index]
		requested[#requested + 1] = string.format("%s:%s:%s:%s",
			Util.nameKey(item.name), tostring(item.variant), tostring(item.fly), tostring(item.ride))
	end
	table.sort(offered)
	table.sort(requested)
	parts[#parts + 1] = table.concat(offered, ",")
	parts[#parts + 1] = table.concat(requested, ",")
	return Util.hashString(table.concat(parts, "|"))
end

function OfferQueue:Add(offer)
	assert(type(offer) == "table", "offer must be a table")
	local now = self.clock()
	local fingerprint = self:Fingerprint(offer)
	local existing = self.fingerprints[fingerprint]
	if existing and (existing.status == OfferQueue.Status.PENDING or existing.status == OfferQueue.Status.UNKNOWN) then
		return existing, false, "duplicate offer"
	end
	local id = offer.id or string.format("Q-%d-%d", self.nextId, now)
	if self.offers[id] then
		id = id .. "-" .. tostring(now)
	end
	self.nextId = self.nextId + 1
	local entry = {
		id = id,
		listingId = offer.listingId,
		offeredItems = Util.deepCopy(offer.offeredItems or {}),
		requestedItems = Util.deepCopy(offer.requestedItems or {}),
		profit = tonumber(offer.profit),
		percent = tonumber(offer.percent),
		percentValue = tonumber(offer.percent),
		status = OfferQueue.Status.PENDING,
		createdAt = offer.createdAt or now,
		expiresAt = (offer.createdAt or now) + (tonumber(offer.timeoutSeconds) or self.timeoutSeconds),
		fingerprint = fingerprint,
		history = { { status = OfferQueue.Status.PENDING, at = now } },
	}
	self.offers[id] = entry
	self.fingerprints[fingerprint] = entry
	table.insert(self.order, id)
	if type(self.onEvent) == "function" then
		pcall(self.onEvent, "created", entry)
	end
	return entry, true
end

function OfferQueue:Get(id)
	return self.offers[id]
end

function OfferQueue:Transition(id, status, options)
	options = options or {}
	local offer = self.offers[id]
	if not offer then
		return nil, "offer not found"
	end
	local allowed = VALID_TRANSITIONS[offer.status]
	if not allowed or not allowed[status] then
		return nil, string.format("invalid transition %s -> %s", offer.status, status)
	end
	if status == OfferQueue.Status.ACCEPTED and options.confirmed ~= true then
		return nil, "accepting an offer requires explicit user confirmation"
	end
	offer.status = status
	offer.updatedAt = self.clock()
	offer.history[#offer.history + 1] = { status = status, at = offer.updatedAt }
	if type(self.onEvent) == "function" then
		pcall(self.onEvent, status, offer)
	end
	return offer
end

function OfferQueue:MarkAccepted(id, options)
	return self:Transition(id, OfferQueue.Status.ACCEPTED, options)
end

function OfferQueue:MarkDeclined(id)
	return self:Transition(id, OfferQueue.Status.DECLINED)
end

function OfferQueue:MarkCancelled(id)
	return self:Transition(id, OfferQueue.Status.CANCELLED)
end

function OfferQueue:Tick(now)
	local current = now or self.clock()
	local expired = {}
	for index = 1, #self.order do
		local offer = self.offers[self.order[index]]
		if offer and offer.status == OfferQueue.Status.PENDING and current >= offer.expiresAt then
			offer.status = OfferQueue.Status.EXPIRED
			offer.updatedAt = current
			offer.history[#offer.history + 1] = { status = OfferQueue.Status.EXPIRED, at = current }
			expired[#expired + 1] = offer
			if type(self.onEvent) == "function" then
				pcall(self.onEvent, "expired", offer)
			end
		end
	end
	return expired
end

function OfferQueue:Age(id, now)
	local offer = self.offers[id]
	if not offer then
		return nil
	end
	return math.max(0, (now or self.clock()) - offer.createdAt)
end

function OfferQueue:Remaining(id, now)
	local offer = self.offers[id]
	if not offer or offer.status ~= OfferQueue.Status.PENDING then
		return nil
	end
	return math.max(0, offer.expiresAt - (now or self.clock()))
end

function OfferQueue:List(status)
	local result = {}
	for index = 1, #self.order do
		local offer = self.offers[self.order[index]]
		if offer and (not status or offer.status == status) then
			result[#result + 1] = offer
		end
	end
	table.sort(result, function(a, b)
		return a.createdAt > b.createdAt
	end)
	return result
end

function OfferQueue:PendingCount()
	local count = 0
	for _, offer in pairs(self.offers) do
		if offer.status == OfferQueue.Status.PENDING then
			count = count + 1
		end
	end
	return count
end

function OfferQueue:PendingProfit()
	local total = 0
	for _, offer in pairs(self.offers) do
		if offer.status == OfferQueue.Status.PENDING and offer.profit and offer.profit > 0 then
			total = total + offer.profit
		end
	end
	return total
end

function OfferQueue:Stats()
	local stats = { total = 0, PENDING = 0, ACCEPTED = 0, DECLINED = 0, EXPIRED = 0, CANCELLED = 0, UNKNOWN = 0 }
	for _, offer in pairs(self.offers) do
		stats.total = stats.total + 1
		stats[offer.status] = (stats[offer.status] or 0) + 1
	end
	return stats
end

return OfferQueue
