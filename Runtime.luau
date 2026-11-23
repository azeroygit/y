local Runtime = {}
Runtime.__index = Runtime

Runtime.FOLDER = "KiriaAutoTrader"

local function safeGetService(name)
	local ok, service = pcall(function()
		return game:GetService(name)
	end)
	if ok then
		return service
	end
	return nil
end

local function findRequestFunction()
	if type(request) == "function" then
		return request
	elseif type(http_request) == "function" then
		return http_request
	elseif type(syn) == "table" and type(syn.request) == "function" then
		return syn.request
	elseif type(http) == "table" and type(http.request) == "function" then
		return http.request
	end
	return nil
end

local function fileExists(path)
	return type(isfile) == "function" and isfile(path)
end

function Runtime.Create(options)
	options = options or {}
	local httpService = safeGetService("HttpService")
	local self = setmetatable({
		isRoblox = httpService ~= nil,
		httpService = httpService,
		requestFunction = findRequestFunction(),
		hasFileApi = type(writefile) == "function" and type(readfile) == "function",
		memoryFiles = {},
		logger = options.logger,
		folderReady = false,
	}, Runtime)
	self.storage = self:_BuildStorage()
	return self
end

function Runtime:JsonEncode(value)
	if self.httpService then
		local ok, result = pcall(function()
			return self.httpService:JSONEncode(value)
		end)
		if ok then
			return result
		end
	end
	return nil
end

function Runtime:JsonDecode(text)
	if self.httpService then
		local ok, result = pcall(function()
			return self.httpService:JSONDecode(text)
		end)
		if ok then
			return result
		end
	end
	return nil
end

function Runtime:EnsureFolders()
	if not self.hasFileApi or self.folderReady then
		return self.hasFileApi
	end
	pcall(function()
		if type(isfolder) == "function" and not isfolder(Runtime.FOLDER) and type(makefolder) == "function" then
			makefolder(Runtime.FOLDER)
		end
	end)
	self.folderReady = true
	return true
end

function Runtime:_BuildStorage()
	local runtime = self
	return {
		read = function(path)
			if runtime.hasFileApi then
				local existsOk, exists = pcall(fileExists, path)
				if existsOk and exists then
					local okRead, content = pcall(readfile, path)
					if okRead then
						return true, content
					end
					return false, tostring(content)
				end
			end
			if runtime.memoryFiles[path] ~= nil then
				return true, runtime.memoryFiles[path]
			end
			return false, "not found"
		end,
		write = function(path, content)
			runtime.memoryFiles[path] = content
			if runtime.hasFileApi then
				runtime:EnsureFolders()
				local ok, err = pcall(writefile, path, content)
				if not ok then
					return false, tostring(err)
				end
			end
			return true
		end,
		remove = function(path)
			runtime.memoryFiles[path] = nil
			if runtime.hasFileApi and type(delfile) == "function" then
				pcall(delfile, path)
			end
			return true
		end,
		exists = function(path)
			if fileExists(path) then
				return true
			end
			return runtime.memoryFiles[path] ~= nil
		end,
	}
end

function Runtime:HttpGet(url, timeoutSeconds)
	if self.requestFunction then
		local ok, response = pcall(self.requestFunction, {
			Url = url,
			Method = "GET",
			Headers = {
				["User-Agent"] = "Mozilla/5.0 (KIRIA AUTOTRADER; AMVGG value reader)",
				["Accept"] = "text/html,application/json;q=0.9,*/*;q=0.8",
			},
		})
		if ok and type(response) == "table" then
			local status = tonumber(response.StatusCode)
			local body = response.Body or response.body
			if body and (status == nil or (status >= 200 and status < 300)) then
				return body
			end
			return nil, string.format("HTTP %s from AMVGG", tostring(status or "unknown"))
		end
		return nil, "request call failed: " .. tostring(response)
	end
	if self.httpService then
		local ok, body = pcall(function()
			return self.httpService:GetAsync(url, true)
		end)
		if ok and type(body) == "string" then
			return body
		end
		return nil, "HttpService request failed: " .. tostring(body)
	end
	return nil, "No HTTP API available. Use an executor with request() or HttpService access."
end

function Runtime:Wait(seconds)
	if type(task) == "table" and type(task.wait) == "function" then
		task.wait(seconds)
	elseif type(wait) == "function" then
		wait(seconds)
	end
	return seconds
end

function Runtime:Spawn(handler)
	if type(task) == "table" and type(task.spawn) == "function" then
		return task.spawn(handler)
	end
	if type(spawn) == "function" then
		return spawn(handler)
	end
	local thread = coroutine.create(handler)
	coroutine.resume(thread)
	return thread
end

function Runtime:Now()
	return os.time()
end

function Runtime:Monotonic()
	return os.clock()
end

function Runtime:Capabilities()
	return {
		http = self.requestFunction ~= nil or self.httpService ~= nil,
		executorRequest = self.requestFunction ~= nil,
		filePersistence = self.hasFileApi,
		json = self.httpService ~= nil,
	}
end

return Runtime
