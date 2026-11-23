local Util = require("../Core/Util")
local ProfitCalculator = require("../Trading/ProfitCalculator")

local ValueEngine = {}
ValueEngine.__index = ValueEngine

ValueEngine.Variants = {
	regular = true,
	neon = true,
	mega = true,
}

function ValueEngine.new(options)
	options = options or {}
	return setmetatable({
		provider = options.provider,
		thresholds = options.thresholds or ProfitCalculator.DefaultThresholds,
		dataset = nil,
		index = {},
		builtAt = nil,
	}, ValueEngine)
end

function ValueEngine:SetDataset(dataset)
	self.dataset = dataset
	self.index = {}
	self.builtAt = os.time()
	if type(dataset) == "table" and type(dataset.pets) == "table" then
		for index = 1, #dataset.pets do
			local pet = dataset.pets[index]
			if type(pet) == "table" and pet.name then
				local key = pet.key or Util.nameKey(pet.name)
				if not self.index[key] then
					self.index[key] = pet
				end
			end
		end
	end
	return self
end

function ValueEngine:RefreshFromProvider()
	if not self.provider then
		return false, "no provider configured"
	end
	local snapshot = self.provider:GetSnapshot()
	local dataset = snapshot and snapshot.dataset
	if not dataset then
		return false, snapshot and snapshot.error or "no AMVGG dataset"
	end
	self:SetDataset(dataset)
	return true
end

function ValueEngine:HasDataset()
	return self.dataset ~= nil
end

function ValueEngine:Count()
	return self.dataset and self.dataset.count or 0
end

function ValueEngine:FindPet(name)
	if not name or not self.dataset then
		return nil
	end
	return self.index[Util.nameKey(name)]
end

function ValueEngine:AllPets()
	if not self.dataset then
		return {}
	end
	return self.dataset.pets
end

function ValueEngine:FieldFor(variant, fly, ride, noPot)
	local v = variant or "regular"
	if not ValueEngine.Variants[v] then
		v = "regular"
	end
	if v == "mega" then
		if noPot then
			return "megaBase", "mega", "mega"
		elseif fly and ride then
			return "mega", "mega", "mega"
		elseif fly then
			return "megaFly", "mega", "mega"
		elseif ride then
			return "megaRide", "mega", "mega"
		end
		return "mega", "mega", "mega"
	elseif v == "neon" then
		if noPot then
			return "neonBase", "neon", "neon"
		elseif fly and ride then
			return "neon", "neon", "neon"
		elseif fly then
			return "neonFly", "neon", "neon"
		elseif ride then
			return "neonRide", "neon", "neon"
		end
		return "neon", "neon", "neon"
	end
	if noPot then
		return "base", "regular", "regular"
	elseif fly and ride then
		return "regular", "regular", "regular"
	elseif fly then
		return "fly", "regular", "regular"
	elseif ride then
		return "ride", "regular", "regular"
	end
	return "regular", "regular", "regular"
end

function ValueEngine:ValueOfItem(item)
	if type(item) ~= "table" then
		return nil, nil, "invalid item"
	end
	local record = self:FindPet(item.name)
	if not record then
		return nil, nil, "pet not found in AMVGG dataset"
	end
	local variant = item.variant or "regular"
	if not ValueEngine.Variants[variant] then
		return nil, record, "unknown variant " .. tostring(variant)
	end
	local field, demandField, fallbackField = self:FieldFor(variant, item.fly == true, item.ride == true, item.noPot == true)
	local values = record.values or {}
	local value = values[field]
	local usedField = field
	if (type(value) ~= "number" or value ~= value or value <= 0) and fallbackField and fallbackField ~= field then
		value = values[fallbackField]
		usedField = fallbackField
	end
	local demand = record.demand and (record.demand[demandField] or record.demand[fallbackField])
	if type(value) ~= "number" or value ~= value or value <= 0 then
		return nil, record, string.format("AMVGG has no verified %s value", field)
	end
	return value, record, nil, usedField, demand
end

function ValueEngine:ValueOfPet(name, variant, fly, ride)
	local value = self:ValueOfItem({ name = name, variant = variant, fly = fly, ride = ride })
	return value
end

function ValueEngine:EvaluateItems(items)
	local results = {
		items = {},
		total = 0,
		count = 0,
		missingCount = 0,
		incomplete = false,
		missing = {},
	}
	if type(items) ~= "table" then
		results.incomplete = true
		return results
	end
	for index = 1, #items do
		local item = items[index]
		local quantity = math.max(1, math.floor(tonumber(item.quantity or item.qty) or 1))
		local unitValue, record, err, field, demand = self:ValueOfItem(item)
		local entry = {
			input = item,
			name = item.name,
			variant = item.variant or "regular",
			fly = item.fly == true,
			ride = item.ride == true,
			quantity = quantity,
			unitValue = unitValue,
			value = unitValue and (unitValue * quantity) or nil,
			record = record,
			field = field,
			demand = demand,
			complete = unitValue ~= nil,
			error = err,
		}
		results.items[#results.items + 1] = entry
		results.count = results.count + quantity
		if unitValue then
			results.total = results.total + unitValue * quantity
		else
			results.missingCount = results.missingCount + 1
			results.incomplete = true
			results.missing[#results.missing + 1] = {
				name = item.name,
				variant = entry.variant,
				reason = err,
			}
		end
	end
	return results
end

function ValueEngine:Compare(yourItems, theirItems, options)
	options = options or {}
	local yours = self:EvaluateItems(yourItems)
	local theirs = self:EvaluateItems(theirItems)
	local incomplete = yours.incomplete or theirs.incomplete
	local summary = ProfitCalculator.Summarize({
		yourValue = yours.total,
		theirValue = theirs.total,
		thresholds = options.thresholds or self.thresholds,
		incomplete = incomplete,
		yourCount = yours.count,
		theirCount = theirs.count,
		demand = options.demand,
	})
	summary.yourOffer = yours
	summary.theirOffer = theirs
	summary.confidence = incomplete and "INCOMPLETE" or "COMPLETE"
	summary.missing = {}
	for _, entry in ipairs(yours.missing) do
		summary.missing[#summary.missing + 1] = entry
	end
	for _, entry in ipairs(theirs.missing) do
		summary.missing[#summary.missing + 1] = entry
	end
	summary.complete = not incomplete
	return summary
end

function ValueEngine:InventoryValue(items)
	local evaluation = self:EvaluateItems(items)
	return evaluation.total, evaluation
end

function ValueEngine:Meta()
	if not self.dataset then
		return { available = false }
	end
	return {
		available = true,
		source = self.dataset.source or "AMVGG",
		url = self.dataset.url,
		fetchedAt = self.dataset.fetchedAt,
		count = self.dataset.count or #self.dataset.pets,
		mode = self.dataset.mode,
		fromCache = self.dataset.fromCache == true,
	}
end

return ValueEngine
