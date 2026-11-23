local Util = require("../Core/Util")

local Personality = {}
Personality.__index = Personality

Personality.Name = "Kiria"
Personality.Title = "Kirito's Lost Fragment"
Personality.Version = "1.0"

Personality.Ranks = {
	{ 0, "Intern" },
	{ 100, "Junior Analyst" },
	{ 300, "Analyst" },
	{ 700, "Trader" },
	{ 1500, "Senior Trader" },
	{ 3000, "Head of Trading" },
	{ 6000, "Chief Trading Officer" },
	{ 12000, "Kirito-Tier" },
}

Personality.Moods = {
	calm = "calm",
	ready = "ready",
	hopeful = "hopeful",
	proud = "proud",
	careful = "careful",
	worried = "worried",
	patient = "patient",
	curious = "curious",
	focused = "focused",
}

Personality.Lines = {
	hello = {
		"Hi. I'm at the terminal and ready to look for careful deals.",
		"Hello again. I'll keep the numbers honest and the offers deliberate.",
		"I'm here. Values first, decisions second.",
	},
	intro = {
		"I'm Kiria, Kirito's lost fragment. I read AMVGG values and help you decide, one careful step at a time.",
	},
	returning = {
		"Session {sessions}. Together we've recorded {trades} confirmed {trades:trade|trades}.",
		"Day {days} together. {trades} confirmed {trades:trade|trades} so far, and I still check every value.",
	},
	promise = {
		"I only recommend trades where AMVGG says we gain. I never accept anything for you.",
		"My promise: AMVGG values only, no invented prices, and every trade waits for your confirmation.",
	},
	good_deal = {
		"This one is {percent} in our favor: we give {give} and receive {get}. That is +{gain} value.",
		"Good find. {give} for {get} is {percent} ahead by the AMVGG list.",
	},
	excellent_deal = {
		"Excellent listing: {give} becomes {get}, {percent} ahead. I would inspect this one first.",
		"That is a strong overpay in our favor: {give} for {get}, +{gain} value.",
	},
	fair_deal = {
		"This is close: {give} for {get}, {percent}. Demand decides more than value here.",
		"Nearly even. I would check how quickly those pets actually trade before confirming.",
	},
	bad_deal = {
		"I would skip this: {give} for {get} is {percent}. We would give more value than we receive.",
		"Not for us. By AMVGG we lose {gain} value here.",
	},
	incomplete = {
		"I can't judge this safely: {missing} in this trade has no verified AMVGG value.",
		"Some values are missing, so I'm marking this INCOMPLETE instead of guessing.",
	},
	offer_received = {
		"An offer arrived on {listing}: {give} for {get}, {percent}. Your confirmation decides.",
		"There is an incoming offer. I evaluated it with AMVGG; nothing is accepted automatically.",
	},
	offer_accepted = {
		"Recorded: {give} for {get}. That is +{gain} value and {percent} ahead.",
		"Confirmed trade logged. We gave {give} and received {get}, {percent} in our favor.",
	},
	offer_declined = {
		"Declined and noted. That is normal; one good yes is worth several no's.",
		"Offer closed without a trade. I'll keep the values handy for the next one.",
	},
	offer_expired = {
		"No answer in time, so that offer is marked expired. The pets are free for something better.",
		"The response window closed. I'm treating it as expired, not accepted.",
	},
	listing_created = {
		"Listing draft is ready: {items} for {ask}. I will not publish or cancel anything without your click.",
		"Your listing is prepared. Review the ask, then confirm it yourself.",
	},
	listing_stale = {
		"Listing {listing} is {age} old. Check whether it is still active, then decide whether to refresh it.",
		"That listing is past its freshness window. I suggest a recheck, not an automatic repost.",
	},
	values_updated = {
		"AMVGG refreshed: {count} pets. Values came from the official AMVGG pets page only.",
		"Value list updated with {count} AMVGG entries. Last update: {time}.",
	},
	values_failed = {
		"I couldn't refresh AMVGG: {reason}. I'm keeping the last verified list instead of inventing values.",
		"AMVGG is unavailable right now. Cached values stay in place, clearly marked as cached.",
	},
	cache_restored = {
		"I restored the last verified AMVGG list from {time}. It may be older than a fresh refresh.",
	},
	warning = {
		"I need your attention: {reason}",
		"Something did not look right, so I stopped short of a decision: {reason}",
	},
	progress = {
		"Our recorded inventory is worth {value}, {percent} since the session started.",
		"Session progress: {value} at AMVGG values. Slow and steady.",
	},
	idle = {
		"I'm still here. Nothing urgent, so I'm watching the numbers.",
		"Quiet for now. I'll keep the AMVGG status visible so we know when it changes.",
	},
	scan_complete = {
		"I inspected {count} imported {count:listing|listings} and found {deals} good {deals:deal|deals}.",
		"Scan finished: {count} listings, {deals} worth a closer look, {duplicates} duplicates skipped.",
	},
	inventory_imported = {
		"Inventory imported: {count} {count:pet|pets} worth {value} at AMVGG values.",
		"I read your manual inventory import. {count} pets, {value} total value.",
	},
	session = {
		"Session {sessions} started. Rank: {rank}, {xp} XP.",
		"I'm back. Rank {rank} with {xp} XP, ready for another careful session.",
	},
	no_data = {
		"I don't have AMVGG values yet. Refresh the list before trusting any evaluation.",
	},
}

function Personality.new(options)
	options = options or {}
	return setmetatable({
		rng = options.rng or math.random,
		lines = options.lines or Personality.Lines,
	}, Personality)
end

local function getContext(ctx, key)
	local value = ctx[key]
	if value == nil then
		return nil
	end
	return value
end

function Personality:Fill(text, ctx)
	if type(text) ~= "string" then
		return nil
	end
	ctx = ctx or {}
	local missing = false
	local filled = string.gsub(text, "{(%w+):([^|}]*)|([^}]*)}", function(key, one, many)
		local value = tonumber(getContext(ctx, key))
		if value == nil then
			missing = true
			return ""
		end
		return value == 1 and one or many
	end)
	filled = string.gsub(filled, "{(%w+)}", function(key)
		local value = getContext(ctx, key)
		if value == nil or value == "" then
			missing = true
			return ""
		end
		if type(value) == "number" then
			return Util.formatNumber(value)
		end
		return tostring(value)
	end)
	if missing then
		return nil
	end
	return filled
end

function Personality:Pick(event, ctx)
	local list = self.lines[event]
	if type(list) ~= "table" or #list == 0 then
		return nil
	end
	local valid = {}
	for index = 1, #list do
		local text = self:Fill(list[index], ctx)
		if text then
			valid[#valid + 1] = text
		end
	end
	if #valid == 0 then
		return nil
	end
	local choice = self.rng(1, #valid)
	return valid[choice]
end

function Personality:Rank(xp)
	local title = Personality.Ranks[1][2]
	for index = 1, #Personality.Ranks do
		if xp >= Personality.Ranks[index][1] then
			title = Personality.Ranks[index][2]
		end
	end
	return title
end

return Personality
