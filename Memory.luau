local Util = require("../Core/Util")
local Personality = require("./Personality")

local Memory = {}
Memory.__index = Memory

Memory.SchemaVersion = 1

function Memory.new(options)
	options = options or {}
	return setmetatable({
		storage = options.storage,
		jsonEncode = options.jsonEncode,
		jsonDecode = options.jsonDecode,
		path = options.path or "KiriaAutoTrader/kiria_memory.json",
		clock = options.clock or os.time,
		data = {
			sessions = 0,
			firstSeen = options.clock and options.clock() or os.time(),
			trades = 0,
			totalGain = 0,
			bestGain = 0,
			xp = 0,
			neons = 0,
			megas = 0,
			accepted = 0,
			declined = 0,
			lastRate = nil,
			currentRate = nil,
		},
	}, Memory)
end

function Memory:Load()
	if not self.storage or not self.jsonDecode then
		return false, "storage unavailable"
	end
	local ok, content = self.storage.read(self.path)
	if not ok or not content then
		return false, "no saved memory"
	end
	local decodedOk, decoded = pcall(self.jsonDecode, content)
	if not decodedOk or type(decoded) ~= "table" then
		return false, "memory is not valid JSON"
	end
	if decoded.schemaVersion ~= Memory.SchemaVersion or type(decoded.data) ~= "table" then
		return false, "memory schema mismatch"
	end
	for key, value in pairs(decoded.data) do
		self.data[key] = value
	end
	return true
end

function Memory:Save()
	if not self.storage or not self.jsonEncode then
		return false, "storage unavailable"
	end
	local ok, encoded = pcall(self.jsonEncode, {
		schemaVersion = Memory.SchemaVersion,
		savedAt = self.clock(),
		data = self.data,
	})
	if not ok or not encoded then
		return false, "memory encode failed"
	end
	local writeOk, err = self.storage.write(self.path, encoded)
	if not writeOk then
		return false, tostring(err)
	end
	return true
end

function Memory:StartSession()
	self.data.sessions = (self.data.sessions or 0) + 1
	if self.data.currentRate then
		self.data.lastRate = self.data.currentRate
	end
	self.data.currentRate = nil
	self:AddXp(2)
	return {
		sessions = self.data.sessions,
		days = math.max(1, math.floor((self.clock() - (self.data.firstSeen or self.clock())) / 86400) + 1),
	}
end

function Memory:AddXp(amount)
	self.data.xp = (self.data.xp or 0) + math.max(0, tonumber(amount) or 0)
	return self.data.xp
end

function Memory:RecordTrade(profit, percent)
	profit = tonumber(profit) or 0
	self.data.trades = (self.data.trades or 0) + 1
	self.data.totalGain = (self.data.totalGain or 0) + profit
	local record = profit > (self.data.bestGain or 0)
	if record then
		self.data.bestGain = profit
	end
	local xpGain = 10 + math.min(40, math.max(0, tonumber(percent) or 0) / 2)
	self:AddXp(xpGain)
	return {
		trades = self.data.trades,
		totalGain = self.data.totalGain,
		bestGain = self.data.bestGain,
		record = record,
		xp = self.data.xp,
	}
end

function Memory:RecordNeon()
	self.data.neons = (self.data.neons or 0) + 1
	self:AddXp(15)
end

function Memory:RecordMega()
	self.data.megas = (self.data.megas or 0) + 1
	self:AddXp(40)
end

function Memory:RecordOfferRate(rate)
	self.data.currentRate = rate
end

function Memory:Rank()
	return Personality:Rank(self.data.xp or 0)
end

function Memory:Stats()
	return {
		sessions = self.data.sessions or 0,
		firstSeen = self.data.firstSeen,
		days = math.max(1, math.floor((self.clock() - (self.data.firstSeen or self.clock())) / 86400) + 1),
		trades = self.data.trades or 0,
		totalGain = self.data.totalGain or 0,
		bestGain = self.data.bestGain or 0,
		xp = self.data.xp or 0,
		rank = self:Rank(),
		neons = self.data.neons or 0,
		megas = self.data.megas or 0,
		accepted = self.data.accepted or 0,
		declined = self.data.declined or 0,
		lastRate = self.data.lastRate,
		currentRate = self.data.currentRate,
	}
end

function Memory:Snapshot()
	return Util.deepCopy(self.data)
end

function Memory:Clear()
	self.data = {
		sessions = 0,
		firstSeen = self.clock(),
		trades = 0,
		totalGain = 0,
		bestGain = 0,
		xp = 0,
		neons = 0,
		megas = 0,
		accepted = 0,
		declined = 0,
		lastRate = nil,
		currentRate = nil,
	}
	if self.storage then
		pcall(self.storage.remove, self.path)
	end
end

return Memory
