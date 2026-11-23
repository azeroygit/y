local TestRunner = require("./TestRunner")
local Mock = require("./Support/Mock")
local TaskScheduler = require("../Core/TaskScheduler")
local OfferTimer = require("../Trading/OfferTimer")
local ErrorHandler = require("../Core/ErrorHandler")
local EventBus = require("../Core/EventBus")
local StateManager = require("../Core/StateManager")
local Logger = require("../Core/Logger")

local describe = TestRunner.describe
local it = TestRunner.it

describe("TaskScheduler", function()
	it("runs repeating and one-shot tasks with injected time", function()
		local clock = Mock.Clock(10)
		local scheduler = TaskScheduler.new({ now = clock.now })
		local ticks = 0
		local once = 0
		scheduler:Every("scan", 5, function()
			ticks = ticks + 1
		end)
		scheduler:After("once", 3, function()
			once = once + 1
		end)
		TestRunner.eq(scheduler:Tick(12), 0)
		TestRunner.eq(scheduler:Tick(16), 2)
		TestRunner.eq(ticks, 1)
		TestRunner.eq(once, 1)
		TestRunner.eq(scheduler:Tick(21), 1)
		TestRunner.eq(ticks, 2)
		TestRunner.falsy(scheduler:Has("once"))
	end)

	it("rejects duplicate ids and supports cancellation", function()
		local clock = Mock.Clock(0)
		local scheduler = TaskScheduler.new({ now = clock.now })
		TestRunner.truthy(scheduler:Every("a", 5, function() end))
		local duplicate, err = scheduler:Every("a", 5, function() end)
		TestRunner.falsy(duplicate)
		TestRunner.contains(err, "duplicate")
		TestRunner.truthy(scheduler:Cancel("a"))
		TestRunner.falsy(scheduler:Has("a"))
	end)

	it("captures handler errors and reports them", function()
		local clock = Mock.Clock(0)
		local reported = 0
		local handler = ErrorHandler.new({ onError = function()
			reported = reported + 1
		end })
		local scheduler = TaskScheduler.new({ now = clock.now, errorHandler = handler })
		scheduler:Every("bad", 1, function()
			error("boom")
		end)
		local executed, failed = scheduler:Tick(1)
		TestRunner.eq(executed, 1)
		TestRunner.eq(failed, 1)
		TestRunner.eq(reported, 1)
	end)
end)

describe("OfferTimer", function()
	it("fires timers once at expiry and stops them cleanly", function()
		local clock = Mock.Clock(100)
		local timer = OfferTimer.new({ clock = clock.now })
		local fired = 0
		timer:Start("offer-1", 30, function()
			fired = fired + 1
		end)
		TestRunner.eq(timer:Remaining("offer-1", 110), 20)
		local expired = timer:Tick(130)
		TestRunner.eq(#expired, 1)
		TestRunner.eq(fired, 1)
		TestRunner.eq(#timer:Tick(140), 0)
		TestRunner.falsy(timer:IsActive("offer-1"))
	end)

	it("can stop a timer before expiry", function()
		local clock = Mock.Clock(0)
		local timer = OfferTimer.new({ clock = clock.now })
		timer:Start("a", 10, function() end)
		TestRunner.truthy(timer:Stop("a"))
		TestRunner.eq(#timer:Tick(100), 0)
		TestRunner.eq(timer:Stats().stopped, 1)
	end)

	it("rejects duplicate active ids", function()
		local timer = OfferTimer.new({ clock = Mock.Clock(0).now })
		timer:Start("x", 10, function() end)
		local second, err = timer:Start("x", 10, function() end)
		TestRunner.falsy(second)
		TestRunner.contains(err, "already active")
	end)
end)

describe("ErrorHandler", function()
	it("uses exponential backoff and retries", function()
		local handler = ErrorHandler.new()
		TestRunner.eq(handler:BackoffDelay(1, 1, 30), 1)
		TestRunner.eq(handler:BackoffDelay(3, 1, 30), 4)
		TestRunner.eq(handler:BackoffDelay(10, 1, 30), 30)
		local attempts = 0
		local waits = {}
		local ok, result = handler:Retry(function(attempt)
			attempts = attempt
			if attempt < 3 then
				error("temporary")
			end
			return "done"
		end, {
			attempts = 4,
			wait = function(seconds)
				waits[#waits + 1] = seconds
			end,
		})
		TestRunner.truthy(ok)
		TestRunner.eq(result, "done")
		TestRunner.eq(attempts, 3)
		TestRunner.eq(#waits, 2)
	end)
end)

describe("EventBus", function()
	it("delivers events and isolates listener errors", function()
		local bus = EventBus.new("test")
		local received = {}
		bus:Connect("hello", function(value)
			received[#received + 1] = value
		end)
		bus:Connect("hello", function()
			error("listener failure")
		end)
		bus:Emit("hello", "world")
		TestRunner.eq(received[1], "world")
		TestRunner.truthy(bus:Error())
	end)

	it("supports once and disconnecting", function()
		local bus = EventBus.new()
		local count = 0
		local connection = bus:Connect("x", function()
			count = count + 1
		end)
		bus:Emit("x")
		connection:Disconnect()
		bus:Emit("x")
		TestRunner.eq(count, 1)
		bus:Once("y", function()
			count = count + 10
		end)
		bus:Emit("y")
		bus:Emit("y")
		TestRunner.eq(count, 11)
		TestRunner.eq(bus.listenerCount, 0)
	end)
end)

describe("StateManager", function()
	it("notifies key and global listeners with previous values", function()
		local state = StateManager.new({ page = "Dashboard", count = 0 })
		local keyed = {}
		local globals = {}
		state:Subscribe("count", function(value, previous)
			keyed[#keyed + 1] = { value, previous }
		end)
		state:SubscribeAll(function(key, value)
			globals[#globals + 1] = key
		end)
		state:Set("count", 5)
		state:Update({ page = "Offers", count = 6 })
		TestRunner.eq(keyed[1][1], 5)
		TestRunner.eq(keyed[1][2], 0)
		TestRunner.eq(keyed[2][1], 6)
		TestRunner.eq(#globals, 3)
		TestRunner.eq(state:Get("page"), "Offers")
	end)

	it("returns deep snapshots so callers cannot mutate state", function()
		local state = StateManager.new({ nested = { a = 1 } })
		local snapshot = state:Snapshot()
		snapshot.nested.a = 99
		TestRunner.eq(state:Get("nested").a, 1)
	end)
end)

describe("Logger", function()
	it("filters levels and keeps a bounded buffer", function()
		local entries = {}
		local logger = Logger.new({
			level = "WARN",
			bufferSize = 20,
			sink = function(entry)
				entries[#entries + 1] = entry
			end,
		})
		logger:Info("hidden")
		logger:Warn("shown %d", 1)
		logger:Error("also shown")
		TestRunner.eq(#entries, 2)
		TestRunner.eq(entries[1].level, "WARN")
		TestRunner.eq(entries[2].message, "also shown")
		for index = 1, 30 do
			logger:Warn("entry %d", index)
		end
		TestRunner.eq(#logger.entries, 20)
	end)
end)

return true
