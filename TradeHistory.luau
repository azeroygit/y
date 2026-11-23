local Util = require("../Core/Util")

local TradeHistory = {}
TradeHistory.__index = TradeHistory

TradeHistory.SchemaVersion = 2

function TradeHistory.new(options)
	options = options or {}
	return setmetatable({
		clock = options.clock or os.time,
		storage = options.storage,
		jsonEncode = options.jsonEncode,
		jsonDecode = options.jsonDecode,
		path = options.path or "KiriaAutoTrader/history.json",
		maxTrades = tonumber(options.maxTrades) or 1000,
		data = {
			scans = 0,
			inspected = 0,
			goodDeals = 0,
			offersCreated = 0,
			accepted = 0,
			declined = 0,
			expired = 0,
			cancelled = 0,
			trades = {},
			activity = {},
			inventoryValue = 0,
			potentialProfit = 0,
			pendingProfit = 0,
		},
	}, TradeHistory)
end

function TradeHistory:RecordScan(result)
	if type(result) ~= "table" then
		return
	end
	local stats = result.stats or {}
	self.data.scans = self.data.scans + 1
	self.data.inspected = self.data.inspected + (stats.parsed or 0)
	self.data.goodDeals = self.data.goodDeals + (stats.goodDeals or 0)
	local day = self:_day()
	self.data.activity[day] = (self.data.activity[day] or 0) + (stats.parsed or 0)
end

function TradeHistory:RecordOfferCreated(offer)
	self.data.offersCreated = self.data.offersCreated + 1
	if offer and offer.profit then
		self.data.pendingProfit = self.data.pendingProfit + math.max(0, offer.profit)
	end
end

function TradeHistory:RecordOfferStatus(status, profit)
	local key = string.lower(tostring(status or ""))
	if key == "accepted" then
		self.data.accepted = self.data.accepted + 1
	elseif key == "declined" then
		self.data.declined = self.data.declined + 1
	elseif key == "expired" then
		self.data.expired = self.data.expired + 1
	elseif key == "cancelled" then
		self.data.cancelled = self.data.cancelled + 1
	end
end

function TradeHistory:RecordTrade(trade)
	if type(trade) ~= "table" then
		return nil, "trade must be a table"
	end
	if trade.confirmed ~= true then
		return nil, "realized trades require explicit confirmation"
	end
	local now = self.clock()
	local entry = {
		id = trade.id or string.format("T-%d-%d", #self.data.trades + 1, now),
		giveItems = Util.deepCopy(trade.giveItems or {}),
		getItems = Util.deepCopy(trade.getItems or {}),
		giveValue = tonumber(trade.giveValue) or 0,
		getValue = tonumber(trade.getValue) or 0,
		profit = tonumber(trade.profit) or 0,
		percent = tonumber(trade.percent),
		confirmedAt = trade.confirmedAt or now,
		source = trade.source,
		note = trade.note,
	}
	self.data.trades[#self.data.trades + 1] = entry
	while #self.data.trades > self.maxTrades do
		table.remove(self.data.trades, 1)
	end
	local day = os.date("%Y-%m-%d", entry.confirmedAt)
	self.data.activity[day] = (self.data.activity[day] or 0) + 1
	return entry
end

function TradeHistory:SetInventoryValue(value)
	self.data.inventoryValue = tonumber(value) or 0
end

function TradeHistory:SetPotentialProfit(value)
	self.data.potentialProfit = tonumber(value) or 0
end

function TradeHistory:SetPendingProfit(value)
	self.data.pendingProfit = tonumber(value) or 0
end

function TradeHistory:_day()
	return os.date("%Y-%m-%d", self.clock())
end

function TradeHistory:Analytics(options)
	options = options or {}
	local trades = self.data.trades
	local confirmedProfit = 0
	local best = nil
	local worst = nil
	local bestPets = {}
	local profitByDay = {}
	local cumulative = {}
	local running = 0
	for index = 1, #trades do
		local trade = trades[index]
		confirmedProfit = confirmedProfit + (trade.profit or 0)
		if not best or (trade.profit or 0) > (best.profit or 0) then
			best = trade
		end
		if not worst or (trade.profit or 0) < (worst.profit or 0) then
			worst = trade
		end
		for _, item in ipairs(trade.getItems or {}) do
			local key = item.name
			if key then
				local bucket = bestPets[key] or { name = key, count = 0, value = 0 }
				bucket.count = bucket.count + (item.quantity or 1)
				bucket.value = bucket.value + (trade.profit or 0)
				bestPets[key] = bucket
			end
		end
		local day = os.date("%Y-%m-%d", trade.confirmedAt)
		profitByDay[day] = (profitByDay[day] or 0) + (trade.profit or 0)
		running = running + (trade.profit or 0)
		cumulative[#cumulative + 1] = { time = trade.confirmedAt, total = running }
	end
	local petList = {}
	for _, bucket in pairs(bestPets) do
		petList[#petList + 1] = bucket
	end
	table.sort(petList, function(a, b)
		if a.count == b.count then
			return a.name < b.name
		end
		return a.count > b.count
	end)
	local attempts = self.data.accepted + self.data.declined + self.data.expired
	local acceptanceRate = attempts > 0 and (self.data.accepted / attempts) * 100 or nil
	local dayKeys = Util.sortedKeys(profitByDay)
	local profitSeries = {}
	for index = 1, #dayKeys do
		profitSeries[#profitSeries + 1] = { label = dayKeys[index], value = profitByDay[dayKeys[index]] }
	end
	local activitySeries = {}
	local activityKeys = Util.sortedKeys(self.data.activity)
	for index = 1, #activityKeys do
		activitySeries[#activitySeries + 1] = { label = activityKeys[index], value = self.data.activity[activityKeys[index]] }
	end
	return {
		inspected = self.data.inspected,
		scans = self.data.scans,
		goodDeals = self.data.goodDeals,
		offersCreated = self.data.offersCreated,
		accepted = self.data.accepted,
		declined = self.data.declined,
		expired = self.data.expired,
		cancelled = self.data.cancelled,
		confirmedTradeCount = #trades,
		confirmedProfit = confirmedProfit,
		potentialProfit = options.potentialProfit or self.data.potentialProfit,
		pendingProfit = options.pendingProfit or self.data.pendingProfit,
		averageProfit = #trades > 0 and (confirmedProfit / #trades) or 0,
		bestTrade = best,
		worstTrade = worst,
		acceptanceRate = acceptanceRate,
		bestPets = petList,
		profitSeries = profitSeries,
		activitySeries = activitySeries,
		profitOverTime = cumulative,
		inventoryValue = options.inventoryValue or self.data.inventoryValue,
		listingStats = options.listingStats,
	}
end

function TradeHistory:Save()
	if not self.storage or not self.jsonEncode then
		return false, "storage unavailable"
	end
	local payload = {
		schemaVersion = TradeHistory.SchemaVersion,
		savedAt = self.clock(),
		data = self.data,
	}
	local ok, encoded = pcall(self.jsonEncode, payload)
	if not ok or not encoded then
		return false, "history encode failed"
	end
	local writeOk, err = self.storage.write(self.path, encoded)
	if not writeOk then
		return false, tostring(err)
	end
	return true
end

function TradeHistory:Load()
	if not self.storage or not self.jsonDecode then
		return false, "storage unavailable"
	end
	local okRead, content = self.storage.read(self.path)
	if not okRead or not content then
		return false, "no saved history"
	end
	local okDecode, decoded = pcall(self.jsonDecode, content)
	if not okDecode or type(decoded) ~= "table" then
		return false, "history is not valid JSON"
	end
	if decoded.schemaVersion ~= TradeHistory.SchemaVersion then
		return false, "history schema mismatch"
	end
	if type(decoded.data) == "table" then
		for key, value in pairs(decoded.data) do
			self.data[key] = value
		end
	end
	return true
end

function TradeHistory:Clear()
	self.data = {
		scans = 0,
		inspected = 0,
		goodDeals = 0,
		offersCreated = 0,
		accepted = 0,
		declined = 0,
		expired = 0,
		cancelled = 0,
		trades = {},
		activity = {},
		inventoryValue = 0,
		potentialProfit = 0,
		pendingProfit = 0,
	}
	if self.storage then
		pcall(self.storage.remove, self.path)
	end
end

function TradeHistory:Snapshot()
	return Util.deepCopy(self.data)
end

return TradeHistory
