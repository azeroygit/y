local Util = require("./Core/Util")
local EventBus = require("./Core/EventBus")
local StateManager = require("./Core/StateManager")
local Logger = require("./Core/Logger")
local ErrorHandler = require("./Core/ErrorHandler")
local TaskScheduler = require("./Core/TaskScheduler")
local ConfigManager = require("./Core/ConfigManager")
local Runtime = require("./Core/Runtime")
local ValueParser = require("./Values/ValueParser")
local ValueValidator = require("./Values/ValueValidator")
local ValueCache = require("./Values/ValueCache")
local AMVGGProvider = require("./Values/AMVGGProvider")
local ValueEngine = require("./Values/ValueEngine")
local PetDatabase = require("./Inventory/PetDatabase")
local InventoryReader = require("./Inventory/InventoryReader")
local InventoryValuator = require("./Inventory/InventoryValuator")
local ProfitCalculator = require("./Trading/ProfitCalculator")
local TradeEvaluator = require("./Trading/TradeEvaluator")
local OfferAnalyzer = require("./Trading/OfferAnalyzer")
local ListingScanner = require("./Trading/ListingScanner")
local OfferEngine = require("./Trading/OfferEngine")
local ListingManager = require("./Trading/ListingManager")
local OfferQueue = require("./Trading/OfferQueue")
local TradeHistory = require("./Trading/TradeHistory")
local Personality = require("./Kiria/Personality")
local Memory = require("./Kiria/Memory")
local Reactions = require("./Kiria/Reactions")
local Companion = require("./Kiria/Companion")

local App = {}
App.__index = App

local function readJson(storage, path, jsonDecode)
	local ok, content = storage.read(path)
	if not ok or not content then
		return nil
	end
	local decodedOk, decoded = pcall(jsonDecode, content)
	if not decodedOk or type(decoded) ~= "table" then
		return nil
	end
	return decoded
end

local function variantLabel(item)
	local variant = item.variant or "regular"
	local tags = {}
	if variant == "neon" then
		tags[#tags + 1] = "Neon"
	elseif variant == "mega" then
		tags[#tags + 1] = "Mega Neon"
	end
	if item.fly then
		tags[#tags + 1] = "Fly"
	end
	if item.ride then
		tags[#tags + 1] = "Ride"
	end
	if #tags == 0 then
		return item.name
	end
	return item.name .. " (" .. table.concat(tags, " ") .. ")"
end

local function describeItems(items)
	local parts = {}
	for index = 1, #(items or {}) do
		local item = items[index]
		local quantity = item.quantity or 1
		local text = variantLabel(item)
		if quantity > 1 then
			text = quantity .. "x " .. text
		end
		parts[#parts + 1] = text
	end
	if #parts == 0 then
		return "nothing"
	end
	return table.concat(parts, ", ")
end

function App.new(options)
	options = options or {}
	local self = setmetatable({
		runtime = options.runtime or Runtime.Create({}),
		bus = EventBus.new("KiriaAutoTrader"),
		running = false,
		started = false,
		lastTickAt = 0,
		lastSaveAt = 0,
		stopped = false,
	}, App)
	self.storage = self.runtime.storage
	self.jsonEncode = options.jsonEncode or function(value)
		return self.runtime:JsonEncode(value)
	end
	self.jsonDecode = options.jsonDecode or function(value)
		return self.runtime:JsonDecode(value)
	end
	self.logger = Logger.new({
		level = options.logLevel or "INFO",
		bufferSize = 300,
		sink = function(entry)
			if self.state then
				local logs = self.state:Get("logs") or {}
				local copy = {}
				for index = 1, #logs do
					copy[index] = logs[index]
				end
				copy[#copy + 1] = entry
				while #copy > 80 do
					table.remove(copy, 1)
				end
				self.state:Set("logs", copy)
			end
		end,
	})
	self.errorHandler = ErrorHandler.new({
		logger = self.logger,
		onError = function(message)
			if self.state then
				self:_Notify("error", message, "ERROR")
			end
		end,
	})
	self.scheduler = TaskScheduler.new({
		now = function()
			return os.clock()
		end,
		errorHandler = self.errorHandler,
	})
	local savedSettings = readJson(self.storage, ConfigManager.Defaults.Data.SettingsFile, self.jsonDecode)
	self.config = ConfigManager.new({
		defaults = ConfigManager.Defaults,
		saved = savedSettings or {},
		storage = self.storage,
		jsonEncode = self.jsonEncode,
		logger = self.logger,
	})
	local config = self.config
	self.thresholds = config:Get("Thresholds") or ProfitCalculator.DefaultThresholds
	self.cache = ValueCache.new({
		storage = self.storage,
		jsonEncode = self.jsonEncode,
		jsonDecode = self.jsonDecode,
		clock = function()
			return os.time()
		end,
		path = config:Get("Values.CacheFile"),
		logger = self.logger,
	})
	self.parser = ValueParser.new({
		jsonDecode = self.jsonDecode,
		jsonEncode = self.jsonEncode,
		minPetCount = config:Get("Values.MinPetCount"),
	})
	self.validator = ValueValidator.new({
		minPetCount = config:Get("Values.MinPetCount"),
	})
	self.provider = AMVGGProvider.new({
		http = function(url)
			return self.runtime:HttpGet(url, config:Get("Values.RequestTimeoutSeconds"))
		end,
		cache = self.cache,
		parser = self.parser,
		validator = self.validator,
		logger = self.logger,
		errorHandler = self.errorHandler,
		now = function()
			return os.time()
		end,
		wait = function(seconds)
			return self.runtime:Wait(seconds)
		end,
		minRefreshInterval = config:Get("Values.MinRefreshIntervalSeconds"),
		maxRetries = config:Get("Values.MaxRetries"),
	})
	self.engine = ValueEngine.new({
		provider = self.provider,
		thresholds = self.thresholds,
	})
	self.db = PetDatabase.new({ engine = self.engine })
	self.reader = InventoryReader.new({
		db = self.db,
		jsonDecode = self.jsonDecode,
	})
	self.valuator = InventoryValuator.new({ engine = self.engine })
	self.evaluator = TradeEvaluator.new({ engine = self.engine, thresholds = self.thresholds })
	self.analyzer = OfferAnalyzer.new({ evaluator = self.evaluator, reader = self.reader })
	self.scanner = ListingScanner.new({
		reader = self.reader,
		evaluator = self.evaluator,
		clock = function()
			return os.time()
		end,
		logger = self.logger,
		maxSeenHistory = config:Get("Scanner.MaxSeenHistory"),
	})
	self.offerEngine = OfferEngine.new({ engine = self.engine, thresholds = self.thresholds })
	self.listingManager = ListingManager.new({
		clock = function()
			return os.time()
		end,
		staleSeconds = config:Get("Listings.StaleSeconds"),
		warnBeforeCancelPendingOffers = config:Get("Listings.WarnBeforeCancelPendingOffers"),
	})
	self.offerQueue = OfferQueue.new({
		clock = function()
			return os.time()
		end,
		timeoutSeconds = config:Get("Offers.ResponseTimeoutSeconds"),
	})
	self.history = TradeHistory.new({
		clock = function()
			return os.time()
		end,
		storage = self.storage,
		jsonEncode = self.jsonEncode,
		jsonDecode = self.jsonDecode,
		path = config:Get("Data.HistoryFile"),
	})
	self.history:Load()
	self.bus:Connect("kiria:message", function(message)
		if self.state then
			self.state:Set("kiria", {
				text = message.text,
				mood = message.mood,
				event = message.event,
				at = message.at,
				rank = message.rank,
			})
		end
	end)
	self.bus:Connect("kiria:promotion", function(info)
		self:_Notify("kiria", "Kiria promotion: " .. tostring(info.rank), "SUCCESS")
	end)
	local personality = Personality.new()
	local memory = Memory.new({
		storage = self.storage,
		jsonEncode = self.jsonEncode,
		jsonDecode = self.jsonDecode,
		path = config:Get("Data.KiriaMemoryFile"),
		clock = function()
			return os.time()
		end,
	})
	self.companion = Companion.new({
		memory = memory,
		personality = personality,
		reactions = Reactions.new({ personality = personality }),
		bus = self.bus,
		clock = function()
			return os.time()
		end,
	})
	self.companion:Init()
	local valueSnapshot = self.provider:GetSnapshot()
	if valueSnapshot.dataset then
		self.engine:SetDataset(valueSnapshot.dataset)
		self.db:Refresh()
	end
	self.state = StateManager.new({
		page = "Dashboard",
		sessionStartedAt = os.time(),
		valuesStatus = valueSnapshot.status == "ok" and "cached" or "idle",
		valuesError = nil,
		lastUpdated = valueSnapshot.lastSuccessAt,
		petCount = valueSnapshot.petCount,
		valuesMode = valueSnapshot.mode,
		valuesFromCache = valueSnapshot.fromCache,
		valuesAge = valueSnapshot.age,
		inventoryText = "",
		inventory = {},
		inventorySummary = {
			total = 0,
			count = 0,
			formatted = "0",
			topPet = nil,
			topValue = nil,
			incomplete = false,
			missingCount = 0,
			byVariant = {
				regular = { count = 0, value = 0 },
				neon = { count = 0, value = 0 },
				mega = { count = 0, value = 0 },
			},
		},
		inventoryErrors = {},
		inventorySelection = {},
		inventoryQuery = "",
		inventoryVariant = "",
		inventoryFly = "any",
		inventoryRide = "any",
		inventoryDemand = "",
		inventorySort = "value",
		listings = {},
		scanStats = {},
		scanErrors = {},
		scanWarnings = {},
		scanText = "",
		listingFilters = {
			minValue = 0,
			minProfit = 0,
			minGainPercent = 0,
			status = "",
			onlyComplete = false,
		},
		offers = {},
		offerStats = {},
		offersText = "",
		offerAnalysis = nil,
		offerCandidates = {},
		offerWarnings = {},
		offerTargetText = "",
		kiria = {
			text = "Kiria is loading the terminal.",
			mood = "calm",
		},
		kiriaStats = self.companion:Stats(),
		analytics = {},
		toasts = {},
		logs = {},
		pendingProfit = 0,
		potentialProfit = 0,
		busy = { refresh = false, scan = false, offers = false },
		config = config:Snapshot(),
		configWarnings = config:Warnings(),
		lastSavedAt = nil,
		storagePersistent = self.runtime.hasFileApi,
		httpAvailable = self.runtime.requestFunction ~= nil or self.runtime.httpService ~= nil,
		providerStats = self.provider:Stats(),
	})
	self:_LoadInventory()
	self:_RefreshAnalytics()
	return self
end

function App:_Notify(kind, message, level)
	if not self.state then
		return
	end
	local toasts = self.state:Get("toasts") or {}
	local copy = {}
	for index = 1, #toasts do
		copy[index] = toasts[index]
	end
	copy[#copy + 1] = {
		id = tostring(os.time()) .. "-" .. tostring(math.random(1, 100000)),
		kind = kind,
		message = message,
		level = level or "INFO",
		at = os.time(),
	}
	while #copy > 6 do
		table.remove(copy, 1)
	end
	self.state:Set("toasts", copy)
end

function App:DismissToast(id)
	local toasts = self.state:Get("toasts") or {}
	local copy = {}
	for index = 1, #toasts do
		if toasts[index].id ~= id then
			copy[#copy + 1] = toasts[index]
		end
	end
	self.state:Set("toasts", copy)
end

function App:GetState()
	return self.state
end

function App:GetLogs()
	return self.logger:Recent(80)
end

function App:SetPage(page)
	self.state:Set("page", page)
end

function App:GetListings()
	return self.state:Get("listings") or {}
end

function App:GetOfferStats()
	return self.offerQueue:Stats()
end

function App:GetAnalytics()
	local listingStats = self.listingManager:Stats()
	local pending = self.offerQueue:PendingProfit()
	local potential = 0
	local listings = self.state:Get("listings") or {}
	for index = 1, #listings do
		local listing = listings[index]
		if listing.potentialProfit and listing.potentialProfit > 0 then
			potential = potential + listing.potentialProfit
		end
	end
	self.history:SetPendingProfit(pending)
	self.history:SetPotentialProfit(potential)
	self.state:Set("pendingProfit", pending)
	self.state:Set("potentialProfit", potential)
	return self.history:Analytics({
		inventoryValue = (self.state:Get("inventorySummary") or {}).total or 0,
		potentialProfit = potential,
		pendingProfit = pending,
		listingStats = listingStats,
	})
end

function App:_RefreshAnalytics()
	if not self.state then
		return
	end
	local analytics = self:GetAnalytics()
	self.state:Set("analytics", analytics)
	self.state:Set("offerStats", self.offerQueue:Stats())
	self.state:Set("kiriaStats", self.companion:Stats())
end

function App:_ApplyValueSnapshot(snapshot)
	if not snapshot then
		return
	end
	self.state:Set("valuesStatus", snapshot.status)
	self.state:Set("valuesError", snapshot.lastError)
	self.state:Set("lastUpdated", snapshot.lastSuccessAt)
	self.state:Set("petCount", snapshot.petCount)
	self.state:Set("valuesMode", snapshot.mode)
	self.state:Set("valuesFromCache", snapshot.fromCache)
	self.state:Set("providerStats", self.provider:Stats())
end

function App:RefreshValues(manual)
	if self.state:Get("busy").refresh then
		self:_Notify("values", "An AMVGG refresh is already running.", "WARN")
		return false
	end
	local busy = Util.shallowCopy(self.state:Get("busy"))
	busy.refresh = true
	self.state:Set("busy", busy)
	self.state:Set("valuesStatus", "loading")
	local function work()
		local result = self.provider:Refresh(manual == true)
		if result.ok then
			self.engine:SetDataset(result.dataset)
			self.db:Refresh()
			self:_ApplyValueSnapshot(self.provider:GetSnapshot())
			self.state:Set("valuesStatus", "ok")
			local count = result.dataset.count or #result.dataset.pets
			self:_Notify("values", string.format("AMVGG refreshed: %d pets.", count), "SUCCESS")
			self.companion:React("values_updated", {
				count = count,
				time = Util.formatTime(result.dataset.fetchedAt),
			})
			self:_RevaluateInventory()
			self:_RefreshAnalytics()
			self:SaveAll()
		else
			local snapshot = self.provider:GetSnapshot()
			self:_ApplyValueSnapshot(snapshot)
			if snapshot.dataset then
				self.engine:SetDataset(snapshot.dataset)
				self.db:Refresh()
			end
			local reason = result.error or snapshot.lastError or "unknown error"
			self:_Notify("values", "AMVGG refresh failed: " .. tostring(reason), "ERROR")
			self.companion:React("values_failed", { reason = tostring(reason) })
		end
		local busyNow = Util.shallowCopy(self.state:Get("busy"))
		busyNow.refresh = false
		self.state:Set("busy", busyNow)
	end
	if self.runtime:Spawn(work) then
		return true
	end
	work()
	return true
end

function App:_RevaluateInventory()
	local items = self.state:Get("inventory") or {}
	local raw = {}
	for index = 1, #items do
		local item = items[index]
		raw[#raw + 1] = {
			name = item.name,
			variant = item.variant,
			fly = item.fly,
			ride = item.ride,
			quantity = item.quantity,
		}
	end
	local valuation = self.valuator:Valuate(raw)
	self.state:Set("inventory", valuation.items)
	self.state:Set("inventorySummary", self.valuator:Summary(raw))
	self.history:SetInventoryValue(valuation.total)
	self:_RefreshAnalytics()
end

function App:ImportInventory(text)
	local items, errors = self.reader:ParseText(text or "")
	local valuation = self.valuator:Valuate(items)
	self.state:Set("inventoryText", text or "")
	self.state:Set("inventory", valuation.items)
	self.state:Set("inventoryErrors", errors)
	self.state:Set("inventorySummary", self.valuator:Summary(items))
	self.state:Set("inventorySelection", {})
	self.history:SetInventoryValue(valuation.total)
	self:_RefreshAnalytics()
	local summary = self.state:Get("inventorySummary")
	self:_Notify("inventory", string.format("Imported %d pets worth %s.", summary.count, summary.formatted), "SUCCESS")
	self.companion:React("inventory_imported", {
		count = summary.count,
		value = Util.formatNumber(summary.total),
	})
	self:_SaveInventory()
	self:SaveAll()
	return {
		items = valuation.items,
		summary = summary,
		errors = errors,
	}
end

function App:_SaveInventory()
	local text = self.state:Get("inventoryText") or ""
	local ok, encoded = pcall(self.jsonEncode, { text = text, savedAt = os.time() })
	if ok and encoded then
		self.storage.write(self.config:Get("Data.InventoryFile"), encoded)
	end
end

function App:_LoadInventory()
	local saved = readJson(self.storage, self.config:Get("Data.InventoryFile"), self.jsonDecode)
	if saved and type(saved.text) == "string" and saved.text ~= "" then
		local items, errors = self.reader:ParseText(saved.text)
		local valuation = self.valuator:Valuate(items)
		self.state:Set("inventoryText", saved.text)
		self.state:Set("inventory", valuation.items)
		self.state:Set("inventoryErrors", errors)
		self.state:Set("inventorySummary", self.valuator:Summary(items))
		self.history:SetInventoryValue(valuation.total)
	end
end

function App:SetInventoryFilters(filters)
	local current = self.state:Get("inventoryQuery") or ""
	self.state:Update({
		inventoryQuery = filters.query ~= nil and filters.query or current,
		inventoryVariant = filters.variant or self.state:Get("inventoryVariant"),
		inventoryFly = filters.fly or self.state:Get("inventoryFly"),
		inventoryRide = filters.ride or self.state:Get("inventoryRide"),
		inventoryDemand = filters.demand or self.state:Get("inventoryDemand"),
		inventorySort = filters.sort or self.state:Get("inventorySort"),
	})
end

function App:FilteredInventory()
	local items = self.state:Get("inventory") or {}
	local fly = self.state:Get("inventoryFly")
	local ride = self.state:Get("inventoryRide")
	return self.valuator:Filter(items, {
		query = self.state:Get("inventoryQuery"),
		variant = self.state:Get("inventoryVariant"),
		fly = fly == "yes" and true or (fly == "no" and false or nil),
		ride = ride == "yes" and true or (ride == "no" and false or nil),
		demand = self.state:Get("inventoryDemand"),
		sort = self.state:Get("inventorySort"),
	})
end

function App:ToggleInventorySelection(uid)
	local selection = self.state:Get("inventorySelection") or {}
	local copy = Util.shallowCopy(selection)
	if copy[uid] then
		copy[uid] = nil
	else
		copy[uid] = true
	end
	self.state:Set("inventorySelection", copy)
end

function App:ClearInventorySelection()
	self.state:Set("inventorySelection", {})
end

function App:SelectedInventoryItems()
	local selection = self.state:Get("inventorySelection") or {}
	local items = self.state:Get("inventory") or {}
	local result = {}
	for index = 1, #items do
		local item = items[index]
		if selection[item.uid] then
			result[#result + 1] = {
				name = item.name,
				variant = item.variant,
				fly = item.fly,
				ride = item.ride,
				quantity = item.quantity,
			}
		end
	end
	return result
end

function App:SetListingFilters(filters)
	local current = self.state:Get("listingFilters") or {}
	self.state:Set("listingFilters", {
		minValue = filters.minValue ~= nil and filters.minValue or current.minValue,
		minProfit = filters.minProfit ~= nil and filters.minProfit or current.minProfit,
		minGainPercent = filters.minGainPercent ~= nil and filters.minGainPercent or current.minGainPercent,
		status = filters.status ~= nil and filters.status or current.status,
		onlyComplete = filters.onlyComplete ~= nil and filters.onlyComplete or current.onlyComplete,
	})
end

function App:ScanListings(text, filters)
	local busy = Util.shallowCopy(self.state:Get("busy"))
	busy.scan = true
	self.state:Set("busy", busy)
	local result = self.scanner:Scan(text or "", { filters = filters or self.state:Get("listingFilters") })
	self.state:Set("listings", result.listings)
	self.state:Set("scanStats", result.stats)
	self.state:Set("scanErrors", result.errors)
	self.state:Set("scanWarnings", result.warnings)
	self.state:Set("scanText", text or "")
	self.history:RecordScan(result)
	self:_RefreshAnalytics()
	local deals = result.stats.goodDeals or 0
	local count = result.stats.parsed or 0
	if count > 0 then
		self:_Notify("scan", string.format("Scanned %d listings, %d good deals.", count, deals), deals > 0 and "SUCCESS" or "INFO")
		self.companion:React("scan_complete", {
			count = count,
			deals = deals,
			duplicates = result.stats.duplicates or 0,
		})
	else
		self:_Notify("scan", "No listings imported. Nothing was invented.", "WARN")
	end
	busy = Util.shallowCopy(self.state:Get("busy"))
	busy.scan = false
	self.state:Set("busy", busy)
	self:SaveAll()
	return result
end

function App:CreateListingDraft(itemsText, askText)
	local items, itemErrors = self.reader:ParseText(itemsText or "")
	local askItems, askErrors = self.reader:ParseText(askText or "")
	if #items == 0 then
		return nil, "Add at least one pet you want to list."
	end
	local draft, err = self.listingManager:Draft({ items = items, askItems = askItems })
	if not draft then
		return nil, err
	end
	if #itemErrors > 0 or #askErrors > 0 then
		self:_Notify("listing", "Draft created with some unparsed lines; review it before publishing.", "WARN")
	end
	self:_Notify("listing", "Draft " .. draft.id .. " created: " .. describeItems(items), "SUCCESS")
	self.companion:React("listing_created", {
		items = describeItems(items),
		ask = #askItems > 0 and describeItems(askItems) or "offers",
	})
	self.state:Set("drafts", self.listingManager.drafts)
	return draft
end

function App:PublishListing(draftId, options)
	options = options or {}
	if options.confirmed ~= true then
		return nil, "Publishing requires explicit confirmation."
	end
	local listing, err = self.listingManager:Publish(draftId, { confirmed = true })
	if not listing then
		return nil, err
	end
	self.state:Set("drafts", self.listingManager.drafts)
	self:_Notify("listing", "Listing published in the terminal: " .. listing.id, "SUCCESS")
	self:SaveAll()
	return listing
end

function App:GetListing(id)
	return self.listingManager:Get(id)
end

function App:GetDrafts()
	return self.listingManager.drafts
end

function App:CancelListing(id, options)
	options = options or {}
	local listing, err = self.listingManager:Cancel(id, options)
	if not listing then
		return nil, err
	end
	self:_Notify("listing", "Listing " .. id .. " marked cancelled in the terminal.", "WARN")
	return listing
end

function App:RepostListing(id, options)
	options = options or {}
	local listing, err = self.listingManager:Repost(id, options)
	if not listing then
		return nil, err
	end
	self:_Notify("listing", "Listing reposted in the terminal as " .. listing.id, "SUCCESS")
	return listing
end

function App:ListingSuggestion(id)
	return self.listingManager:RefreshSuggestion(id)
end

function App:EvaluateOffer(offeredText, requestedText, inventoryAware)
	local offeredItems, offeredErrors = self.reader:ParseText(offeredText or "")
	local requestedItems, requestedErrors = self.reader:ParseText(requestedText or "")
	local errors = {}
	for _, err in ipairs(offeredErrors) do
		errors[#errors + 1] = "offered: " .. err
	end
	for _, err in ipairs(requestedErrors) do
		errors[#errors + 1] = "requested: " .. err
	end
	if #offeredItems == 0 or #requestedItems == 0 then
		return nil, "Both sides need at least one pet.", errors
	end
	local offer = {
		id = "PREVIEW-" .. tostring(os.time()),
		offeredItems = offeredItems,
		requestedItems = requestedItems,
		createdAt = os.time(),
	}
	local analysis = self.analyzer:Analyze(offer, {
		inventory = inventoryAware ~= false and (self.state:Get("inventory") or {}) or nil,
	})
	analysis.errors = errors
	self.state:Set("offerAnalysis", analysis)
	self.state:Set("offersText", (offeredText or "") .. "\n---\n" .. (requestedText or ""))
	local event = analysis.confidence == "INCOMPLETE" and "incomplete" or nil
	if event then
		self.companion:React(event, {
			missing = analysis.evaluation.missing and analysis.evaluation.missing[1] and analysis.evaluation.missing[1].name or "an item",
		})
	end
	return analysis
end

function App:_OfferContext(offer, evaluation)
	return {
		listing = offer.listingId or offer.id or "manual offer",
		give = describeItems(offer.requestedItems),
		get = describeItems(offer.offeredItems),
		gain = Util.formatNumber(evaluation and evaluation.difference or 0),
		percent = Util.formatPercent(evaluation and evaluation.percent or 0),
	}
end

function App:AddOfferToQueue(analysis)
	analysis = analysis or self.state:Get("offerAnalysis")
	if not analysis or not analysis.evaluation then
		return nil, "Analyze an offer first."
	end
	local evaluation = analysis.evaluation
	local entry, created, reason = self.offerQueue:Add({
		listingId = analysis.offer.id,
		offeredItems = analysis.offer.offeredItems,
		requestedItems = analysis.offer.requestedItems,
		profit = evaluation.difference,
		percent = evaluation.percent,
	})
	if not entry then
		return nil, reason
	end
	if not created then
		return nil, "This offer is already in the queue."
	end
	entry.giveValue = evaluation.yourValue
	entry.getValue = evaluation.theirValue
	entry.difference = evaluation.difference
	entry.confidence = evaluation.confidence
	self.history:RecordOfferCreated(entry)
	self.state:Set("offers", self.offerQueue:List())
	self:_RefreshAnalytics()
	self:_Notify("offers", "Offer queued: " .. describeItems(entry.requestedItems) .. " for " .. describeItems(entry.offeredItems), "SUCCESS")
	self.companion:React("offer_received", self:_OfferContext(entry, evaluation))
	return entry
end

function App:GenerateOffers(targetText)
	local targets, errors = self.reader:ParseText(targetText or "")
	if #targets == 0 then
		return nil, "Enter the pet or pets you want to receive.", errors
	end
	local inventory = self.state:Get("inventory") or {}
	local result = self.offerEngine:Recommend({
		inventory = inventory,
		targets = targets,
		maxItems = self.config:Get("Offers.MaxItems"),
		minProfit = self.config:Get("Offers.MinProfit"),
		minGainPercent = self.config:Get("Offers.MinGainPercent"),
		maxCandidates = self.config:Get("Offers.MaxCandidates"),
	})
	self.state:Set("offerCandidates", result.candidates)
	self.state:Set("offerWarnings", result.warnings)
	self.state:Set("offerTargetText", targetText or "")
	if #result.candidates == 0 then
		self:_Notify("offers", "No safe offer combination found with the current limits.", "WARN")
	else
		self:_Notify("offers", string.format("Built %d offer candidate(s).", #result.candidates), "SUCCESS")
	end
	return result
end

function App:QueueCandidate(index)
	local candidates = self.state:Get("offerCandidates") or {}
	local candidate = candidates[index]
	if not candidate then
		return nil, "Candidate not found."
	end
	local entry, created, reason = self.offerQueue:Add({
		listingId = "TARGET-" .. tostring(os.time()),
		offeredItems = candidate.giveItems,
		requestedItems = candidate.targetItems,
		profit = candidate.profit,
		percent = candidate.percent,
	})
	if not entry then
		return nil, reason
	end
	if not created then
		return nil, "This offer is already queued."
	end
	entry.giveValue = candidate.yourValue
	entry.getValue = candidate.targetValue
	entry.difference = candidate.profit
	entry.confidence = "COMPLETE"
	self.history:RecordOfferCreated(entry)
	self.state:Set("offers", self.offerQueue:List())
	self:_RefreshAnalytics()
	self:_Notify("offers", "Candidate queued for manual sending: " .. describeItems(entry.requestedItems), "SUCCESS")
	return entry
end

function App:AcceptOffer(id, options)
	options = options or {}
	if options.confirmed ~= true then
		return nil, "Accepting an offer requires explicit confirmation."
	end
	local entry = self.offerQueue:Get(id)
	if not entry then
		return nil, "Offer not found."
	end
	local accepted, err = self.offerQueue:MarkAccepted(id, { confirmed = true })
	if not accepted then
		return nil, err
	end
	self.history:RecordOfferStatus("ACCEPTED", entry.profit)
	local recorded = nil
	if options.recordTrade == true then
		recorded = self.history:RecordTrade({
			confirmed = true,
			giveItems = entry.requestedItems,
			getItems = entry.offeredItems,
			giveValue = entry.giveValue or 0,
			getValue = entry.getValue or 0,
			profit = entry.difference or entry.profit or 0,
			percent = entry.percent,
			source = "offer-queue",
		})
		self.companion:React("trade_confirmed", {
			gain = entry.difference or entry.profit or 0,
			percent = entry.percent or 0,
			give = describeItems(entry.requestedItems),
			get = describeItems(entry.offeredItems),
		})
	end
	self.state:Set("offers", self.offerQueue:List())
	self:_RefreshAnalytics()
	self:_Notify("offers", recorded and "Trade recorded as confirmed." or "Offer marked accepted.", "SUCCESS")
	self:SaveAll()
	return accepted, recorded
end

function App:DeclineOffer(id)
	local entry = self.offerQueue:Get(id)
	if not entry then
		return nil, "Offer not found."
	end
	local declined, err = self.offerQueue:MarkDeclined(id)
	if not declined then
		return nil, err
	end
	self.history:RecordOfferStatus("DECLINED", entry.profit)
	self.state:Set("offers", self.offerQueue:List())
	self:_RefreshAnalytics()
	self:_Notify("offers", "Offer declined.", "INFO")
	self.companion:React("offer_declined", {})
	self:SaveAll()
	return declined
end

function App:CancelOffer(id)
	local entry = self.offerQueue:Get(id)
	if not entry then
		return nil, "Offer not found."
	end
	local cancelled, err = self.offerQueue:MarkCancelled(id)
	if not cancelled then
		return nil, err
	end
	self.history:RecordOfferStatus("CANCELLED", entry.profit)
	self.state:Set("offers", self.offerQueue:List())
	self:_RefreshAnalytics()
	self:_Notify("offers", "Offer cancelled.", "INFO")
	return cancelled
end

function App:RecordManualTrade(giveText, getText, options)
	options = options or {}
	if options.confirmed ~= true then
		return nil, "Recording a completed trade requires explicit confirmation."
	end
	local give, giveErrors = self.reader:ParseText(giveText or "")
	local get, getErrors = self.reader:ParseText(getText or "")
	if #give == 0 or #get == 0 then
		return nil, "Both sides need at least one pet."
	end
	local evaluation = self.evaluator:Evaluate(give, get)
	local trade, err = self.history:RecordTrade({
		confirmed = true,
		giveItems = give,
		getItems = get,
		giveValue = evaluation.yourValue,
		getValue = evaluation.theirValue,
		profit = evaluation.difference,
		percent = evaluation.percent,
		source = "manual",
		note = options.note,
	})
	if not trade then
		return nil, err
	end
	self._pendingManualErrors = giveErrors
	self:_RefreshAnalytics()
	self:_Notify("trades", "Confirmed trade recorded.", "SUCCESS")
	self.companion:React("trade_confirmed", {
		gain = evaluation.difference,
		percent = evaluation.percent,
		give = describeItems(give),
		get = describeItems(get),
	})
	self:SaveAll()
	return trade
end

function App:SetConfig(path, value)
	local ok, err = self.config:Set(path, value)
	if not ok then
		return false, err
	end
	self.thresholds = self.config:Get("Thresholds")
	self.evaluator:SetThresholds(self.thresholds)
	self.engine.thresholds = self.thresholds
	self.state:Set("config", self.config:Snapshot())
	self:_Notify("settings", "Setting saved: " .. tostring(path), "SUCCESS")
	if self.config:Get("Data.AutoSave") then
		self.config:Save()
	end
	return true
end

function App:SaveAll(force)
	if not self.config:Get("Data.AutoSave") and force ~= true then
		return false
	end
	self.config:Save()
	self.history:Save()
	self:_SaveInventory()
	if self.companion and self.companion.memory then
		self.companion.memory:Save()
	end
	self.state:Set("lastSavedAt", os.time())
	self.lastSaveAt = os.time()
	return true
end

function App:ResetData(kind)
	if kind == "history" then
		self.history:Clear()
		self:_Notify("data", "Analytics history cleared.", "WARN")
	elseif kind == "inventory" then
		self.state:Set("inventoryText", "")
		self.state:Set("inventory", {})
		self.state:Set("inventorySelection", {})
		self.state:Set("inventorySummary", self.valuator:Summary({}))
		self.storage.remove(self.config:Get("Data.InventoryFile"))
		self:_Notify("data", "Imported inventory cleared.", "WARN")
	elseif kind == "cache" then
		self.cache:Clear()
		self._cacheCleared = true
		self:_Notify("data", "AMVGG cache cleared. Refresh values to restore data.", "WARN")
	elseif kind == "settings" then
		self.config:Reset()
		self.thresholds = self.config:Get("Thresholds")
		self.state:Set("config", self.config:Snapshot())
		self:_Notify("data", "Settings reset to defaults.", "WARN")
	elseif kind == "kiria" then
		self.companion.memory:Clear()
		self:_Notify("data", "Kiria memory cleared.", "WARN")
	end
	self:_RefreshAnalytics()
end

function App:SearchPets(query, filters)
	return self.db:Search(query, filters)
end

function App:ProviderSnapshot()
	return self.provider:GetSnapshot()
end

function App:Tick()
	local now = os.time()
	local expired = self.offerQueue:Tick(now)
	for _, entry in ipairs(expired) do
		self.history:RecordOfferStatus("EXPIRED", entry.profit)
		self:_Notify("offers", "Offer expired without a response: " .. describeItems(entry.offeredItems), "WARN")
		self.companion:React("offer_expired", {
			give = describeItems(entry.requestedItems),
			get = describeItems(entry.offeredItems),
		})
	end
	local stale = self.listingManager:Tick(now)
	for _, listing in ipairs(stale) do
		self:_Notify("listing", "Listing " .. listing.id .. " is stale. Review it before cancelling.", "WARN")
		self.companion:React("listing_stale", {
			listing = listing.id,
			age = Util.formatDuration(now - listing.createdAt),
		})
	end
	if #expired > 0 or #stale > 0 then
		self.state:Set("offers", self.offerQueue:List())
		self:_RefreshAnalytics()
	end
	if now - self.lastSaveAt > 30 then
		self:SaveAll()
	end
end

function App:Start()
	if self.started then
		return self
	end
	self.started = true
	self.running = true
	self.companion:StartSession()
	self.state:Set("kiriaStats", self.companion:Stats())
	self.state:Set("providerStats", self.provider:Stats())
	if not self.runtime.hasFileApi then
		self:_Notify("storage", "File persistence is unavailable; settings and history stay in memory for this session.", "WARN")
	end
	if self.provider:Status() ~= "ok" then
		self:RefreshValues(false)
	end
	self.scheduler:Every("app-tick", 1, function()
		self:Tick()
	end)
	local refreshSeconds = self.config:Get("Values.RefreshIntervalSeconds")
	if refreshSeconds and refreshSeconds > 0 then
		self.scheduler:Every("amvgg-refresh", refreshSeconds, function()
			self:RefreshValues(false)
		end)
	end
	self.runtime:Spawn(function()
		while self.running do
			self.scheduler:Tick(os.clock())
			self.runtime:Wait(0.25)
		end
	end)
	self:_Notify("session", "KIRIA AUTOTRADER started. Values source: AMVGG only.", "SUCCESS")
	return self
end

function App:Shutdown()
	if self.stopped then
		return
	end
	self.stopped = true
	self.running = false
	self.scheduler:Clear()
	self:SaveAll(true)
	self.bus:Clear()
end

return App
