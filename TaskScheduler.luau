local TaskScheduler = {}
TaskScheduler.__index = TaskScheduler

function TaskScheduler.new(options)
	options = options or {}
	return setmetatable({
		now = options.now or os.clock,
		errorHandler = options.errorHandler,
		tasks = {},
		order = {},
		nextId = 1,
		runCount = 0,
		errorCount = 0,
	}, TaskScheduler)
end

local function recompute(self)
	self.order = {}
	for id in pairs(self.tasks) do
		self.order[#self.order + 1] = id
	end
	table.sort(self.order)
end

function TaskScheduler:Every(id, interval, handler, options)
	assert(type(handler) == "function", "handler must be a function")
	local seconds = tonumber(interval)
	assert(seconds and seconds > 0, "interval must be positive")
	local key = id or ("task-" .. tostring(self.nextId))
	if self.tasks[key] then
		return nil, "duplicate task id"
	end
	self.nextId = self.nextId + 1
	self.tasks[key] = {
		id = key,
		interval = seconds,
		handler = handler,
		nextAt = self.now() + (options and tonumber(options.delay) or seconds),
		repeats = true,
		runs = 0,
	}
	recompute(self)
	return key
end

function TaskScheduler:After(id, delay, handler)
	assert(type(handler) == "function", "handler must be a function")
	local seconds = math.max(0, tonumber(delay) or 0)
	local key = id or ("task-" .. tostring(self.nextId))
	if self.tasks[key] then
		return nil, "duplicate task id"
	end
	self.nextId = self.nextId + 1
	self.tasks[key] = {
		id = key,
		interval = seconds,
		handler = handler,
		nextAt = self.now() + seconds,
		repeats = false,
		runs = 0,
	}
	recompute(self)
	return key
end

function TaskScheduler:Cancel(id)
	if not self.tasks[id] then
		return false
	end
	self.tasks[id] = nil
	recompute(self)
	return true
end

function TaskScheduler:Has(id)
	return self.tasks[id] ~= nil
end

function TaskScheduler:Tick(now)
	local current = now or self.now()
	local executed = 0
	local failed = 0
	local snapshot = {}
	for index = 1, #self.order do
		snapshot[index] = self.order[index]
	end
	for index = 1, #snapshot do
		local id = snapshot[index]
		local task = self.tasks[id]
		if task and task.nextAt <= current then
			if task.repeats then
				task.nextAt = current + task.interval
			else
				self.tasks[id] = nil
				recompute(self)
			end
			task.runs = task.runs + 1
			executed = executed + 1
			local ok, err = pcall(task.handler, current)
			if not ok then
				failed = failed + 1
				self.errorCount = self.errorCount + 1
				if self.errorHandler then
					self.errorHandler:Report(err, "scheduler:" .. tostring(id))
				end
			end
		end
	end
	self.runCount = self.runCount + executed
	return executed, failed
end

function TaskScheduler:Clear()
	self.tasks = {}
	self.order = {}
end

function TaskScheduler:Stats()
	return {
		active = #self.order,
		runs = self.runCount,
		errors = self.errorCount,
	}
end

return TaskScheduler
