local TestRunner = require("./TestRunner")
local Json = require("./Support/Json")
local Mock = require("./Support/Mock")
local App = require("../App")

local describe = TestRunner.describe
local it = TestRunner.it

local function fakeRuntime(html)
	local storage = Mock.Storage()
	local runtime = {
		storage = storage,
		hasFileApi = false,
		requestFunction = true,
		httpService = true,
		memoryFiles = {},
	}
	function runtime:JsonEncode(value)
		return Json.encode(value)
	end
	function runtime:JsonDecode(text)
		return Json.decode(text)
	end
	function runtime:HttpGet()
		return html
	end
	function runtime:Wait()
	end
	function runtime:Spawn(handler)
		handler()
		return true
	end
	return runtime, storage
end

local function buildApp()
	local runtime, storage = fakeRuntime(Mock.Html())
	storage.write("KiriaAutoTrader/settings.json", Json.encode({
		Values = {
			MinPetCount = 2,
			MinRefreshIntervalSeconds = 0,
		},
	}))
	local app = App.new({
		runtime = runtime,
		jsonEncode = Json.encode,
		jsonDecode = Json.decode,
	})
	return app, storage
end

describe("App wiring", function()
	it("refreshes values from AMVGG and imports a valued inventory", function()
		local app = buildApp()
		app:RefreshValues(true)
		TestRunner.eq(app:GetState():Get("valuesStatus"), "ok")
		TestRunner.eq(app:GetState():Get("petCount"), 3)
		local result = app:ImportInventory("2x Owl\nGiraffe")
		TestRunner.eq(result.summary.count, 2)
		TestRunner.near(result.summary.total, 1.355 * 2 + 2.59)
		TestRunner.eq(app:GetState():Get("inventorySummary").topPet, "Giraffe")
	end)

	it("requires explicit confirmation before accepting an offer and records it once", function()
		local app = buildApp()
		app:RefreshValues(true)
		local analysis = app:EvaluateOffer("Bat Dragon", "Giraffe")
		TestRunner.truthy(analysis)
		TestRunner.eq(analysis.evaluation.confidence, "COMPLETE")
		local entry = app:AddOfferToQueue(analysis)
		TestRunner.truthy(entry)
		local before = app:GetAnalytics()
		local refused, reason = app:AcceptOffer(entry.id, { confirmed = false })
		TestRunner.eq(refused, nil)
		TestRunner.truthy(reason)
		TestRunner.eq(#(app:GetState():Get("offers")), 1)
		local accepted, trade = app:AcceptOffer(entry.id, { confirmed = true, recordTrade = true })
		TestRunner.truthy(accepted)
		TestRunner.truthy(trade)
		local analytics = app:GetAnalytics()
		TestRunner.eq(analytics.trades.realized, before.trades.realized + 1)
		local again = app:AcceptOffer(entry.id, { confirmed = true })
		TestRunner.eq(again, nil)
	end)

	it("keeps listing publication behind explicit confirmation", function()
		local app = buildApp()
		app:RefreshValues(true)
		local draft = app:CreateListingDraft("Owl", "Giraffe")
		TestRunner.truthy(draft)
		local refused, reason = app:PublishListing(draft.id, {})
		TestRunner.eq(refused, nil)
		TestRunner.truthy(reason)
		local listing = app:PublishListing(draft.id, { confirmed = true })
		TestRunner.truthy(listing)
		TestRunner.eq(app:GetListing(listing.id).status, "ACTIVE")
		local cancelled = app:CancelListing(listing.id, { confirmed = true })
		TestRunner.truthy(cancelled)
		TestRunner.eq(app:GetListing(listing.id).status, "CANCELLED")
	end)

	it("records confirmed manual trades and persists history through storage", function()
		local app, storage = buildApp()
		app:RefreshValues(true)
		local refused, reason = app:RecordManualTrade("Owl", "Bat Dragon", {})
		TestRunner.eq(refused, nil)
		TestRunner.truthy(reason)
		local trade = app:RecordManualTrade("Owl", "Bat Dragon", { confirmed = true })
		TestRunner.truthy(trade)
		TestRunner.near(trade.profit, 5.53 - 1.355)
		TestRunner.truthy(storage.exists("KiriaAutoTrader/history.json"))
		local analytics = app:GetAnalytics()
		TestRunner.eq(analytics.trades.realized, 1)
		TestRunner.near(analytics.profit.realized, 5.53 - 1.355)
	end)

	it("applies settings changes and reports config warnings without crashing", function()
		local app = buildApp()
		local ok, err = app:SetConfig("Thresholds.Good", 15)
		TestRunner.truthy(ok)
		TestRunner.eq(err, nil)
		TestRunner.eq(app.thresholds.Good, 15)
		TestRunner.eq(app:GetState():Get("config").Thresholds.Good, 15)
		local bad = app:SetConfig("NotAThing", 1)
		TestRunner.eq(bad, false)
	end)
end)
