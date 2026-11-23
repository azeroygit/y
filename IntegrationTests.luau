local TestRunner = require("./TestRunner")
local Json = require("./Support/Json")
local Mock = require("./Support/Mock")
local ValueParser = require("../Values/ValueParser")
local ValueValidator = require("../Values/ValueValidator")
local ValueCache = require("../Values/ValueCache")
local ValueEngine = require("../Values/ValueEngine")
local AMVGGProvider = require("../Values/AMVGGProvider")
local PetDatabase = require("../Inventory/PetDatabase")
local InventoryReader = require("../Inventory/InventoryReader")
local InventoryValuator = require("../Inventory/InventoryValuator")
local TradeEvaluator = require("../Trading/TradeEvaluator")
local ListingScanner = require("../Trading/ListingScanner")
local OfferEngine = require("../Trading/OfferEngine")
local OfferQueue = require("../Trading/OfferQueue")
local TradeHistory = require("../Trading/TradeHistory")
local Personality = require("../Kiria/Personality")
local Memory = require("../Kiria/Memory")
local Companion = require("../Kiria/Companion")
local EventBus = require("../Core/EventBus")

local describe = TestRunner.describe
local it = TestRunner.it

describe("End-to-end pipeline", function()
	it("moves from AMVGG fetch to confirmed analytics without fabricating steps", function()
		local clock = Mock.Clock(50000)
		local storage = Mock.Storage()
		local bus = EventBus.new("integration")
		local cache = ValueCache.new({
			storage = storage,
			jsonEncode = Json.encode,
			jsonDecode = Json.decode,
			clock = clock.now,
		})
		local provider = AMVGGProvider.new({
			http = Mock.HttpResponse(Mock.Html()),
			cache = cache,
			parser = ValueParser.new({ jsonDecode = Json.decode, minPetCount = 2 }),
			validator = ValueValidator.new({ minPetCount = 2 }),
			now = clock.now,
			wait = function() end,
			minRefreshInterval = 0,
		})
		local refresh = provider:Refresh(true)
		TestRunner.truthy(refresh.ok)
		local engine = ValueEngine.new({ provider = provider })
		TestRunner.truthy(engine:RefreshFromProvider())
		TestRunner.eq(engine:Count(), 3)

		local db = PetDatabase.new({ engine = engine })
		local reader = InventoryReader.new({ db = db, jsonDecode = Json.decode })
		local inventory = reader:ParseText("2x Owl\nGiraffe")
		TestRunner.eq(#inventory, 2)
		local valuator = InventoryValuator.new({ engine = engine })
		local valuation = valuator:Valuate(inventory)
		TestRunner.near(valuation.total, 1.355 * 2 + 2.59)
		TestRunner.eq(valuation.top.name, "Giraffe")

		local evaluator = TradeEvaluator.new({ engine = engine })
		local scanner = ListingScanner.new({ reader = reader, evaluator = evaluator, clock = clock.now })
		local scan = scanner:Scan([[
id: LIVE-1
seller: 123
offer: Giraffe
want: Owl
]])
		TestRunner.eq(#scan.listings, 1)
		local listing = scan.listings[1]
		TestRunner.eq(listing.statusLabel, "GOOD DEAL")
		TestRunner.truthy(listing.potentialProfit > 0)

		local offerEngine = OfferEngine.new({ engine = engine })
		local recommendation = offerEngine:Recommend({
			inventory = inventory,
			targets = { Mock.Item("Giraffe") },
			maxItems = 2,
			minProfit = 0.5,
			minGainPercent = 5,
			minFillPercent = 0,
			maxCandidates = 5,
		})
		TestRunner.truthy(#recommendation.candidates > 0)
		local candidate = recommendation.candidates[1]
		TestRunner.truthy(candidate.profit >= 0.5)

		local queue = OfferQueue.new({ clock = clock.now, timeoutSeconds = 60 })
		local entry = queue:Add({
			listingId = listing.id,
			offeredItems = candidate.targetItems,
			requestedItems = candidate.giveItems,
			profit = candidate.profit,
			percent = candidate.percent,
		})
		local refused = queue:MarkAccepted(entry.id)
		TestRunner.falsy(refused)
		local accepted = queue:MarkAccepted(entry.id, { confirmed = true })
		TestRunner.truthy(accepted)

		local history = TradeHistory.new({ clock = clock.now, storage = storage, jsonEncode = Json.encode, jsonDecode = Json.decode })
		history:RecordScan(scan)
		history:RecordOfferCreated(entry)
		history:RecordOfferStatus("accepted", candidate.profit)
		local recorded = history:RecordTrade({
			confirmed = true,
			giveItems = candidate.giveItems,
			getItems = candidate.targetItems,
			giveValue = candidate.yourValue,
			getValue = candidate.targetValue,
			profit = candidate.profit,
			percent = candidate.percent,
		})
		TestRunner.truthy(recorded)
		local analytics = history:Analytics({ inventoryValue = valuation.total })
		TestRunner.eq(analytics.confirmedTradeCount, 1)
		TestRunner.near(analytics.confirmedProfit, candidate.profit)
		TestRunner.eq(analytics.inspected, 1)
		TestRunner.truthy(history:Save())

		local personality = Personality.new({ rng = function() return 1 end })
		local memory = Memory.new({
			storage = storage,
			jsonEncode = Json.encode,
			jsonDecode = Json.decode,
			clock = clock.now,
		})
		local companion = Companion.new({
			memory = memory,
			personality = personality,
			bus = bus,
			clock = clock.now,
		})
		companion:Init()
		local startMessage = companion:StartSession()
		TestRunner.contains(startMessage.text, "Kiria")
		local received = nil
		bus:Connect("kiria:message", function(message)
			received = message
		end)
		local reaction = companion:React("trade_confirmed", {
			gain = candidate.profit,
			percent = candidate.percent,
			give = "Owl",
			get = "Giraffe",
		})
		TestRunner.truthy(reaction)
		TestRunner.truthy(received)
		TestRunner.eq(companion:Stats().trades, 1)
		clock.advance(100)
		TestRunner.truthy(memory:Save())
	end)

	it("survives an AMVGG outage with cached values and honest status", function()
		local clock = Mock.Clock(1000)
		local storage = Mock.Storage()
		local cache = ValueCache.new({
			storage = storage,
			jsonEncode = Json.encode,
			jsonDecode = Json.decode,
			clock = clock.now,
		})
		local dataset = Mock.Dataset()
		dataset.fetchedAt = clock.now()
		cache:Save(dataset)
		local provider = AMVGGProvider.new({
			http = Mock.HttpError("AMVGG blocked"),
			cache = cache,
			parser = ValueParser.new({ jsonDecode = Json.decode, minPetCount = 2 }),
			validator = ValueValidator.new({ minPetCount = 2 }),
			now = clock.now,
			wait = function() end,
			minRefreshInterval = 0,
			maxRetries = 2,
		})
		local init = provider:Init({})
		TestRunner.truthy(init.ok)
		local failed = provider:Refresh(true)
		TestRunner.falsy(failed.ok)
		local snapshot = provider:GetSnapshot()
		TestRunner.eq(snapshot.status, "degraded")
		TestRunner.eq(snapshot.petCount, 8)
		TestRunner.eq(snapshot.fromCache, true)
		TestRunner.truthy(snapshot.lastError)
		local engine = ValueEngine.new({ provider = provider })
		TestRunner.truthy(engine:RefreshFromProvider())
		local value = engine:ValueOfItem({ name = "Bat Dragon", variant = "regular" })
		TestRunner.near(value, 5.53)
	end)
end)

return true
