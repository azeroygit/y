local Util = require("../Core/Util")

local InventoryValuator = {}
InventoryValuator.__index = InventoryValuator

function InventoryValuator.new(options)
	options = options or {}
	return setmetatable({
		engine = options.engine,
	}, InventoryValuator)
end

function InventoryValuator:Valuate(items)
	local evaluation = self.engine:EvaluateItems(items)
	local byVariant = {
		regular = { count = 0, value = 0 },
		neon = { count = 0, value = 0 },
		mega = { count = 0, value = 0 },
	}
	local top = nil
	local valued = {}
	for index = 1, #evaluation.items do
		local entry = evaluation.items[index]
		local decorated = {
			uid = entry.input.uid,
			name = entry.name,
			variant = entry.variant,
			fly = entry.fly,
			ride = entry.ride,
			quantity = entry.quantity,
			unitValue = entry.unitValue,
			value = entry.value,
			demand = entry.demand,
			origin = entry.record and entry.record.origin or nil,
			complete = entry.complete,
			error = entry.error,
			raw = entry.input.raw,
		}
		valued[#valued + 1] = decorated
		local bucket = byVariant[decorated.variant]
		if bucket then
			bucket.count = bucket.count + decorated.quantity
			bucket.value = bucket.value + (decorated.value or 0)
		end
		if decorated.unitValue and (not top or decorated.unitValue > top.unitValue) then
			top = decorated
		end
	end
	table.sort(valued, function(a, b)
		return (a.value or 0) > (b.value or 0)
	end)
	return {
		items = valued,
		total = evaluation.total,
		count = evaluation.count,
		incomplete = evaluation.incomplete,
		missingCount = evaluation.missingCount,
		missing = evaluation.missing,
		byVariant = byVariant,
		top = top,
		completeValue = evaluation.total,
	}
end

function InventoryValuator:Summary(items)
	local result = self:Valuate(items)
	return {
		total = result.total,
		count = result.count,
		formatted = Util.formatNumber(result.total),
		topPet = result.top and result.top.name or nil,
		topValue = result.top and result.top.unitValue or nil,
		incomplete = result.incomplete,
		missingCount = result.missingCount,
		byVariant = result.byVariant,
	}
end

function InventoryValuator:Filter(items, options)
	options = options or {}
	local query = Util.nameKey(options.query or "")
	local results = {}
	for index = 1, #items do
		local item = items[index]
		local pass = true
		if query ~= "" then
			pass = pass and string.find(Util.nameKey(item.name), query, 1, true) ~= nil
		end
		if options.variant and options.variant ~= "" then
			pass = pass and item.variant == options.variant
		end
		if options.fly ~= nil then
			pass = pass and item.fly == options.fly
		end
		if options.ride ~= nil then
			pass = pass and item.ride == options.ride
		end
		if options.demand and options.demand ~= "" then
			pass = pass and item.demand == options.demand
		end
		if options.minValue then
			pass = pass and (item.value or 0) >= options.minValue
		end
		if pass then
			results[#results + 1] = item
		end
	end
	local sortMode = options.sort or "value"
	if sortMode == "name" then
		table.sort(results, function(a, b)
			if a.name == b.name then
				return (a.value or 0) > (b.value or 0)
			end
			return a.name < b.name
		end)
	elseif sortMode == "quantity" then
		table.sort(results, function(a, b)
			return (a.quantity or 0) > (b.quantity or 0)
		end)
	else
		table.sort(results, function(a, b)
			return (a.value or 0) > (b.value or 0)
		end)
	end
	return results
end

return InventoryValuator
