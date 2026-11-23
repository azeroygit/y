local Util = require("../Core/Util")

local Logger = {}
Logger.__index = Logger

Logger.Levels = {
	DEBUG = 1,
	INFO = 2,
	SUCCESS = 3,
	WARN = 4,
	ERROR = 5,
	OFF = 99,
}

local ORDER = { "DEBUG", "INFO", "SUCCESS", "WARN", "ERROR" }

function Logger.new(options)
	options = options or {}
	local level = string.upper(tostring(options.level or "INFO"))
	if Logger.Levels[level] == nil then
		level = "INFO"
	end
	return setmetatable({
		level = level,
		sink = options.sink,
		bufferSize = math.max(20, tonumber(options.bufferSize) or 200),
		entries = {},
		counts = { DEBUG = 0, INFO = 0, SUCCESS = 0, WARN = 0, ERROR = 0 },
		closed = false,
	}, Logger)
end

function Logger:SetLevel(level)
	level = string.upper(tostring(level or ""))
	if Logger.Levels[level] == nil then
		return false, "unknown log level"
	end
	self.level = level
	return true
end

function Logger:ShouldLog(level)
	return not self.closed and Logger.Levels[level] >= Logger.Levels[self.level]
end

function Logger:_write(level, message)
	if not self:ShouldLog(level) then
		return nil
	end
	local entry = {
		level = level,
		message = tostring(message),
		time = os.time(),
		clock = os.clock(),
	}
	self.entries[#self.entries + 1] = entry
	self.counts[level] = (self.counts[level] or 0) + 1
	while #self.entries > self.bufferSize do
		table.remove(self.entries, 1)
	end
	if type(self.sink) == "function" then
		pcall(self.sink, entry)
	end
	return entry
end

function Logger:_format(level, fmt, ...)
	local args = { ... }
	local message
	if select("#", ...) > 0 then
		local ok, formatted = pcall(string.format, tostring(fmt), table.unpack(args))
		message = ok and formatted or (tostring(fmt) .. " " .. Util.join(args, " "))
	else
		message = tostring(fmt)
	end
	return self:_write(level, message)
end

function Logger:Debug(fmt, ...)
	return self:_format("DEBUG", fmt, ...)
end

function Logger:Info(fmt, ...)
	return self:_format("INFO", fmt, ...)
end

function Logger:Success(fmt, ...)
	return self:_format("SUCCESS", fmt, ...)
end

function Logger:Warn(fmt, ...)
	return self:_format("WARN", fmt, ...)
end

function Logger:Error(fmt, ...)
	return self:_format("ERROR", fmt, ...)
end

function Logger:Recent(limit)
	local count = math.min(limit or 20, #self.entries)
	local result = {}
	for index = #self.entries - count + 1, #self.entries do
		result[#result + 1] = self.entries[index]
	end
	return result
end

function Logger:Summary()
	local parts = {}
	for _, level in ipairs(ORDER) do
		parts[#parts + 1] = string.format("%s=%d", level, self.counts[level] or 0)
	end
	return table.concat(parts, " ")
end

function Logger:Close()
	self.closed = true
end

return Logger
