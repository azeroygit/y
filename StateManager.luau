local Util = require("../Core/Util")

local StateManager = {}
StateManager.__index = StateManager

function StateManager.new(initial)
	local self = setmetatable({
		_state = Util.deepCopy(initial or {}),
		_keyListeners = {},
		_globalListeners = {},
		_version = 0,
	}, StateManager)
	return self
end

function StateManager:Get(key)
	if key == nil then
		return self._state
	end
	return self._state[key]
end

function StateManager:Snapshot()
	return Util.deepCopy(self._state)
end

function StateManager:Set(key, value)
	assert(type(key) == "string", "state key must be a string")
	local previous = self._state[key]
	self._state[key] = value
	self._version = self._version + 1
	local bucket = self._keyListeners[key]
	if bucket then
		local snapshot = {}
		for index = 1, #bucket do
			snapshot[index] = bucket[index]
		end
		for index = 1, #snapshot do
			local listener = snapshot[index]
			if listener.connected then
				pcall(listener.handler, value, previous, key)
			end
		end
	end
	local globals = {}
	for index = 1, #self._globalListeners do
		globals[index] = self._globalListeners[index]
	end
	for index = 1, #globals do
		local listener = globals[index]
		if listener.connected then
			pcall(listener.handler, key, value, previous)
		end
	end
	return value
end

function StateManager:Update(partial)
	assert(type(partial) == "table", "partial state must be a table")
	for key, value in pairs(partial) do
		self:Set(key, value)
	end
	return self._state
end

function StateManager:Toggle(key)
	return self:Set(key, not self._state[key])
end

function StateManager:Subscribe(key, handler)
	assert(type(handler) == "function", "handler must be a function")
	local bucket = self._keyListeners[key]
	if not bucket then
		bucket = {}
		self._keyListeners[key] = bucket
	end
	local listener = { handler = handler, connected = true }
	bucket[#bucket + 1] = listener
	local state = self
	local connection = {}
	function connection.Disconnect()
		if not listener.connected then
			return
		end
		listener.connected = false
		connection.Connected = false
		for index, entry in ipairs(bucket) do
			if entry == listener then
				table.remove(bucket, index)
				break
			end
		end
		if #bucket == 0 then
			state._keyListeners[key] = nil
		end
	end
	connection.Connected = true
	return connection
end

function StateManager:SubscribeAll(handler)
	assert(type(handler) == "function", "handler must be a function")
	local listener = { handler = handler, connected = true }
	self._globalListeners[#self._globalListeners + 1] = listener
	local state = self
	local connection = {}
	function connection.Disconnect()
		if not listener.connected then
			return
		end
		listener.connected = false
		connection.Connected = false
		for index, entry in ipairs(state._globalListeners) do
			if entry == listener then
				table.remove(state._globalListeners, index)
				break
			end
		end
	end
	connection.Connected = true
	return connection
end

function StateManager:Reset(initial)
	self._state = Util.deepCopy(initial or {})
	self._version = self._version + 1
	for index = 1, #self._globalListeners do
		local listener = self._globalListeners[index]
		if listener.connected then
			pcall(listener.handler, "*", self._state, nil)
		end
	end
end

function StateManager:Version()
	return self._version
end

return StateManager
