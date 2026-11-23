local Reactions = {}
Reactions.__index = Reactions

Reactions.MoodByEvent = {
	hello = "ready",
	intro = "calm",
	returning = "ready",
	promise = "calm",
	good_deal = "hopeful",
	excellent_deal = "proud",
	fair_deal = "careful",
	bad_deal = "careful",
	incomplete = "careful",
	offer_received = "focused",
	offer_accepted = "proud",
	offer_declined = "patient",
	offer_expired = "patient",
	listing_created = "hopeful",
	listing_stale = "careful",
	values_updated = "ready",
	values_failed = "worried",
	cache_restored = "careful",
	warning = "worried",
	progress = "proud",
	idle = "patient",
	scan_complete = "focused",
	inventory_imported = "ready",
	session = "ready",
	no_data = "careful",
}

function Reactions.new(options)
	options = options or {}
	return setmetatable({
		personality = options.personality,
	}, Reactions)
end

function Reactions:FromEvaluation(evaluation)
	if not evaluation then
		return "incomplete"
	end
	if evaluation.confidence == "INCOMPLETE" then
		return "incomplete"
	end
	if evaluation.classification == "EXCELLENT" then
		return "excellent_deal"
	elseif evaluation.classification == "GOOD" then
		return "good_deal"
	elseif evaluation.classification == "FAIR" then
		return "fair_deal"
	end
	return "bad_deal"
end

Reactions.EventAliases = {
	trade_confirmed = "offer_accepted",
	trade_accepted = "offer_accepted",
	trade_declined = "offer_declined",
	deal_found = "good_deal",
	values_refresh = "values_updated",
	value_error = "values_failed",
}

function Reactions:React(event, ctx)
	if not self.personality then
		return nil
	end
	local lineKey = Reactions.EventAliases[event] or event
	local line = self.personality:Pick(lineKey, ctx)
	if not line then
		return nil
	end
	return {
		event = event,
		lineKey = lineKey,
		text = line,
		mood = Reactions.MoodByEvent[lineKey] or "calm",
		context = ctx,
	}
end

return Reactions
