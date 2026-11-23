local Util = require("../Core/Util")

local PetDatabase = {}
PetDatabase.__index = PetDatabase

function PetDatabase.new(options)
	options = options or {}
	local self = setmetatable({
		engine = options.engine,
		pets = {},
		byKey = {},
		namesByLength = {},
	}, PetDatabase)
	self:Refresh()
	return self
end

function PetDatabase:Refresh()
	self.pets = {}
	self.byKey = {}
	self.namesByLength = {}
	local source = {}
	if self.engine then
		source = self.engine:AllPets()
	end
	for index = 1, #source do
		local pet = source[index]
		if pet and pet.name then
			self.pets[#self.pets + 1] = pet
			local key = pet.key or Util.nameKey(pet.name)
			if not self.byKey[key] then
				self.byKey[key] = pet
			end
		end
	end
	table.sort(self.pets, function(a, b)
		local av = a.values and a.values.regular or 0
		local bv = b.values and b.values.regular or 0
		if av == bv then
			return a.name < b.name
		end
		return av > bv
	end)
	for index = 1, #self.pets do
		local name = self.pets[index].name
		self.namesByLength[#self.namesByLength + 1] = { name = name, key = Util.nameKey(name), length = #name }
	end
	table.sort(self.namesByLength, function(a, b)
		return a.length > b.length
	end)
	return #self.pets
end

function PetDatabase:Count()
	return #self.pets
end

function PetDatabase:Get(name)
	if not name then
		return nil
	end
	return self.byKey[Util.nameKey(name)]
end

function PetDatabase:All()
	return self.pets
end

function PetDatabase:MatchName(text)
	if type(text) ~= "string" or text == "" then
		return nil
	end
	local normalized = Util.normalizeName(text)
	local key = string.gsub(normalized, "%s+", "")
	local direct = self.byKey[key]
	if direct then
		return direct
	end
	for index = 1, #self.namesByLength do
		local candidate = self.namesByLength[index]
		if string.find(normalized, candidate.key, 1, true) then
			return self.byKey[candidate.key]
		end
	end
	return nil
end

function PetDatabase:DemandRank(demand)
	local ranks = { High = 3, Medium = 2, Low = 1 }
	return ranks[demand] or 0
end

function PetDatabase:Search(query, filters)
	filters = filters or {}
	local searchKey = Util.nameKey(query or "")
	local results = {}
	for index = 1, #self.pets do
		local pet = self.pets[index]
		local key = pet.key or Util.nameKey(pet.name)
		local matches = searchKey == "" or string.find(key, searchKey, 1, true) ~= nil
		if matches then
			local values = pet.values or {}
			local pass = true
			if filters.origin and filters.origin ~= "" then
				pass = pass and pet.origin == filters.origin
			end
			if filters.demand and filters.demand ~= "" then
				pass = pass and pet.demand and pet.demand.regular == filters.demand
			end
			if filters.minValue then
				pass = pass and (values.regular or 0) >= filters.minValue
			end
			if filters.variant == "neon" then
				pass = pass and type(values.neon) == "number" and values.neon > 0
			elseif filters.variant == "mega" then
				pass = pass and type(values.mega) == "number" and values.mega > 0
			end
			if pass then
				results[#results + 1] = pet
			end
		end
	end
	local sortMode = filters.sort or "value"
	if sortMode == "name" then
		table.sort(results, function(a, b)
			return a.name < b.name
		end)
	elseif sortMode == "demand" then
		table.sort(results, function(a, b)
			local ad = self:DemandRank(a.demand and a.demand.regular)
			local bd = self:DemandRank(b.demand and b.demand.regular)
			if ad == bd then
				return (a.values and a.values.regular or 0) > (b.values and b.values.regular or 0)
			end
			return ad > bd
		end)
	else
		table.sort(results, function(a, b)
			return (a.values and a.values.regular or 0) > (b.values and b.values.regular or 0)
		end)
	end
	return results
end

function PetDatabase:Origins()
	local seen = {}
	local list = {}
	for index = 1, #self.pets do
		local origin = self.pets[index].origin
		if origin and not seen[origin] then
			seen[origin] = true
			list[#list + 1] = origin
		end
	end
	table.sort(list)
	return list
end

return PetDatabase
