local OfferTimer = {}
OfferTimer.__index = OfferTimer

function OfferTimer.new(options)
	options = options or {}
	return setmetatable({
		clock = options.clock or os.time,
		timers = {},
		fired = 0,
		stopped = 0,
	}, OfferTimer)
end

function OfferTimer:Start(id, timeoutSeconds, onExpire, metadata)
	assert(type(id) == "string", "timer id must be a string")
	local now = self.clock()
	local seconds = math.max(0, tonumber(timeoutSeconds) or 0)
	if self.timers[id] then
		return nil, "timer already active"
	end
	self.timers[id] = {
		id = id,
		startedAt = now,
		expiresAt = now + seconds,
		timeout = seconds,
		onExpire = onExpire,
		metadata = metadata,
	}
	return self.timers[id]
end

function OfferTimer:Tick(now)
	local current = now or self.clock()
	local expired = {}
	for id, timer in pairs(self.timers) do
		if current >= timer.expiresAt then
			self.timers[id] = nil
			self.fired = self.fired + 1
			expired[#expired + 1] = timer
			if type(timer.onExpire) == "function" then
				pcall(timer.onExpire, timer, current)
			end
		end
	end
	table.sort(expired, function(a, b)
		return a.expiresAt < b.expiresAt
	end)
	return expired
end

function OfferTimer:Stop(id)
	local timer = self.timers[id]
	if not timer then
		return false
	end
	self.timers[id] = nil
	self.stopped = self.stopped + 1
	return true
end

function OfferTimer:Remaining(id, now)
	local timer = self.timers[id]
	if not timer then
		return nil
	end
	return math.max(0, timer.expiresAt - (now or self.clock()))
end

function OfferTimer:IsActive(id)
	return self.timers[id] ~= nil
end

function OfferTimer:Active()
	local list = {}
	for _, timer in pairs(self.timers) do
		list[#list + 1] = timer
	end
	table.sort(list, function(a, b)
		return a.expiresAt < b.expiresAt
	end)
	return list
end

function OfferTimer:Stats()
	return {
		active = (function()
			local count = 0
			for _ in pairs(self.timers) do
				count = count + 1
			end
			return count
		end)(),
		fired = self.fired,
		stopped = self.stopped,
	}
end

function OfferTimer:Clear()
	self.timers = {}
end

return OfferTimer
