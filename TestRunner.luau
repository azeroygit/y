local TestRunner = {}

TestRunner.passed = 0
TestRunner.failed = 0
TestRunner.suites = 0
TestRunner.currentSuite = nil
TestRunner.failures = {}

function TestRunner.describe(name, handler)
	TestRunner.suites = TestRunner.suites + 1
	TestRunner.currentSuite = name
	print("")
	print("[suite] " .. name)
	local ok, err = pcall(handler)
	if not ok then
		TestRunner.failed = TestRunner.failed + 1
		TestRunner.failures[#TestRunner.failures + 1] = "suite crashed: " .. name .. ": " .. tostring(err)
		print("  [FAIL] suite crashed: " .. tostring(err))
	end
end

function TestRunner.it(name, handler)
	local ok, err = pcall(handler)
	if ok then
		TestRunner.passed = TestRunner.passed + 1
		print("  [pass] " .. name)
	else
		TestRunner.failed = TestRunner.failed + 1
		local message = tostring(err)
		TestRunner.failures[#TestRunner.failures + 1] = name .. ": " .. message
		print("  [FAIL] " .. name .. " -> " .. message)
	end
end

local function fail(message, level)
	error(message or "assertion failed", (level or 1) + 1)
end

function TestRunner.eq(actual, expected, message)
	if actual ~= expected then
		fail(string.format("%s (expected %s, got %s)", message or "values differ", tostring(expected), tostring(actual)))
	end
end

function TestRunner.truthy(value, message)
	if not value then
		fail(message or "expected truthy value")
	end
end

function TestRunner.falsy(value, message)
	if value then
		fail(message or "expected falsy value")
	end
end

function TestRunner.near(actual, expected, tolerance, message)
	local delta = math.abs((tonumber(actual) or 0) - (tonumber(expected) or 0))
	if delta > (tolerance or 0.0001) then
		fail(string.format("%s (expected %.6f, got %.6f)", message or "numbers differ", expected, actual))
	end
end

function TestRunner.contains(text, needle, message)
	if type(text) ~= "string" or not string.find(text, needle, 1, true) then
		fail(string.format("%s (missing %q)", message or "substring not found", tostring(needle)))
	end
end

function TestRunner.errors(handler, message)
	local ok = pcall(handler)
	if ok then
		fail(message or "expected function to error")
	end
end

function TestRunner.finish()
	print("")
	print(string.rep("-", 52))
	print(string.format("Tests: %d passed, %d failed, %d suites", TestRunner.passed, TestRunner.failed, TestRunner.suites))
	if TestRunner.failed > 0 then
		print("Failures:")
		for index = 1, #TestRunner.failures do
			print("  - " .. TestRunner.failures[index])
		end
		error(string.format("%d test(s) failed", TestRunner.failed), 0)
	end
	print("All tests passed.")
end

return TestRunner
