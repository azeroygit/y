local ValueCache = {}
ValueCache.__index = ValueCache

ValueCache.SchemaVersion = 2

function ValueCache.new(options)
	options = options or {}
	return setmetatable({
		storage = options.storage,
		jsonEncode = options.jsonEncode,
		jsonDecode = options.jsonDecode,
		clock = options.clock or os.time,
		logger = options.logger,
		path = options.path or "KiriaAutoTrader/amvgg_cache.json",
		lastValid = nil,
		lastError = nil,
		loadedFromDisk = false,
	}, ValueCache)
end

function ValueCache:SetPath(path)
	self.path = path
end

function ValueCache:Save(dataset)
	if type(dataset) ~= "table" or type(dataset.pets) ~= "table" or #dataset.pets == 0 then
		return false, "refusing to cache empty dataset"
	end
	self.lastValid = dataset
	if not self.storage or not self.jsonEncode then
		return false, "cache persistence unavailable"
	end
	local payload = {
		schemaVersion = ValueCache.SchemaVersion,
		source = dataset.source or "AMVGG",
		url = dataset.url,
		fetchedAt = dataset.fetchedAt,
		savedAt = self.clock(),
		mode = dataset.mode,
		count = dataset.count or #dataset.pets,
		skipped = dataset.skipped,
		pets = dataset.pets,
	}
	local ok, encoded = pcall(self.jsonEncode, payload)
	if not ok or not encoded then
		self.lastError = "cache encode failed: " .. tostring(encoded)
		return false, self.lastError
	end
	local writeOk, err = self.storage.write(self.path, encoded)
	if not writeOk then
		self.lastError = "cache write failed: " .. tostring(err)
		if self.logger then
			self.logger:Warn("%s", self.lastError)
		end
		return false, self.lastError
	end
	return true
end

function ValueCache:Load()
	if not self.storage or not self.jsonDecode then
		self.lastError = "cache persistence unavailable"
		return nil, self.lastError
	end
	local okRead, content = self.storage.read(self.path)
	if not okRead or not content then
		self.lastError = "no cached dataset"
		return nil, self.lastError
	end
	local okDecode, decoded = pcall(self.jsonDecode, content)
	if not okDecode or type(decoded) ~= "table" then
		self.lastError = "cached dataset is not valid JSON"
		return nil, self.lastError
	end
	if decoded.schemaVersion ~= ValueCache.SchemaVersion then
		self.lastError = string.format("cache schema mismatch (%s)", tostring(decoded.schemaVersion))
		return nil, self.lastError
	end
	if type(decoded.pets) ~= "table" or #decoded.pets == 0 then
		self.lastError = "cached dataset has no pets"
		return nil, self.lastError
	end
	local dataset = {
		source = decoded.source or "AMVGG",
		url = decoded.url,
		fetchedAt = decoded.fetchedAt,
		cachedAt = decoded.savedAt,
		mode = decoded.mode,
		count = decoded.count or #decoded.pets,
		skipped = decoded.skipped,
		pets = decoded.pets,
		fromCache = true,
	}
	self.lastValid = dataset
	self.loadedFromDisk = true
	self.lastError = nil
	return dataset
end

function ValueCache:GetLastValid()
	return self.lastValid
end

function ValueCache:Age(now)
	if not self.lastValid or type(self.lastValid.fetchedAt) ~= "number" then
		return nil
	end
	return math.max(0, (now or self.clock()) - self.lastValid.fetchedAt)
end

function ValueCache:IsStale(maxAgeSeconds, now)
	local age = self:Age(now)
	if age == nil then
		return true
	end
	return age > (maxAgeSeconds or 86400)
end

function ValueCache:Clear()
	self.lastValid = nil
	self.lastError = nil
	self.loadedFromDisk = false
	if self.storage then
		pcall(self.storage.remove, self.path)
	end
	return true
end

function ValueCache:LastError()
	return self.lastError
end

return ValueCache
