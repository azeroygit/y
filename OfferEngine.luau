local Util = require("../Core/Util")
local ProfitCalculator = require("./ProfitCalculator")

local OfferEngine = {}
OfferEngine.__index = OfferEngine

function OfferEngine.new(options)
	options = options or {}
	return setmetatable({
		engine = options.engine,
		calculator = options.calculator or ProfitCalculator,
		thresholds = options.thresholds or ProfitCalculator.DefaultThresholds,
		nodeBudget = tonumber(options.nodeBudget) or 20000,
	}, OfferEngine)
end

local function mergeUnits(units)
	local merged = {}
	local byKey = {}
	for index = 1, #units do
		local unit = units[index]
		local item = unit.item
		local key = string.format("%s|%s|%s|%s", Util.nameKey(item.name), tostring(item.variant), tostring(item.fly), tostring(item.ride))
		local existing = byKey[key]
		if existing then
			existing.quantity = existing.quantity + 1
		else
			local copy = {
				name = item.name,
				variant = item.variant or "regular",
				fly = item.fly == true,
				ride = item.ride == true,
				quantity = 1,
			}
			byKey[key] = copy
			merged[#merged + 1] = copy
		end
	end
	return merged
end

function OfferEngine:BuildUnits(inventory)
	local units = {}
	if not self.engine then
		return units
	end
	for index = 1, #inventory do
		local item = inventory[index]
		local quantity = math.max(1, math.floor(tonumber(item.quantity or item.qty) or 1))
		local unitValue = self.engine:ValueOfItem(item)
		if unitValue and unitValue > 0 then
			for _ = 1, quantity do
				units[#units + 1] = {
					item = item,
					value = unitValue,
					name = item.name,
					variant = item.variant or "regular",
				}
			end
		end
	end
	table.sort(units, function(a, b)
		if a.value == b.value then
			return a.name < b.name
		end
		return a.value < b.value
	end)
	return units
end

function OfferEngine:AcceptanceRisk(percent, itemCount, demand)
	local risk = 100 - (tonumber(percent) or 0) * 3 + math.max(0, itemCount - 1) * 4
	if demand == "Low" then
		risk = risk + 15
	elseif demand == "Medium" then
		risk = risk + 5
	end
	return Util.clamp(math.floor(risk + 0.5), 0, 100)
end

function OfferEngine:Recommend(options)
	options = options or {}
	local inventory = options.inventory or {}
	local targets = options.targets or {}
	local maxItems = math.max(1, math.floor(tonumber(options.maxItems) or 6))
	local minProfit = tonumber(options.minProfit) or 0.5
	local minGainPercent = tonumber(options.minGainPercent) or 5
	local minFillPercent = tonumber(options.minFillPercent) or 60
	local maxCandidates = math.max(1, math.floor(tonumber(options.maxCandidates) or 25))
	local result = {
		candidates = {},
		targetEvaluation = nil,
		unitsConsidered = 0,
		nodesVisited = 0,
		truncated = false,
		warnings = {},
	}
	if not self.engine or not self.engine:HasDataset() then
		result.warnings[#result.warnings + 1] = "AMVGG values are not loaded; refresh values first."
		return result
	end
	local targetEvaluation = self.engine:EvaluateItems(targets)
	result.targetEvaluation = targetEvaluation
	if targetEvaluation.incomplete or targetEvaluation.total <= 0 then
		result.warnings[#result.warnings + 1] = "Target has no verified AMVGG value; cannot build a safe offer."
		return result
	end
	local targetTotal = targetEvaluation.total
	local units = self:BuildUnits(inventory)
	if #units == 0 then
		result.warnings[#result.warnings + 1] = "No valued pets in the imported inventory."
		return result
	end
	local maxUnits = math.min(#units, tonumber(options.maxUnits) or 26)
	result.unitsConsidered = maxUnits
	if maxUnits < #units then
		result.truncated = true
		result.warnings[#result.warnings + 1] = "Search bounded to the 26 lowest-value owned pets to avoid combinatorial explosion."
	end
	local selected = {}
	local best = {}
	local nodes = 0
	local budget = tonumber(options.nodeBudget) or self.nodeBudget
	local minFill = targetTotal * (minFillPercent / 100)
	local function consider(sum)
		local profit = targetTotal - sum
		local percent = ProfitCalculator.Percent(profit, sum)
		if profit + 0.000001 < minProfit then
			return
		end
		if sum < minFill then
			return
		end
		if not percent or percent < minGainPercent then
			return
		end
		local count = #selected
		local giveItems = mergeUnits(selected)
		local candidate = {
			giveItems = giveItems,
			targetItems = targets,
			yourValue = sum,
			targetValue = targetTotal,
			profit = profit,
			percent = percent,
			itemCount = count,
			acceptanceRisk = self:AcceptanceRisk(percent, count, targetEvaluation.items[1] and targetEvaluation.items[1].demand),
			classification = ProfitCalculator.Classify(percent, self.thresholds),
			createdAt = options.now or os.time(),
		}
		candidate.explanation = string.format(
			"Give %s value for %s value: +%s (%s) using %d item(s).",
			Util.formatNumber(sum),
			Util.formatNumber(targetTotal),
			Util.formatNumber(profit),
			Util.formatPercent(percent),
			count
		)
		best[#best + 1] = candidate
		table.sort(best, function(a, b)
			if a.profit == b.profit then
				return a.acceptanceRisk < b.acceptanceRisk
			end
			return a.profit > b.profit
		end)
		while #best > maxCandidates do
			table.remove(best)
		end
	end
	local function dfs(startIndex, sum)
		if nodes >= budget then
			result.truncated = true
			return
		end
		nodes = nodes + 1
		if #selected > 0 then
			consider(sum)
		end
		if #selected >= maxItems then
			return
		end
		for index = startIndex, maxUnits do
			if nodes >= budget then
				result.truncated = true
				return
			end
			local unit = units[index]
			local nextSum = sum + unit.value
			if nextSum > targetTotal then
				break
			end
			selected[#selected + 1] = unit
			dfs(index + 1, nextSum)
			selected[#selected] = nil
		end
	end
	dfs(1, 0)
	result.nodesVisited = nodes
	result.candidates = best
	if #best == 0 then
		result.warnings[#result.warnings + 1] = "No profitable combination found within the configured limits."
	end
	result.warnings[#result.warnings + 1] = "AMVGG value does not guarantee demand or a willing trader; verify before offering."
	return result
end

function OfferEngine:RecommendForTargets(inventory, targetList, options)
	options = options or {}
	local all = {}
	local warnings = {}
	for index = 1, #targetList do
		local target = targetList[index]
		local single = self:Recommend({
			inventory = inventory,
			targets = { target },
			maxItems = options.maxItems,
			minProfit = options.minProfit,
			minGainPercent = options.minGainPercent,
			minFillPercent = options.minFillPercent,
			maxCandidates = options.maxCandidates,
			maxUnits = options.maxUnits,
			nodeBudget = options.nodeBudget,
			now = options.now,
		})
		for _, warning in ipairs(single.warnings) do
			warnings[#warnings + 1] = warning
		end
		for _, candidate in ipairs(single.candidates) do
			candidate.target = target
			all[#all + 1] = candidate
		end
	end
	table.sort(all, function(a, b)
		if a.profit == b.profit then
			return a.acceptanceRisk < b.acceptanceRisk
		end
		return a.profit > b.profit
	end)
	local limited = {}
	for index = 1, math.min(#all, math.max(1, math.floor(tonumber(options.maxCandidates) or 25))) do
		limited[index] = all[index]
	end
	return {
		candidates = limited,
		warnings = warnings,
	}
end

return OfferEngine
