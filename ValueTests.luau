local TestRunner = require("./TestRunner")
local Json = require("./Support/Json")
local Mock = require("./Support/Mock")
local ValueParser = require("../Values/ValueParser")
local ValueValidator = require("../Values/ValueValidator")
local ValueCache = require("../Values/ValueCache")
local ValueEngine = require("../Values/ValueEngine")
local AMVGGProvider = require("../Values/AMVGGProvider")
local ConfigManager = require("../Core/ConfigManager")

local describe = TestRunner.describe
local it = TestRunner.it

describe("ValueParser", function()
	it("decodes RSC flight payload and normalizes pet records", function()
		local parser = ValueParser.new({ jsonDecode = Json.decode, minPetCount = 2 })
		local dataset, err = parser:ParsePayload(Mock.Payload(), { fetchedAt = 1000 })
		TestRunner.truthy(dataset, err)
		TestRunner.eq(dataset.count, 3)
		TestRunner.eq(dataset.mode, "flight")
		local bat = dataset.pets[1]
		TestRunner.eq(bat.name, "Bat Dragon")
		TestRunner.near(bat.values.regular, 5.53)
		TestRunner.near(bat.values.neon, 12.775)
		TestRunner.near(bat.values.mega, 36.4)
		TestRunner.near(bat.values.base, 5.58)
		TestRunner.near(bat.values.megaFly, 36.7)
		TestRunner.eq(bat.updatedAt, "2026-11-16T16:10:15.223Z")
	end)

	it("extracts flight payload from real-style next_f script tags", function()
		local parser = ValueParser.new({ jsonDecode = Json.decode, minPetCount = 2 })
		local dataset, err = parser:ParseHtml(Mock.Html(), { fetchedAt = 2000 })
		TestRunner.truthy(dataset, err)
		TestRunner.eq(dataset.count, 3)
		TestRunner.eq(dataset.mode, "flight")
		TestRunner.eq(dataset.url, "https://amvgg.com/values/pets")
	end)

	it("falls back to server-rendered pet cards", function()
		local parser = ValueParser.new({ jsonDecode = Json.decode, minPetCount = 2 })
		local dataset, err = parser:ParseHtml(Mock.CardsHtml())
		TestRunner.truthy(dataset, err)
		TestRunner.eq(dataset.count, 3)
		TestRunner.eq(dataset.mode, "cards")
		TestRunner.near(dataset.pets[1].values.regular, 5.53)
	end)

	it("rejects a payload below the minimum pet count", function()
		local parser = ValueParser.new({ jsonDecode = Json.decode, minPetCount = 10 })
		local dataset, err = parser:ParsePayload(Mock.Payload())
		TestRunner.falsy(dataset)
		TestRunner.contains(err, "too few")
	end)
end)

describe("ValueValidator", function()
	it("accepts a healthy dataset", function()
		local validator = ValueValidator.new({ minPetCount = 2 })
		local report = validator:ValidatePets(Mock.Dataset().pets)
		TestRunner.truthy(report.ok)
		TestRunner.eq(report.invalid, 0)
		TestRunner.eq(report.duplicates, 0)
	end)

	it("reports invalid and duplicate values without crashing", function()
		local validator = ValueValidator.new({ minPetCount = 2 })
		local broken = {
			{ name = "Bat Dragon", key = "batdragon", values = { regular = 0 } },
			{ name = "Bat Dragon", key = "batdragon", values = { regular = 3 } },
		}
		local report = validator:ValidatePets(broken, { minPetCount = 2 })
		TestRunner.truthy(report.invalid >= 1)
		TestRunner.eq(report.duplicates, 1)
		TestRunner.falsy(report.ok)
	end)
end)

describe("ValueEngine", function()
	local function engine()
		local e = ValueEngine.new()
		e:SetDataset(Mock.Dataset())
		return e
	end

	it("maps variants to the AMVGG attribute fields", function()
		local e = engine()
		local value = e:ValueOfItem({ name = "Bat Dragon", variant = "regular", fly = true, ride = true })
		TestRunner.near(value, 5.53)
		value = e:ValueOfItem({ name = "Bat Dragon", variant = "regular" })
		TestRunner.near(value, 5.53)
		value = e:ValueOfItem({ name = "Bat Dragon", variant = "neon", fly = true, ride = true })
		TestRunner.near(value, 12.775)
		value = e:ValueOfItem({ name = "Bat Dragon", variant = "mega", fly = true })
		TestRunner.near(value, 36.7)
	end)

	it("computes difference and percent exactly as specified", function()
		local e = engine()
		local summary = e:Compare(
			{ Mock.Item("Owl") },
			{ Mock.Item("Giraffe") }
		)
		TestRunner.near(summary.yourValue, 1.355)
		TestRunner.near(summary.theirValue, 2.59)
		TestRunner.near(summary.difference, 1.235)
		TestRunner.near(summary.percent, (1.235 / 1.355) * 100, 0.01)
		TestRunner.eq(summary.classification, "EXCELLENT")
		TestRunner.eq(summary.statusLabel, "GOOD DEAL")
	end)

	it("marks missing pets as INCOMPLETE instead of inventing values", function()
		local e = engine()
		local summary = e:Compare({ Mock.Item("Owl") }, { Mock.Item("Unknown Pet") })
		TestRunner.eq(summary.confidence, "INCOMPLETE")
		TestRunner.eq(summary.statusLabel, "INCOMPLETE DATA")
		TestRunner.eq(#summary.missing, 1)
	end)
end)

describe("ValueCache", function()
	it("persists and restores the last valid dataset with staleness tracking", function()
		local clock = Mock.Clock(5000)
		local storage = Mock.Storage()
		local cache = ValueCache.new({
			storage = storage,
			jsonEncode = Json.encode,
			jsonDecode = Json.decode,
			clock = clock.now,
		})
		local dataset = Mock.Dataset()
		dataset.fetchedAt = clock.now()
		local saved = cache:Save(dataset)
		TestRunner.truthy(saved)
		local restored = ValueCache.new({
			storage = storage,
			jsonEncode = Json.encode,
			jsonDecode = Json.decode,
			clock = clock.now,
		})
		local dataset = restored:Load()
		TestRunner.truthy(dataset)
		TestRunner.eq(dataset.count, #Mock.Dataset().pets)
		TestRunner.truthy(dataset.fromCache)
		TestRunner.falsy(restored:IsStale(100))
		clock.advance(101)
		TestRunner.truthy(restored:IsStale(100))
	end)

	it("refuses corrupt cache content", function()
		local storage = Mock.Storage()
		storage.write("KiriaAutoTrader/amvgg_cache.json", "{not json")
		local cache = ValueCache.new({
			storage = storage,
			jsonEncode = Json.encode,
			jsonDecode = Json.decode,
		})
		local dataset, err = cache:Load()
		TestRunner.falsy(dataset)
		TestRunner.truthy(err)
	end)
end)

describe("AMVGGProvider", function()
	local function makeProvider(http, options)
		options = options or {}
		local clock = options.clock or Mock.Clock(10000)
		local storage = Mock.Storage()
		local cache = ValueCache.new({
			storage = storage,
			jsonEncode = Json.encode,
			jsonDecode = Json.decode,
			clock = clock.now,
		})
		local provider = AMVGGProvider.new({
			http = http,
			cache = cache,
			parser = ValueParser.new({ jsonDecode = Json.decode, minPetCount = 2 }),
			validator = ValueValidator.new({ minPetCount = 2 }),
			now = clock.now,
			wait = options.wait or function() end,
			minRefreshInterval = 30,
			maxRetries = options.maxRetries or 3,
		})
		return provider, clock, storage, cache
	end

	it("fetches, validates and caches AMVGG data", function()
		local provider, clock, storage = makeProvider(Mock.HttpResponse(Mock.Html()))
		local result = provider:Refresh(true)
		TestRunner.truthy(result.ok)
		TestRunner.eq(result.dataset.count, 3)
		TestRunner.eq(provider:Status(), "ok")
		TestRunner.truthy(storage.exists("KiriaAutoTrader/amvgg_cache.json"))
		local limited = provider:Refresh(false)
		TestRunner.falsy(limited.ok)
		TestRunner.truthy(limited.rateLimited)
		clock.advance(31)
		local again = provider:Refresh(false)
		TestRunner.truthy(again.ok)
	end)

	it("keeps the last valid dataset when AMVGG is unavailable", function()
		local waits = 0
		local provider = makeProvider(Mock.HttpSequence({
			Mock.Html(),
		}), { maxRetries = 1 })
		provider:Refresh(true)
		TestRunner.eq(provider:Status(), "ok")
		provider.http = Mock.HttpError("blocked")
		provider.wait = function()
			waits = waits + 1
		end
		provider.maxRetries = 2
		local result = provider:Refresh(true)
		TestRunner.falsy(result.ok)
		TestRunner.eq(result.usedCache, true)
		TestRunner.eq(provider:Status(), "degraded")
		TestRunner.eq(provider:GetSnapshot().petCount, 3)
		TestRunner.truthy(result.error)
	end)

	it("restores cached data on init without inventing values", function()
		local provider, _, _, cache = makeProvider(Mock.HttpError("offline"))
		cache:Save(Mock.Dataset())
		local init = provider:Init({})
		TestRunner.truthy(init.ok)
		TestRunner.eq(provider:GetSnapshot().petCount, 8)
		TestRunner.eq(provider:Status(), "ok")
		local result = provider:Refresh(true)
		TestRunner.falsy(result.ok)
		TestRunner.eq(provider:Status(), "degraded")
	end)
end)

describe("ConfigManager", function()
	it("merges defaults and rejects malformed overrides", function()
		local config, warnings = ConfigManager.Build(ConfigManager.Defaults, {
			Thresholds = { Good = "high" },
			Unknown = true,
			Offers = { MaxItems = 8 },
		})
		TestRunner.eq(config.Offers.MaxItems, 8)
		TestRunner.eq(config.Thresholds.Good, ConfigManager.Defaults.Thresholds.Good)
		TestRunner.truthy(#warnings >= 2)
	end)
end)

return true
