local Util = require("../Core/Util")

local ProfitCalculator = {}

ProfitCalculator.DefaultThresholds = {
	Excellent = 25,
	Good = 10,
	Fair = -5,
	SmallLoss = -20,
}

ProfitCalculator.Classification = {
	EXCELLENT = "EXCELLENT",
	GOOD = "GOOD",
	FAIR = "FAIR",
	SMALL_LOSS = "SMALL_LOSS",
	BAD = "BAD",
	INCOMPLETE = "INCOMPLETE",
}

function ProfitCalculator.Difference(theirValue, yourValue)
	local theirs = tonumber(theirValue)
	local yours = tonumber(yourValue)
	if not theirs or not yours then
		return nil
	end
	return theirs - yours
end

function ProfitCalculator.Percent(difference, yourValue)
	local diff = tonumber(difference)
	local yours = tonumber(yourValue)
	if not diff or not yours or yours <= 0 then
		return nil
	end
	return (diff / yours) * 100
end

function ProfitCalculator.Classify(percent, thresholds)
	if percent == nil then
		return ProfitCalculator.Classification.INCOMPLETE
	end
	local t = thresholds or ProfitCalculator.DefaultThresholds
	local value = tonumber(percent) or 0
	if value >= (t.Excellent or 25) then
		return ProfitCalculator.Classification.EXCELLENT
	elseif value >= (t.Good or 10) then
		return ProfitCalculator.Classification.GOOD
	elseif value >= (t.Fair or -5) then
		return ProfitCalculator.Classification.FAIR
	elseif value >= (t.SmallLoss or -20) then
		return ProfitCalculator.Classification.SMALL_LOSS
	end
	return ProfitCalculator.Classification.BAD
end

function ProfitCalculator.StatusLabel(classification)
	if classification == ProfitCalculator.Classification.EXCELLENT or classification == ProfitCalculator.Classification.GOOD then
		return "GOOD DEAL"
	elseif classification == ProfitCalculator.Classification.FAIR then
		return "FAIR DEAL"
	elseif classification == ProfitCalculator.Classification.SMALL_LOSS or classification == ProfitCalculator.Classification.BAD then
		return "BAD DEAL"
	end
	return "INCOMPLETE DATA"
end

function ProfitCalculator.ClassifyPercent(percent, thresholds)
	local key = ProfitCalculator.Classify(percent, thresholds)
	return key, ProfitCalculator.StatusLabel(key)
end

function ProfitCalculator.RiskScore(options)
	options = options or {}
	local percent = tonumber(options.percent) or 0
	local itemCount = math.max(1, tonumber(options.itemCount) or 1)
	local incomplete = options.incomplete and 1 or 0
	local demandPenalty = 0
	local demand = options.demand
	if demand == "Low" then
		demandPenalty = 15
	elseif demand == "Medium" then
		demandPenalty = 7
	end
	local risk = 40 - percent * 0.6 + itemCount * 3 + incomplete * 25 + demandPenalty
	return Util.clamp(math.floor(risk + 0.5), 0, 100)
end

function ProfitCalculator.Summarize(options)
	local yourValue = tonumber(options.yourValue) or 0
	local theirValue = tonumber(options.theirValue) or 0
	local difference = theirValue - yourValue
	local percent = ProfitCalculator.Percent(difference, yourValue)
	local classification = ProfitCalculator.Classify(percent, options.thresholds)
	if options.incomplete then
		classification = ProfitCalculator.Classification.INCOMPLETE
	end
	local overpayPercent = percent and math.max(percent, 0) or 0
	local underpayPercent = percent and math.max(-percent, 0) or 0
	return {
		yourValue = yourValue,
		theirValue = theirValue,
		difference = difference,
		percent = percent,
		overpayPercent = overpayPercent,
		underpayPercent = underpayPercent,
		classification = classification,
		statusLabel = ProfitCalculator.StatusLabel(classification),
		potentialProfit = difference,
		riskScore = ProfitCalculator.RiskScore({
			percent = percent,
			itemCount = (options.yourCount or 1) + (options.theirCount or 1),
			incomplete = options.incomplete,
			demand = options.demand,
		}),
	}
end

return ProfitCalculator
