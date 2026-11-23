local Util = require("../Core/Util")

local ListingManager = {}
ListingManager.__index = ListingManager

function ListingManager.new(options)
	options = options or {}
	return setmetatable({
		clock = options.clock or os.time,
		staleSeconds = tonumber(options.staleSeconds) or 60,
		warnBeforeCancelPendingOffers = options.warnBeforeCancelPendingOffers ~= false,
		drafts = {},
		listings = {},
		order = {},
		nextId = 1,
	}, ListingManager)
end

function ListingManager:Draft(entry)
	assert(type(entry) == "table", "draft entry must be a table")
	local items = entry.items or {}
	local askItems = entry.askItems or entry.ask or {}
	if #items == 0 then
		return nil, "draft needs at least one item"
	end
	local now = self.clock()
	local id = string.format("D-%d-%d", self.nextId, now)
	self.nextId = self.nextId + 1
	local draft = {
		id = id,
		items = Util.deepCopy(items),
		askItems = Util.deepCopy(askItems),
		note = entry.note,
		status = "DRAFT",
		createdAt = now,
		updatedAt = now,
	}
	self.drafts[id] = draft
	return draft
end

function ListingManager:Publish(draftId, options)
	options = options or {}
	if options.confirmed ~= true then
		return nil, "publishing requires explicit confirmation"
	end
	local draft = self.drafts[draftId]
	if not draft then
		return nil, "draft not found"
	end
	if draft.status ~= "DRAFT" then
		return nil, "draft is not publishable"
	end
	local now = self.clock()
	local listing = {
		id = string.format("L-%d-%d", self.nextId, now),
		draftId = draftId,
		items = Util.deepCopy(draft.items),
		askItems = Util.deepCopy(draft.askItems),
		note = draft.note,
		status = "ACTIVE",
		createdAt = now,
		updatedAt = now,
		expiresAt = now + self.staleSeconds,
		offers = {},
		history = {},
	}
	self.nextId = self.nextId + 1
	table.insert(self.listings, listing)
	table.insert(self.order, listing.id)
	draft.status = "PUBLISHED"
	draft.listingId = listing.id
	return listing
end

function ListingManager:AddOffer(listingId, offer)
	local listing = self:Get(listingId)
	if not listing then
		return nil, "listing not found"
	end
	local now = self.clock()
	local entry = {
		id = offer.id or string.format("O-%d-%d", self.nextId, now),
		listingId = listingId,
		offeredItems = Util.deepCopy(offer.offeredItems or {}),
		requestedItems = Util.deepCopy(offer.requestedItems or {}),
		profit = offer.profit,
		percent = offer.percent,
		status = offer.status or "PENDING",
		createdAt = now,
	}
	table.insert(listing.offers, entry)
	listing.updatedAt = now
	return entry
end

function ListingManager:PendingOfferCount(listingId)
	local listing = self:Get(listingId)
	if not listing then
		return 0
	end
	local count = 0
	for index = 1, #listing.offers do
		if listing.offers[index].status == "PENDING" then
			count = count + 1
		end
	end
	return count
end

function ListingManager:Get(listingId)
	for index = 1, #self.listings do
		if self.listings[index].id == listingId then
			return self.listings[index]
		end
	end
	return nil
end

function ListingManager:GetDraft(draftId)
	return self.drafts[draftId]
end

function ListingManager:List(status)
	local result = {}
	for index = 1, #self.listings do
		local listing = self.listings[index]
		if not status or listing.status == status then
			result[#result + 1] = listing
		end
	end
	return result
end

function ListingManager:Tick(now)
	local current = now or self.clock()
	local stale = {}
	for index = 1, #self.listings do
		local listing = self.listings[index]
		if listing.status == "ACTIVE" and current >= listing.expiresAt then
			listing.status = "STALE"
			listing.staleAt = current
			listing.history[#listing.history + 1] = {
				type = "stale",
				at = current,
				pendingOffers = self:PendingOfferCount(listing.id),
			}
			stale[#stale + 1] = listing
		end
	end
	return stale
end

function ListingManager:Age(listingId, now)
	local listing = self:Get(listingId)
	if not listing then
		return nil
	end
	return math.max(0, (now or self.clock()) - listing.createdAt)
end

function ListingManager:RefreshSuggestion(listingId)
	local listing = self:Get(listingId)
	if not listing then
		return nil, "listing not found"
	end
	local age = self:Age(listingId)
	local pending = self:PendingOfferCount(listingId)
	local lines = {
		string.format("Listing %s is %s old.", listing.id, Util.formatDuration(age)),
	}
	if pending > 0 then
		lines[#lines + 1] = string.format("%d pending offer(s): review them before cancelling.", pending)
	end
	if listing.status == "STALE" then
		lines[#lines + 1] = "The listing is stale. Recheck its status in Adopt Me, then update the ask or repost with explicit confirmation."
	else
		lines[#lines + 1] = "Listing is still within its configured freshness window."
	end
	return {
		listingId = listing.id,
		age = age,
		pendingOffers = pending,
		status = listing.status,
		message = table.concat(lines, " "),
		requiresConfirmation = true,
	}
end

function ListingManager:Cancel(listingId, options)
	options = options or {}
	local listing = self:Get(listingId)
	if not listing then
		return nil, "listing not found"
	end
	if options.confirmed ~= true then
		return nil, "cancelling requires explicit confirmation"
	end
	local pending = self:PendingOfferCount(listingId)
	if pending > 0 and self.warnBeforeCancelPendingOffers and options.force ~= true then
		return nil, string.format("listing has %d pending offer(s); pass force=true to cancel anyway", pending)
	end
	listing.status = "CANCELLED"
	listing.cancelledAt = self.clock()
	listing.history[#listing.history + 1] = {
		type = "cancelled",
		at = listing.cancelledAt,
		pendingOffers = pending,
	}
	return listing
end

function ListingManager:Repost(listingId, options)
	options = options or {}
	local listing = self:Get(listingId)
	if not listing then
		return nil, "listing not found"
	end
	if options.confirmed ~= true then
		return nil, "reposting requires explicit confirmation"
	end
	listing.status = "ARCHIVED"
	listing.archivedAt = self.clock()
	listing.history[#listing.history + 1] = { type = "archived", at = listing.archivedAt }
	local now = self.clock()
	local reposted = {
		id = string.format("L-%d-%d", self.nextId, now),
		draftId = listing.draftId,
		items = Util.deepCopy(listing.items),
		askItems = Util.deepCopy(listing.askItems),
		note = listing.note,
		status = "ACTIVE",
		createdAt = now,
		updatedAt = now,
		expiresAt = now + self.staleSeconds,
		offers = {},
		history = { { type = "repost-of", parent = listing.id, at = now } },
	}
	self.nextId = self.nextId + 1
	table.insert(self.listings, reposted)
	table.insert(self.order, reposted.id)
	return reposted
end

function ListingManager:Stats()
	local active, stale, cancelled, archived = 0, 0, 0, 0
	for index = 1, #self.listings do
		local status = self.listings[index].status
		if status == "ACTIVE" then
			active = active + 1
		elseif status == "STALE" then
			stale = stale + 1
		elseif status == "CANCELLED" then
			cancelled = cancelled + 1
		elseif status == "ARCHIVED" then
			archived = archived + 1
		end
	end
	return {
		active = active,
		stale = stale,
		cancelled = cancelled,
		archived = archived,
		drafts = self.nextId,
	}
end

return ListingManager
