local TestRunner = require("./TestRunner")

require("./ValueTests")
require("./TradingTests")
require("./TimerTests")

pcall(require, "./IntegrationTests")

TestRunner.finish()
