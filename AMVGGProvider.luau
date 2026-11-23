local ValueParser = require("./ValueParser")

local AMVGGProvider = {}
AMVGGProvider.__index = AMVGGProvider

AMVGGProvider.URL = "https://amvgg.com/values/pets"
AMVGGProvider.HUB_URL = "https://amvgg.com/values"
AMVGGProvider.SOURCE = "AMVGG"

function AMVGGProvider.new(options)
	options = options or {}
	return setmetatable({
		url = options.url or AMVGGProvider.URL,
		http = options.http,
		parser = options.parser or ValueParser.new({
			jsonDecode = options.jsonDecode,
			jsonEncode = options.jsonEncode,
			minPetCount = options.minPetCount,
		}),
		validator = options.validator,
		cache = options.cache,
		logger = options.logger,
		errorHandler = options.errorHandler,
		now = options.now or os.time,
		wait = options.wait,
		minRefreshInterval = tonumber(options.minRefreshInterval) or 30,
		maxRetries = tonumber(options.maxRetries) or 3,
		backoffBase = tonumber(options.backoffBase) or 1,
		backoffMax = tonumber(options.backoffMax) or 20,
		status = "idle",
		dataset = nil,
		lastSuccessAt = nil,
		lastAttemptAt = nil,
		lastError = nil,
		lastAttempts = 0,
		requestCount = 0,
		successCount = 0,
		failureCount = 0,
	}, AMVGGProvider)
end

function AMVGGProvider:Init(options)
	options = options or {}
	if self.cache then
		local dataset, err = self.cache:Load()
		if dataset then
			local valid = true
			if self.validator then
				valid = self.validator:IsDatasetValid(dataset, {
					minPetCount = self.parser.minPetCount,
					source = dataset.source,
				})
			end
			if valid then
				self.dataset = dataset
				self.status = "ok"
				self.lastSuccessAt = dataset.fetchedAt
			else
				self.lastError = "cached AMVGG dataset failed validation"
				if self.logger then
					self.logger:Warn("%s", self.lastError)
				end
			end
		elseif err and self.logger then
			self.logger:Info("AMVGG cache: %s", tostring(err))
		end
	end
	if options.refreshIfStale and self.cache and self.cache:IsStale(options.maxAgeSeconds, self.now()) then
		return self:Refresh(false)
	end
	return {
		ok = self.dataset ~= nil,
		fromCache = self.dataset ~= nil,
		status = self.status,
	}
end

function AMVGGProvider:FetchOnce()
	if type(self.http) ~= "function" then
		return nil, "http adapter unavailable (executor request function required)"
	end
	self.requestCount = self.requestCount + 1
	local ok, body, err = pcall(self.http, self.url)
	if not ok then
		return nil, tostring(body)
	end
	if body == nil or body == "" then
		return nil, tostring(err or "empty AMVGG response")
	end
	return body
end

function AMVGGProvider:Refresh(force)
	local now = self.now()
	if not force and self.lastAttemptAt and (now - self.lastAttemptAt) < self.minRefreshInterval then
		return {
			ok = false,
			rateLimited = true,
			status = self.status,
			error = string.format("refresh rate limited (%ds minimum)", self.minRefreshInterval),
		}
	end
	self.lastAttemptAt = now
	local previousStatus = self.status
	self.status = "loading"
	self.lastError = nil
	local attempts = math.max(1, self.maxRetries)
	local body, fetchError
	local wait = self.wait or function(seconds)
		return seconds
	end
	for attempt = 1, attempts do
		self.lastAttempts = attempt
		body, fetchError = self:FetchOnce()
		if body then
			break
		end
		if attempt < attempts then
			local delay = self.errorHandler and self.errorHandler:BackoffDelay(attempt, self.backoffBase, self.backoffMax)
				or (self.backoffBase * (2 ^ (attempt - 1)))
			if self.logger then
				self.logger:Warn("AMVGG fetch attempt %d/%d failed: %s; retrying in %ds", attempt, attempts, tostring(fetchError), delay)
			end
			pcall(wait, delay)
		end
	end
	if not body then
		self.failureCount = self.failureCount + 1
		self.status = self.dataset and "degraded" or "error"
		self.lastError = string.format("AMVGG fetch failed after %d attempt(s): %s", attempts, tostring(fetchError))
		if self.logger then
			self.logger:Error("%s", self.lastError)
		end
		return {
			ok = false,
			status = self.status,
			error = self.lastError,
			dataset = self.dataset,
			usedCache = self.dataset ~= nil,
			previousStatus = previousStatus,
		}
	end
	local dataset, parseError = self.parser:ParseHtml(body, {
		url = self.url,
		fetchedAt = self.now(),
	})
	if not dataset then
		self.failureCount = self.failureCount + 1
		self.status = self.dataset and "degraded" or "error"
		self.lastError = "AMVGG parse failed: " .. tostring(parseError)
		if self.logger then
			self.logger:Error("%s", self.lastError)
		end
		return {
			ok = false,
			status = self.status,
			error = self.lastError,
			dataset = self.dataset,
			usedCache = self.dataset ~= nil,
		}
	end
	if self.validator then
		local report = self.validator:ValidatePets(dataset.pets, {
			minPetCount = self.parser.minPetCount,
			source = dataset.source,
		})
		if not report.ok then
			self.failureCount = self.failureCount + 1
			self.status = self.dataset and "degraded" or "error"
			self.lastError = "AMVGG validation failed: " .. table.concat(report.errors, "; ")
			if self.logger then
				self.logger:Error("%s", self.lastError)
			end
			return {
				ok = false,
				status = self.status,
				error = self.lastError,
				dataset = self.dataset,
				usedCache = self.dataset ~= nil,
				report = report,
			}
		end
		dataset.validation = report
	end
	self.dataset = dataset
	self.lastSuccessAt = dataset.fetchedAt
	self.successCount = self.successCount + 1
	self.status = "ok"
	self.lastError = nil
	if self.cache then
		local saved = self.cache:Save(dataset)
		if not saved and self.logger then
			self.logger:Warn("AMVGG dataset fetched but cache save failed")
		end
	end
	if self.logger then
		self.logger:Success("AMVGG updated: %d pets (%s mode)", dataset.count or #dataset.pets, tostring(dataset.mode))
	end
	return {
		ok = true,
		status = self.status,
		dataset = dataset,
		attempts = self.lastAttempts,
	}
end

function AMVGGProvider:GetDataset()
	return self.dataset
end

function AMVGGProvider:GetSnapshot()
	local age = nil
	if self.lastSuccessAt then
		age = math.max(0, self.now() - self.lastSuccessAt)
	end
	return {
		status = self.status,
		dataset = self.dataset,
		petCount = self.dataset and (self.dataset.count or #self.dataset.pets) or 0,
		lastSuccessAt = self.lastSuccessAt,
		lastAttemptAt = self.lastAttemptAt,
		lastError = self.lastError,
		age = age,
		source = AMVGGProvider.SOURCE,
		url = self.url,
		mode = self.dataset and self.dataset.mode or nil,
		fromCache = self.dataset and self.dataset.fromCache == true or false,
		attempts = self.lastAttempts,
	}
end

function AMVGGProvider:Status()
	return self.status
end

function AMVGGProvider:Stats()
	return {
		requests = self.requestCount,
		successes = self.successCount,
		failures = self.failureCount,
		status = self.status,
		lastError = self.lastError,
		lastSuccessAt = self.lastSuccessAt,
	}
end

return AMVGGProvider
