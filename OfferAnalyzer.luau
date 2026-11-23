local Util = require("../Core/Util")

local OfferAnalyzer = {}
OfferAnalyzer.__index = OfferAnalyzer

OfferAnalyzer.Recommendation = {
	ACCEPT_AFTER_CONFIRMATION = "ACCEPT_AFTER_CONFIRMATION",
	NEGOTIATE = "NEGOTIATE",
	DECLINE_SUGGESTED = "DECLINE_SUGGESTED",
	VERIFY_DATA = "VERIFY_DATA",
}

function OfferAnalyzer.new(options)
	options = options or {}
	return setmetatable({
		evaluator = options.evaluator,
		reader = options.reader,
	}, OfferAnalyzer)
end

function OfferAnalyzer:Analyze(offer, options)
	options = options or {}
	local evaluation = self.evaluator:EvaluateOffer(offer, options)
	local recommendation = OfferAnalyzer.Recommendation.DECLINE_SUGGESTED
	local reasons = {}
	if evaluation.confidence ~= "COMPLETE" then
		recommendation = OfferAnalyzer.Recommendation.VERIFY_DATA
		reasons[#reasons + 1] = "Incomplete AMVGG data: verify missing pets before considering this offer."
	elseif evaluation.classification == "EXCELLENT" or evaluation.classification == "GOOD" then
		recommendation = OfferAnalyzer.Recommendation.ACCEPT_AFTER_CONFIRMATION
		reasons[#reasons + 1] = string.format(
			"Their offer is %s value ahead (%s).",
			Util.formatNumber(evaluation.difference),
			Util.formatPercent(evaluation.percent)
		)
	elseif evaluation.classification == "FAIR" then
		recommendation = OfferAnalyzer.Recommendation.NEGOTIATE
		reasons[#reasons + 1] = "Values are close; demand and liquidity decide the outcome."
	else
		reasons[#reasons + 1] = string.format(
			"Their offer is %s value behind (%s).",
			Util.formatNumber(math.abs(evaluation.difference)),
			Util.formatPercent(evaluation.percent)
		)
	end
	if options.inventory then
		local missing = {}
		for index = 1, #(offer.requestedItems or {}) do
			local item = offer.requestedItems[index]
			local owned = self.reader and self.reader:CountOwned(options.inventory, item.name, item.variant, item.fly, item.ride) or nil
			local needed = item.quantity or 1
			if owned ~= nil and owned < needed then
				missing[#missing + 1] = string.format("%s (%d/%d owned)", item.name, owned, needed)
			end
		end
		if #missing > 0 then
			reasons[#reasons + 1] = "Warning: requested pets exceed your imported inventory: " .. table.concat(missing, ", ")
			if recommendation == OfferAnalyzer.Recommendation.ACCEPT_AFTER_CONFIRMATION then
				recommendation = OfferAnalyzer.Recommendation.NEGOTIATE
			end
		end
	end
	if evaluation.demand and evaluation.demand == "Low" then
		reasons[#reasons + 1] = "Reminder: equal AMVGG value does not guarantee equal liquidity."
	end
	reasons[#reasons + 1] = "KIRIA AUTOTRADER never accepts automatically; confirm the trade yourself in Adopt Me."
	return {
		offer = offer,
		evaluation = evaluation,
		recommendation = recommendation,
		reasons = reasons,
		statusLabel = evaluation.statusLabel,
		confidence = evaluation.confidence,
		potentialProfit = evaluation.potentialProfit,
		percent = evaluation.percent,
		riskScore = evaluation.riskScore,
		requiresConfirmation = true,
		analyzedAt = options.now or os.time(),
	}
end

function OfferAnalyzer:Rank(analyses)
	local copy = {}
	for index = 1, #analyses do
		copy[index] = analyses[index]
	end
	table.sort(copy, function(a, b)
		local ap = a.evaluation and a.evaluation.potentialProfit or -math.huge
		local bp = b.evaluation and b.evaluation.potentialProfit or -math.huge
		if ap == bp then
			return (a.evaluation and a.evaluation.percent or -math.huge) > (b.evaluation and b.evaluation.percent or -math.huge)
		end
		return ap > bp
	end)
	return copy
end

return OfferAnalyzer
