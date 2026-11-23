local ValueValidator = {}
ValueValidator.__index = ValueValidator

function ValueValidator.new(options)
	options = options or {}
	return setmetatable({
		minPetCount = tonumber(options.minPetCount) or 100,
		maxAllowedMissingRatio = tonumber(options.maxAllowedMissingRatio) or 0.5,
	}, ValueValidator)
end

local function isPositiveNumber(value)
	return type(value) == "number" and value == value and value > 0 and value < math.huge
end

function ValueValidator:ValidatePets(pets, options)
	options = options or {}
	local minimum = tonumber(options.minPetCount) or self.minPetCount
	local report = {
		ok = false,
		errors = {},
		warnings = {},
		count = 0,
		valid = 0,
		invalid = 0,
		duplicates = 0,
		missing = 0,
		withNeon = 0,
		withMega = 0,
		source = options.source,
		checkedAt = os.time(),
	}
	if type(pets) ~= "table" then
		report.errors[#report.errors + 1] = "dataset is not a table"
		return report
	end
	local seen = {}
	for index = 1, #pets do
		local pet = pets[index]
		report.count = report.count + 1
		local problems = {}
		if type(pet) ~= "table" then
			problems[#problems + 1] = "entry is not a table"
		else
			if type(pet.name) ~= "string" or pet.name == "" then
				problems[#problems + 1] = "missing name"
			end
			if type(pet.key) ~= "string" or pet.key == "" then
				pet.key = pet.name and (string.gsub(string.lower(pet.name), "[^%w]+", "")) or nil
			end
			if pet.key then
				if seen[pet.key] then
					report.duplicates = report.duplicates + 1
				end
				seen[pet.key] = true
			end
			local values = pet.values
			if type(values) ~= "table" then
				problems[#problems + 1] = "missing values table"
			else
				if not isPositiveNumber(values.regular) and not isPositiveNumber(pet.regular) then
					problems[#problems + 1] = "invalid regular value"
					report.missing = report.missing + 1
				end
				if isPositiveNumber(values.neon) then
					report.withNeon = report.withNeon + 1
				end
				if isPositiveNumber(values.mega) then
					report.withMega = report.withMega + 1
				end
				for field, value in pairs(values) do
					if value ~= nil and not isPositiveNumber(value) then
						report.warnings[#report.warnings + 1] = string.format("%s: invalid %s value (%s)", tostring(pet.name), tostring(field), tostring(value))
					end
				end
			end
		end
		if #problems == 0 then
			report.valid = report.valid + 1
		else
			report.invalid = report.invalid + 1
			if report.invalid <= 10 then
				report.errors[#report.errors + 1] = string.format("#%d: %s", index, table.concat(problems, ", "))
			end
		end
	end
	if report.count < minimum then
		report.errors[#report.errors + 1] = string.format("dataset too small (%d < %d)", report.count, minimum)
	end
	report.ok = report.count >= minimum and report.valid >= minimum and report.valid >= report.count * (1 - self.maxAllowedMissingRatio)
	return report
end

function ValueValidator:IsDatasetValid(dataset, options)
	if type(dataset) ~= "table" or type(dataset.pets) ~= "table" then
		return false, { ok = false, errors = { "cache dataset malformed" } }
	end
	local report = self:ValidatePets(dataset.pets, options)
	return report.ok, report
end

function ValueValidator:ValidateItem(item, record)
	local result = { complete = false, errors = {} }
	if not record then
		result.errors[#result.errors + 1] = "pet not found in AMVGG dataset"
		return result
	end
	local values = record.values or {}
	local value
	local variant = item.variant or "regular"
	if variant == "mega" then
		value = values.mega
	elseif variant == "neon" then
		value = values.neon
	else
		value = values.regular
	end
	if type(value) ~= "number" or value <= 0 then
		result.errors[#result.errors + 1] = string.format("AMVGG has no valid %s value for %s", variant, record.name)
		return result
	end
	result.complete = true
	result.value = value
	return result
end

return ValueValidator
