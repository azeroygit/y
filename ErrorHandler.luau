local ErrorHandler = {}
ErrorHandler.__index = ErrorHandler

function ErrorHandler.new(options)
	options = options or {}
	return setmetatable({
		logger = options.logger,
		onError = options.onError,
		lastError = nil,
		errorCount = 0,
	}, ErrorHandler)
end

function ErrorHandler:Guard(handler, context)
	local ok, result = pcall(handler)
	if not ok then
		self:Report(result, context)
		return false, tostring(result)
	end
	return true, result
end

function ErrorHandler:Report(err, context)
	local message = tostring(err)
	if context then
		message = tostring(context) .. ": " .. message
	end
	self.lastError = message
	self.errorCount = self.errorCount + 1
	if self.logger then
		self.logger:Error("%s", message)
	end
	if type(self.onError) == "function" then
		pcall(self.onError, message, context)
	end
	return message
end

function ErrorHandler:BackoffDelay(attempt, base, maximum)
	local baseDelay = tonumber(base) or 1
	local maxDelay = tonumber(maximum) or 30
	local exponent = math.max(0, math.floor(tonumber(attempt) or 0) - 1)
	local delay = baseDelay * (2 ^ exponent)
	if delay > maxDelay then
		delay = maxDelay
	end
	return delay
end

function ErrorHandler:Retry(handler, options)
	options = options or {}
	local attempts = math.max(1, tonumber(options.attempts) or 3)
	local base = tonumber(options.baseDelay) or 1
	local maximum = tonumber(options.maxDelay) or 30
	local wait = options.wait or function(seconds)
		return seconds
	end
	local context = options.context or "retry"
	local errors = {}
	for attempt = 1, attempts do
		local ok, result = pcall(handler, attempt)
		if ok then
			if attempt > 1 and self.logger then
				self.logger:Info("%s succeeded on attempt %d", context, attempt)
			end
			return true, result, attempt, errors
		end
		errors[#errors + 1] = tostring(result)
		if attempt < attempts then
			local delay = self:BackoffDelay(attempt, base, maximum)
			local waitOk = pcall(wait, delay)
			if not waitOk then
				self:Report(result, context .. " (wait failed)")
				return false, tostring(result), attempt, errors
			end
		end
	end
	local finalError = errors[#errors] or "unknown error"
	self:Report(finalError, context)
	return false, finalError, attempts, errors
end

function ErrorHandler:Stats()
	return {
		errorCount = self.errorCount,
		lastError = self.lastError,
	}
end

return ErrorHandler
