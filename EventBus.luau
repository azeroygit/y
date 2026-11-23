local EventBus = {}
EventBus.__index = EventBus

function EventBus.new(name)
	return setmetatable({
		name = name or "EventBus",
		_listeners = {},
		_lastError = nil,
		listenerCount = 0,
	}, EventBus)
end

function EventBus:Connect(eventName, handler)
	assert(type(eventName) == "string", "eventName must be a string")
	assert(type(handler) == "function", "handler must be a function")
	local bucket = self._listeners[eventName]
	if not bucket then
		bucket = {}
		self._listeners[eventName] = bucket
	end
	local listener = { handler = handler, connected = true }
	bucket[#bucket + 1] = listener
	self.listenerCount = self.listenerCount + 1
	local bus = self
	local connection = {}
	function connection.Disconnect()
		if not listener.connected then
			return
		end
		listener.connected = false
		connection.Connected = false
		bus.listenerCount = math.max(0, bus.listenerCount - 1)
		for index, entry in ipairs(bucket) do
			if entry == listener then
				table.remove(bucket, index)
				break
			end
		end
	end
	connection.Connected = true
	return connection
end

function EventBus:Once(eventName, handler)
	local connection
	connection = self:Connect(eventName, function(...)
		connection:Disconnect()
		handler(...)
	end)
	return connection
end

function EventBus:Emit(eventName, ...)
	local bucket = self._listeners[eventName]
	if not bucket then
		return 0
	end
	local snapshot = {}
	for index = 1, #bucket do
		snapshot[index] = bucket[index]
	end
	local called = 0
	for index = 1, #snapshot do
		local listener = snapshot[index]
		if listener.connected then
			local ok, err = pcall(listener.handler, ...)
			called = called + 1
			if not ok then
				self._lastError = tostring(err)
			end
		end
	end
	return called
end

function EventBus:Error()
	return self._lastError
end

function EventBus:Clear(eventName)
	if eventName then
		local bucket = self._listeners[eventName]
		if bucket then
			for index = 1, #bucket do
				bucket[index].connected = false
				self.listenerCount = math.max(0, self.listenerCount - 1)
			end
			self._listeners[eventName] = nil
		end
		return
	end
	for _, bucket in pairs(self._listeners) do
		for index = 1, #bucket do
			bucket[index].connected = false
		end
	end
	self._listeners = {}
	self.listenerCount = 0
end

function EventBus:Destroy()
	self:Clear()
end

return EventBus
