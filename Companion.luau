local Reactions = require("./Reactions")

local Companion = {}
Companion.__index = Companion

function Companion.new(options)
	options = options or {}
	return setmetatable({
		memory = options.memory,
		reactions = options.reactions or Reactions.new({ personality = options.personality }),
		personality = options.personality,
		bus = options.bus,
		clock = options.clock or os.time,
		messages = {},
		lastMessage = nil,
		maxMessages = tonumber(options.maxMessages) or 50,
	}, Companion)
end

function Companion:Init()
	if self.memory then
		local ok = self.memory:Load()
		if not ok then
			self.memory:Save()
		end
	end
	return self:Stats()
end

function Companion:_Publish(message)
	self.lastMessage = message
	self.messages[#self.messages + 1] = message
	while #self.messages > self.maxMessages do
		table.remove(self.messages, 1)
	end
	if self.bus then
		self.bus:Emit("kiria:message", message)
	end
	return message
end

function Companion:StartSession(context)
	local info = {}
	if self.memory then
		info = self.memory:StartSession()
	end
	local ctx = {
		sessions = info.sessions or 1,
		days = info.days or 1,
		trades = self.memory and self.memory.data.trades or 0,
		rank = self.memory and self.memory:Rank() or "Intern",
		xp = self.memory and self.memory.data.xp or 0,
		dry = context and context.dry,
	}
	local reaction = self.reactions:React(info.sessions and info.sessions > 1 and "returning" or "intro", ctx)
	local hello = self.reactions:React("hello", ctx)
	local promise = self.reactions:React("promise", ctx)
	local parts = {}
	if hello then
		parts[#parts + 1] = hello.text
	end
	if reaction then
		parts[#parts + 1] = reaction.text
	end
	if promise then
		parts[#parts + 1] = promise.text
	end
	local message = self:_Publish({
		event = "start",
		text = table.concat(parts, " "),
		mood = "ready",
		at = self.clock(),
		rank = ctx.rank,
		xp = ctx.xp,
	})
	if self.memory then
		self.memory:Save()
	end
	return message
end

function Companion:React(event, ctx)
	ctx = ctx or {}
	local reaction = self.reactions:React(event, ctx)
	if not reaction then
		return nil
	end
	local rankBefore = self.memory and self.memory:Rank() or nil
	local meta = {}
	if self.memory then
		if event == "trade_confirmed" then
			meta = self.memory:RecordTrade(ctx.gain, ctx.percent)
		elseif event == "neon" then
			self.memory:RecordNeon()
		elseif event == "mega" then
			self.memory:RecordMega()
		elseif event == "offer_rate" and ctx.rate then
			self.memory:RecordOfferRate(ctx.rate)
		end
		self.memory:Save()
	end
	local rankAfter = self.memory and self.memory:Rank() or nil
	local promoted = rankBefore and rankAfter and rankBefore ~= rankAfter
	local message = {
		event = event,
		text = reaction.text,
		mood = reaction.mood,
		at = self.clock(),
		rank = rankAfter,
		xp = self.memory and self.memory.data.xp or 0,
		meta = meta,
		promoted = promoted or false,
	}
	self:_Publish(message)
	if promoted and self.bus then
		self.bus:Emit("kiria:promotion", { rank = rankAfter, previous = rankBefore })
	end
	return message
end

function Companion:Stats()
	if not self.memory then
		return { rank = "Intern", xp = 0 }
	end
	return self.memory:Stats()
end

function Companion:History()
	return self.messages
end

return Companion
