local Util = require("../Core/Util")

local ConfigManager = {}
ConfigManager.__index = ConfigManager

ConfigManager.Defaults = {
	SchemaVersion = 1,
	Values = {
		RefreshIntervalSeconds = 900,
		MinRefreshIntervalSeconds = 30,
		RequestTimeoutSeconds = 30,
		MaxRetries = 3,
		MinPetCount = 100,
		CacheFile = "KiriaAutoTrader/amvgg_cache.json",
	},
	Thresholds = {
		Excellent = 25,
		Good = 10,
		Fair = -5,
		SmallLoss = -20,
	},
	Scanner = {
		MinValue = 0,
		MinProfit = 0.5,
		MinGainPercent = 5,
		MaxSeenHistory = 500,
	},
	Offers = {
		MaxItems = 6,
		MinProfit = 0.5,
		MinGainPercent = 5,
		MaxCandidates = 25,
		ResponseCheckSeconds = 45,
		ResponseTimeoutSeconds = 600,
	},
	Listings = {
		StaleSeconds = 60,
		WarnBeforeCancelPendingOffers = true,
	},
	UI = {
		Theme = "Kiria Terminal",
		Accent = "Purple",
		Animations = true,
		ShowKiria = true,
		CompactTables = false,
	},
	Notifications = {
		Enabled = true,
		GoodDealToasts = true,
		ExpiryToasts = true,
		ValueRefreshToasts = true,
	},
	Data = {
		HistoryFile = "KiriaAutoTrader/history.json",
		SettingsFile = "KiriaAutoTrader/settings.json",
		InventoryFile = "KiriaAutoTrader/inventory.json",
		KiriaMemoryFile = "KiriaAutoTrader/kiria_memory.json",
		AutoSave = true,
	},
}

local function isList(value)
	if type(value) ~= "table" then
		return false
	end
	local count = 0
	for _ in pairs(value) do
		count = count + 1
	end
	return count == #value
end

local function merge(defaults, overrides, path, warnings)
	local result = {}
	for key, defaultValue in pairs(defaults) do
		local keyPath = path == "" and tostring(key) or (path .. "." .. tostring(key))
		local override = overrides and overrides[key]
		if type(defaultValue) == "table" and not isList(defaultValue) then
			if override ~= nil and type(override) ~= "table" then
				warnings[#warnings + 1] = keyPath .. " must be a table; default kept"
				override = nil
			end
			result[key] = merge(defaultValue, override, keyPath, warnings)
		elseif override == nil then
			result[key] = Util.deepCopy(defaultValue)
		elseif type(override) ~= type(defaultValue) then
			warnings[#warnings + 1] = keyPath .. " must be a " .. type(defaultValue) .. "; default kept"
			result[key] = Util.deepCopy(defaultValue)
		else
			result[key] = Util.deepCopy(override)
		end
	end
	if type(overrides) == "table" then
		for key in pairs(overrides) do
			if defaults[key] == nil then
				warnings[#warnings + 1] = "unknown setting ignored: " .. (path == "" and tostring(key) or (path .. "." .. tostring(key)))
			end
		end
	end
	return result
end

function ConfigManager.Build(defaults, overrides)
	local warnings = {}
	local config = merge(defaults or ConfigManager.Defaults, overrides or {}, "", warnings)
	return config, warnings
end

function ConfigManager.new(options)
	options = options or {}
	local defaults = options.defaults or ConfigManager.Defaults
	local config, warnings = ConfigManager.Build(defaults, options.saved or {})
	local self = setmetatable({
		defaults = Util.deepCopy(defaults),
		config = config,
		warnings = warnings,
		storage = options.storage,
		jsonEncode = options.jsonEncode,
		logger = options.logger,
		listeners = {},
	}, ConfigManager)
	if #warnings > 0 and self.logger then
		for index = 1, #warnings do
			self.logger:Warn("config: %s", warnings[index])
		end
	end
	return self
end

local function resolve(root, path)
	if type(path) == "string" then
		local parts = {}
		for part in string.gmatch(path, "[^%.]+") do
			parts[#parts + 1] = part
		end
		path = parts
	end
	local node = root
	for index = 1, #path do
		if type(node) ~= "table" then
			return nil
		end
		node = node[path[index]]
	end
	return node
end

function ConfigManager:Get(path)
	return resolve(self.config, path)
end

function ConfigManager:Default(path)
	return resolve(self.defaults, path)
end

function ConfigManager:Set(path, value)
	local parts = path
	if type(path) == "string" then
		parts = {}
		for part in string.gmatch(path, "[^%.]+") do
			parts[#parts + 1] = part
		end
	end
	local parent = resolve(self.config, { table.unpack(parts, 1, #parts - 1) })
	local defaultParent = resolve(self.defaults, { table.unpack(parts, 1, #parts - 1) })
	local key = parts[#parts]
	if type(parent) ~= "table" or type(defaultParent) ~= "table" then
		return false, "invalid config path"
	end
	local expected = defaultParent[key]
	if expected ~= nil and type(value) ~= type(expected) then
		return false, "type mismatch for " .. tostring(path)
	end
	parent[key] = value
	for index = 1, #self.listeners do
		local listener = self.listeners[index]
		pcall(listener, path, value)
	end
	return true
end

function ConfigManager:Apply(overrides)
	local config, warnings = ConfigManager.Build(self.defaults, overrides)
	self.config = config
	self.warnings = warnings
	for index = 1, #self.listeners do
		pcall(self.listeners[index], "*", config)
	end
	return config, warnings
end

function ConfigManager:Reset()
	self:Apply({})
	return self.config
end

function ConfigManager:Subscribe(handler)
	self.listeners[#self.listeners + 1] = handler
	local listeners = self.listeners
	local connection = {}
	function connection.Disconnect()
		for index, entry in ipairs(listeners) do
			if entry == handler then
				table.remove(listeners, index)
				break
			end
		end
	end
	return connection
end

function ConfigManager:Save()
	if not self.storage or not self.jsonEncode then
		return false, "storage unavailable"
	end
	local ok, encoded = pcall(self.jsonEncode, self.config)
	if not ok or not encoded then
		return false, "encode failed"
	end
	local writeOk, err = self.storage.write(self.config.Data.SettingsFile, encoded)
	if not writeOk then
		return false, tostring(err)
	end
	return true
end

function ConfigManager:LoadSaved(saved)
	if type(saved) ~= "table" then
		return false, "no saved settings"
	end
	self:Apply(saved)
	return true
end

function ConfigManager:Snapshot()
	return Util.deepCopy(self.config)
end

function ConfigManager:Warnings()
	return self.warnings
end

return ConfigManager
