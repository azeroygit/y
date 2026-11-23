local Mock = {}

function Mock.Clock(startTime)
	local clock = {
		time = startTime or 1000000,
	}
	function clock.now()
		return clock.time
	end
	function clock.advance(seconds)
		clock.time = clock.time + (seconds or 0)
		return clock.time
	end
	return clock
end

function Mock.Storage()
	local files = {}
	local storage = { files = files }
	function storage.read(path)
		if files[path] == nil then
			return false, "not found"
		end
		return true, files[path]
	end
	function storage.write(path, content)
		files[path] = content
		return true
	end
	function storage.remove(path)
		files[path] = nil
		return true
	end
	function storage.exists(path)
		return files[path] ~= nil
	end
	return storage
end

function Mock.HttpResponse(body)
	return function()
		return body
	end
end

function Mock.HttpError(message)
	return function()
		return nil, message or "network error"
	end
end

function Mock.HttpSequence(responses)
	local index = 0
	return function()
		index = index + 1
		local entry = responses[index] or responses[#responses]
		if type(entry) == "function" then
			return entry()
		end
		if entry == nil then
			return nil, "no response"
		end
		if type(entry) == "table" then
			return entry.body, entry.error
		end
		return entry
	end
end

function Mock.Dataset()
	local function pet(name, regular, neon, mega, demand)
		return {
			id = "mock-" .. name,
			name = name,
			key = string.lower(string.gsub(name, "[^%w]", "")),
			origin = "Mock Origin",
			category = 1,
			updatedAt = "2026-01-01T00:00:00.000Z",
			demand = {
				regular = demand or "High",
				fly = demand or "High",
				ride = demand or "High",
				base = demand or "High",
				neon = demand or "High",
				neonFly = demand or "High",
				neonRide = demand or "High",
				neonBase = demand or "High",
				mega = demand or "High",
				megaFly = demand or "High",
				megaRide = demand or "High",
				megaBase = demand or "High",
			},
			values = {
				regular = regular,
				fly = regular,
				ride = regular,
				base = regular,
				neon = neon or (regular and regular * 2.5),
				neonFly = neon or (regular and regular * 2.5),
				neonRide = neon or (regular and regular * 2.5),
				neonBase = neon or (regular and regular * 2.5),
				mega = mega or (neon and neon * 3),
				megaFly = mega or (neon and neon * 3),
				megaRide = mega or (neon and neon * 3),
				megaBase = mega or (neon and neon * 3),
			},
			regular = regular,
			neon = neon,
			mega = mega,
		}
	end
	local pets = {
		pet("Bat Dragon", 5.53, 12.775, 36.4, "High"),
		pet("Shadow Dragon", 3.775, 7.51, 18.3, "High"),
		pet("Giraffe", 2.59, 6.2, 15.0, "Medium"),
		pet("Frost Dragon", 1.76, 4.4, 11.0, "High"),
		pet("Owl", 1.355, 3.2, 8.0, "Medium"),
		pet("Parrot", 1.085, 2.6, 6.0, "Low"),
		pet("Unicorn", 0.85, 2.1, 5.2, "High"),
		pet("Dog", 0.05, 0.2, 0.6, "Low"),
	}
	pets[1].values.fly = 5.53
	pets[1].values.megaFly = 36.7
	return {
		source = "AMVGG",
		url = "https://amvgg.com/values/pets",
		fetchedAt = 1000000,
		mode = "flight",
		pets = pets,
		count = #pets,
		skipped = 0,
	}
end

function Mock.Item(name, quantity, variant, fly, ride)
	return {
		name = name,
		quantity = quantity or 1,
		variant = variant or "regular",
		fly = fly == true,
		ride = ride == true,
	}
end

function Mock.Inventory()
	return {
		Mock.Item("Dog", 2),
		Mock.Item("Dog", 1, "neon", true, true),
		Mock.Item("Parrot", 1),
		Mock.Item("Owl", 1),
		Mock.Item("Unicorn", 1),
		Mock.Item("Frost Dragon", 1),
	}
end

function Mock.Payload()
	return table.concat({
		'{"pets":[',
		'{"id":"1","name":"Bat Dragon","regularValue":"5.53","npRegularValue":"5.58","neonValue":"12.775","npNeonValue":"13.4","megaValue":"36.4","npMegaValue":"39.7","regularDemand":"High","npRegularDemand":"High","neonDemand":"High","npNeonDemand":"High","megaDemand":"High","npMegaDemand":"High","origin":"Halloween Event (2019)","category":13,"rValue":"5.53","fValue":"5.53","nrValue":"12.975","nfValue":"13.025","mrValue":"36.6","mfValue":"36.7","fDemand":"High","rDemand":"High","nrDemand":"High","nfDemand":"High","mrDemand":"High","mfDemand":"High","lastUpdatedAt":"$D2026-11-16T16:10:15.223Z"},',
		'{"id":"2","name":"Giraffe","regularValue":"2.59","npRegularValue":"2.67","neonValue":"6.2","npNeonValue":"7.1","megaValue":"15","npMegaValue":"18","regularDemand":"Medium","npRegularDemand":"Medium","neonDemand":"High","npNeonDemand":"High","megaDemand":"High","npMegaDemand":"High","origin":"Safari Egg","category":13,"lastUpdatedAt":"$D2026-11-10T10:00:00.000Z"},',
		'{"id":"3","name":"Owl","regularValue":"1.355","neonValue":"3.2","megaValue":"8","origin":"Farm Egg","category":13,"lastUpdatedAt":"$D2026-11-01T09:30:00.000Z"}',
		"],\"page\":1}",
	}, "")
end

function Mock.Html(payload)
	local escaped = string.gsub(payload or Mock.Payload(), "\\", "\\\\")
	escaped = string.gsub(escaped, '"', '\\"')
	escaped = string.gsub(escaped, "\n", "\\n")
	return '<!DOCTYPE html><html><body><script>self.__next_f.push([1,"' .. escaped .. '"])</script></body></html>'
end

function Mock.CardsHtml()
	local cards = {
		['<div data-pet-name="Bat-Dragon" class="card"><h2 title="Bat Dragon">Bat Dragon</h2><div><span>Value</span><span class="value">5.53</span></div><span>★★★</span></div>'] = true,
	}
	local html = {
		'<!DOCTYPE html><html><body>',
		'<div data-pet-name="Bat-Dragon" class="card"><h2 title="Bat Dragon">Bat Dragon</h2><div class="row"><span class="label">Value</span><span class="text-white">5.53</span></div><span>★★★</span></div>',
		'<div data-pet-name="Giraffe" class="card"><h2 title="Giraffe">Giraffe</h2><div class="row"><span class="label">Value</span><span class="text-white">2.59</span></div><span>★★★</span></div>',
		'<div data-pet-name="Owl" class="card"><h2 title="Owl">Owl</h2><div class="row"><span class="label">Value</span><span class="text-white">1.355</span></div><span>★★★</span></div>',
		"</body></html>",
	}
	return table.concat(html, "")
end

return Mock
