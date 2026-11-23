local TestRunner = require("./TestRunner")
local Json = require("./Support/Json")
local Mock = require("./Support/Mock")
local ValueEngine = require("../Values/ValueEngine")
local ProfitCalculator = require("../Trading/ProfitCalculator")
local TradeEvaluator = require("../Trading/TradeEvaluator")
local OfferAnalyzer = require("../Trading/OfferAnalyzer")
local ListingScanner = require("../Trading/ListingScanner")
local OfferEngine = require("../Trading/OfferEngine")
local ListingManager = require("../Trading/ListingManager")
local OfferQueue = require("../Trading/OfferQueue")
local TradeHistory = require("../Trading/TradeHistory")
local PetDatabase = require("../Inventory/PetDatabase")
local InventoryReader = require("../Inventory/InventoryReader")
local InventoryValuator = require("../Inventory/InventoryValuator")

local describe = TestRunner.describe
local it = TestRunner.it

local function buildEngine()
	local engine = ValueEngine.new()
	engine:SetDataset(Mock.Dataset())
	return engine
end

local function buildReader(engine)
	local db = PetDatabase.new({ engine = engine })
	return InventoryReader.new({ db = db, jsonDecode = Json.decode }), db
end

describe("ProfitCalculator", function()
	it("classifies thresholds from configurable percentages", function()
		TestRunner.eq(ProfitCalculator.Classify(30), "EXCELLENT")
		TestRunner.eq(ProfitCalculator.Classify(12), "GOOD")
		TestRunner.eq(ProfitCalculator.Classify(0), "FAIR")
		TestRunner.eq(ProfitCalculator.Classify(-10), "SMALL_LOSS")
		TestRunner.eq(ProfitCalculator.Classify(-30), "BAD")
		TestRunner.eq(ProfitCalculator.StatusLabel("GOOD"), "GOOD DEAL")
		TestRunner.eq(ProfitCalculator.StatusLabel("BAD"), "BAD DEAL")
		TestRunner.eq(ProfitCalculator.StatusLabel("INCOMPLETE"), "INCOMPLETE DATA")
	end)

	it("computes the documented 100 -> 125 example", function()
		local diff = ProfitCalculator.Difference(125, 100)
		local percent = ProfitCalculator.Percent(diff, 100)
		TestRunner.near(diff, 25)
		TestRunner.near(percent, 25)
	end)

	it("returns nil percent when your offer has no value", function()
		TestRunner.eq(ProfitCalculator.Percent(10, 0), nil)
	end)
end)

describe("TradeEvaluator and OfferAnalyzer", function()
	it("evaluates give/get with AMVGG only values", function()
		local evaluator = TradeEvaluator.new({ engine = buildEngine() })
		local summary = evaluator:Evaluate({ Mock.Item("Owl") }, { Mock.Item("Frost Dragon") })
		TestRunner.eq(summary.confidence, "COMPLETE")
		TestRunner.near(summary.yourValue, 1.355)
		TestRunner.near(summary.theirValue, 1.76)
		TestRunner.near(summary.difference, 0.405)
		TestRunner.eq(summary.statusLabel, "GOOD DEAL")
	end)

	it("recommends acceptance only after explicit confirmation", function()
		local engine = buildEngine()
		local reader = buildReader(engine)
		local evaluator = TradeEvaluator.new({ engine = engine })
		local analyzer = OfferAnalyzer.new({ evaluator = evaluator, reader = reader })
		local analysis = analyzer:Analyze({
			id = "O1",
			offeredItems = { Mock.Item("Giraffe") },
			requestedItems = { Mock.Item("Owl") },
		}, { inventory = Mock.Inventory() })
		TestRunner.eq(analysis.recommendation, "ACCEPT_AFTER_CONFIRMATION")
		TestRunner.truthy(analysis.requiresConfirmation)
		TestRunner.truthy(#analysis.reasons >= 2)
	end)

	it("flags incomplete offers for verification", function()
		local analyzer = OfferAnalyzer.new({ evaluator = TradeEvaluator.new({ engine = buildEngine() }) })
		local analysis = analyzer:Analyze({
			offeredItems = { Mock.Item("Unknown Pet") },
			requestedItems = { Mock.Item("Owl") },
		})
		TestRunner.eq(analysis.recommendation, "VERIFY_DATA")
		TestRunner.eq(analysis.confidence, "INCOMPLETE")
	end)
end)

describe("InventoryReader and InventoryValuator", function()
	it("parses common manual inventory lines", function()
		local engine = buildEngine()
		local reader = buildReader(engine)
		local items, errors = reader:ParseText([[
2x Bat Dragon
MFR Giraffe
Neon Fly Ride Owl
Parrot
]])
		TestRunner.eq(#errors, 0)
		TestRunner.eq(#items, 4)
		TestRunner.eq(items[1].name, "Bat Dragon")
		TestRunner.eq(items[1].quantity, 2)
		local giraffe = items[2]
		TestRunner.eq(giraffe.variant, "mega")
		TestRunner.truthy(giraffe.fly)
		TestRunner.truthy(giraffe.ride)
		local owl = items[3]
		TestRunner.eq(owl.variant, "neon")
		TestRunner.truthy(owl.fly)
	end)

	it("aggregates duplicates and values the inventory", function()
		local engine = buildEngine()
		local reader = buildReader(engine)
		local items = reader:ParseText("Bat Dragon\nBat Dragon\nOwl")
		TestRunner.eq(#items, 2)
		TestRunner.eq(items[1].quantity, 2)
		local valuator = InventoryValuator.new({ engine = engine })
		local result = valuator:Valuate(items)
		TestRunner.near(result.total, 5.53 * 2 + 1.355)
		TestRunner.eq(result.top.name, "Bat Dragon")
		TestRunner.eq(result.count, 3)
	end)

	it("keeps unknown pets explicit instead of guessing", function()
		local engine = buildEngine()
		local reader = buildReader(engine)
		local items = reader:ParseText("Imaginary Dragon")
		TestRunner.eq(items[1].known, false)
		local valuator = InventoryValuator.new({ engine = engine })
		local result = valuator:Valuate(items)
		TestRunner.truthy(result.incomplete)
		TestRunner.eq(result.missingCount, 1)
	end)

	it("supports JSON inventory import", function()
		local engine = buildEngine()
		local reader = buildReader(engine)
		local items, errors = reader:ParseText(Json.encode({
			{ name = "Bat Dragon", variant = "mega", fly = true, ride = true, quantity = 1 },
		}))
		TestRunner.eq(#errors, 0)
		TestRunner.eq(items[1].variant, "mega")
	end)
end)

describe("OfferEngine", function()
	it("builds profitable inventory-aware candidates below the target value", function()
		local engine = buildEngine()
		local offerEngine = OfferEngine.new({ engine = engine })
		local result = offerEngine:Recommend({
			inventory = Mock.Inventory(),
			targets = { Mock.Item("Giraffe") },
			maxItems = 4,
			minProfit = 0.5,
			minGainPercent = 5,
			minFillPercent = 60,
			maxCandidates = 10,
		})
		TestRunner.truthy(#result.candidates > 0)
		for _, candidate in ipairs(result.candidates) do
			TestRunner.truthy(candidate.yourValue < candidate.targetValue)
			TestRunner.truthy(candidate.profit >= 0.4999)
			TestRunner.truthy(candidate.percent >= 5)
			TestRunner.truthy(candidate.itemCount <= 4)
			TestRunner.truthy(#candidate.giveItems > 0)
		end
	end)

	it("refuses to build offers without a verified target value", function()
		local offerEngine = OfferEngine.new({ engine = buildEngine() })
		local result = offerEngine:Recommend({
			inventory = Mock.Inventory(),
			targets = { Mock.Item("Unknown Pet") },
		})
		TestRunner.eq(#result.candidates, 0)
		TestRunner.truthy(#result.warnings > 0)
	end)
end)

describe("ListingScanner", function()
	local text = [[
id: L101
seller: 777
offer: Giraffe
want: Owl

id: L102
offer: Unknown Pet
want: Owl
]]

	it("parses, evaluates and deduplicates imported listings", function()
		local engine = buildEngine()
		local reader = buildReader(engine)
		local evaluator = TradeEvaluator.new({ engine = engine })
		local scanner = ListingScanner.new({
			reader = reader,
			evaluator = evaluator,
			clock = Mock.Clock(9000).now,
		})
		local result = scanner:Scan(text)
		TestRunner.eq(result.stats.blocks, 2)
		TestRunner.eq(result.stats.parsed, 2)
		TestRunner.eq(result.stats.incomplete, 1)
		TestRunner.eq(result.listings[1].id, "L101")
		TestRunner.eq(result.listings[1].statusLabel, "GOOD DEAL")
		TestRunner.eq(result.listings[2].listingStatus, "INCOMPLETE DATA")
		local second = scanner:Scan(text)
		TestRunner.eq(second.stats.duplicates, 2)
		TestRunner.eq(#second.listings, 0)
	end)

	it("applies filters and never fabricates empty results", function()
		local engine = buildEngine()
		local reader = buildReader(engine)
		local scanner = ListingScanner.new({
			reader = reader,
			evaluator = TradeEvaluator.new({ engine = engine }),
		})
		local result = scanner:Scan(text, { filters = { minProfit = 100 } })
		TestRunner.eq(#result.listings, 0)
		local empty = scanner:Scan("")
		TestRunner.eq(#empty.listings, 0)
		TestRunner.truthy(#empty.warnings > 0)
	end)
end)

describe("ListingManager", function()
	local function build()
		local clock = Mock.Clock(1000)
		local manager = ListingManager.new({ clock = clock.now, staleSeconds = 60 })
		return manager, clock
	end

	it("requires explicit confirmation to publish", function()
		local manager = build()
		local draft = manager:Draft({ items = { Mock.Item("Owl") }, askItems = { Mock.Item("Giraffe") } })
		TestRunner.truthy(draft)
		local listing, err = manager:Publish(draft.id)
		TestRunner.falsy(listing)
		TestRunner.contains(err, "confirmation")
		local published, publishErr = manager:Publish(draft.id, { confirmed = true })
		TestRunner.truthy(published, publishErr)
		TestRunner.eq(published.status, "ACTIVE")
	end)

	it("marks stale listings without auto cancelling", function()
		local manager, clock = build()
		local draft = manager:Draft({ items = { Mock.Item("Owl") } })
		local listing = manager:Publish(draft.id, { confirmed = true })
		clock.advance(61)
		local stale = manager:Tick()
		TestRunner.eq(#stale, 1)
		TestRunner.eq(manager:Get(listing.id).status, "STALE")
		local suggestion = manager:RefreshSuggestion(listing.id)
		TestRunner.truthy(string.find(suggestion.message, "stale", 1, true))
	end)

	it("warns before cancelling a listing with pending offers", function()
		local manager = build()
		local draft = manager:Draft({ items = { Mock.Item("Owl") } })
		local listing = manager:Publish(draft.id, { confirmed = true })
		manager:AddOffer(listing.id, { offeredItems = { Mock.Item("Giraffe") }, requestedItems = { Mock.Item("Owl") } })
		local cancelled, err = manager:Cancel(listing.id, { confirmed = true })
		TestRunner.falsy(cancelled)
		TestRunner.contains(err, "pending")
		local forced = manager:Cancel(listing.id, { confirmed = true, force = true })
		TestRunner.truthy(forced)
		TestRunner.eq(forced.status, "CANCELLED")
	end)
end)

describe("OfferQueue", function()
	local function offer()
		return {
			listingId = "L1",
			offeredItems = { Mock.Item("Giraffe") },
			requestedItems = { Mock.Item("Owl") },
			profit = 1.235,
			percent = 91.1,
		}
	end

	it("deduplicates active offers", function()
		local queue = OfferQueue.new({ clock = Mock.Clock(100).now })
		local first, created = queue:Add(offer())
		TestRunner.truthy(created)
		local second, createdAgain, reason = queue:Add(offer())
		TestRunner.falsy(createdAgain)
		TestRunner.eq(second.id, first.id)
		TestRunner.contains(reason, "duplicate")
	end)

	it("requires confirmation for acceptance and validates transitions", function()
		local queue = OfferQueue.new({ clock = Mock.Clock(100).now })
		local entry = queue:Add(offer())
		local accepted, err = queue:MarkAccepted(entry.id)
		TestRunner.falsy(accepted)
		TestRunner.contains(err, "confirmation")
		local confirmed = queue:MarkAccepted(entry.id, { confirmed = true })
		TestRunner.truthy(confirmed)
		TestRunner.eq(confirmed.status, "ACCEPTED")
		local declined, transitionError = queue:Transition(entry.id, "DECLINED")
		TestRunner.falsy(declined)
		TestRunner.contains(transitionError, "invalid transition")
	end)

	it("expires pending offers after the configured timeout", function()
		local clock = Mock.Clock(100)
		local queue = OfferQueue.new({ clock = clock.now, timeoutSeconds = 60 })
		local entry = queue:Add(offer())
		clock.advance(30)
		TestRunner.eq(#queue:Tick(), 0)
		clock.advance(31)
		local expired = queue:Tick()
		TestRunner.eq(#expired, 1)
		TestRunner.eq(queue:Get(entry.id).status, "EXPIRED")
		TestRunner.eq(queue:PendingCount(), 0)
	end)
end)

describe("TradeHistory", function()
	it("counts only confirmed trades as realized profit", function()
		local history = TradeHistory.new({ clock = Mock.Clock(1000).now })
		local rejected, err = history:RecordTrade({ profit = 5, giveItems = {}, getItems = {} })
		TestRunner.falsy(rejected)
		TestRunner.contains(err, "confirmation")
		local first = history:RecordTrade({
			profit = 3,
			percent = 20,
			giveValue = 15,
			getValue = 18,
			confirmed = true,
			giveItems = { Mock.Item("Owl") },
			getItems = { Mock.Item("Unicorn") },
		})
		TestRunner.truthy(first)
		history:RecordTrade({
			profit = -1,
			percent = -10,
			confirmed = true,
			giveItems = { Mock.Item("Parrot") },
			getItems = { Mock.Item("Dog") },
		})
		history:RecordOfferStatus("accepted")
		history:RecordOfferStatus("declined")
		history:RecordScan({ stats = { parsed = 4, goodDeals = 2 } })
		local analytics = history:Analytics({ inventoryValue = 42, potentialProfit = 2, pendingProfit = 1 })
		TestRunner.eq(analytics.confirmedProfit, 2)
		TestRunner.eq(analytics.confirmedTradeCount, 2)
		TestRunner.eq(analytics.inspected, 4)
		TestRunner.eq(analytics.goodDeals, 2)
		TestRunner.eq(analytics.accepted, 1)
		TestRunner.near(analytics.acceptanceRate, 50)
		TestRunner.eq(analytics.inventoryValue, 42)
		TestRunner.eq(analytics.bestTrade.profit, 3)
		TestRunner.eq(analytics.worstTrade.profit, -1)
	end)

	it("persists and reloads analytics", function()
		local storage = Mock.Storage()
		local clock = Mock.Clock(2000)
		local history = TradeHistory.new({
			clock = clock.now,
			storage = storage,
			jsonEncode = Json.encode,
			jsonDecode = Json.decode,
		})
		history:RecordTrade({ profit = 4, confirmed = true, getItems = { Mock.Item("Owl") } })
		TestRunner.truthy(history:Save())
		local restored = TradeHistory.new({
			clock = clock.now,
			storage = storage,
			jsonEncode = Json.encode,
			jsonDecode = Json.decode,
		})
		TestRunner.truthy(restored:Load())
		TestRunner.eq(restored:Analytics().confirmedProfit, 4)
	end)
end)

return true
