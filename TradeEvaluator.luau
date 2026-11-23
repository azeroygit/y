local ProfitCalculator = require("./ProfitCalculator")

local TradeEvaluator = {}
TradeEvaluator.__index = TradeEvaluator

function TradeEvaluator.new(options)
	options = options or {}
	return setmetatable({
		engine = options.engine,
		thresholds = options.thresholds or ProfitCalculator.DefaultThresholds,
	}, TradeEvaluator)
end

function TradeEvaluator:SetThresholds(thresholds)
	self.thresholds = thresholds or ProfitCalculator.DefaultThresholds
end

function TradeEvaluator:Evaluate(giveItems, getItems, options)
	options = options or {}
	if not self.engine then
		return {
			complete = false,
			confidence = "INCOMPLETE",
			classification = "INCOMPLETE",
			statusLabel = "INCOMPLETE DATA",
			error = "value engine unavailable",
			missing = {},
			yourOffer = { items = {}, total = 0, incomplete = true },
			theirOffer = { items = {}, total = 0, incomplete = true },
			difference = 0,
			percent = nil,
			potentialProfit = 0,
			riskScore = 100,
		}
	end
	local summary = self.engine:Compare(giveItems or {}, getItems or {}, {
		thresholds = options.thresholds or self.thresholds,
		demand = options.demand,
	})
	summary.yourItems = giveItems or {}
	summary.theirItems = getItems or {}
	summary.generatedAt = options.now or os.time()
	summary.notes = {}
	if summary.confidence == "INCOMPLETE" then
		summary.notes[#summary.notes + 1] = "Some items have no verified AMVGG value; totals are partial and the deal cannot be confirmed safely."
	end
	if summary.percent and summary.percent < 0 then
		summary.notes[#summary.notes + 1] = "Your offer is worth more than theirs at AMVGG values."
	end
	if summary.percent and summary.percent >= (self.thresholds.Good or 10) then
		summary.notes[#summary.notes + 1] = "Their side is worth more at AMVGG values, subject to demand and availability."
	end
	return summary
end

function TradeEvaluator:EvaluateListing(listing, options)
	options = options or {}
	local summary = self:Evaluate(listing.requestedItems or {}, listing.offeredItems or {}, options)
	summary.listingId = listing.id
	summary.sellerId = listing.seller
	summary.listingStatus = summary.confidence == "INCOMPLETE" and "INCOMPLETE DATA" or summary.statusLabel
	summary.timestamp = listing.timestamp or options.now or os.time()
	return summary
end

function TradeEvaluator:EvaluateOffer(offer, options)
	options = options or {}
	local summary = self:Evaluate(offer.requestedItems or {}, offer.offeredItems or {}, options)
	summary.offerId = offer.id
	summary.listingId = offer.listingId
	summary.listingStatus = summary.confidence == "INCOMPLETE" and "INCOMPLETE DATA" or summary.statusLabel
	summary.timestamp = offer.createdAt or options.now or os.time()
	return summary
end

return TradeEvaluator
