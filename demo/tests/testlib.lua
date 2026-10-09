-- A small test library for the Qt6 Lua bindings (no external dependencies).
--
--   local T = require("testlib")
--   T.test("QPoint: manhattan_length", function()
--       T.eq(qt6.QPoint(3, -4):manhattan_length(), 7)
--   end)
--   T.run()   -- last line of the file; raises an error if any test failed
--
-- Environment variables:
--   QT6_TEST_VERBOSE=1       print a line for every passing test as well
--   QT6_TEST_FILTER=<text>   only run tests whose name contains <text> (plain match)

local T = {}

--- true when QT6_TEST_VERBOSE is set to something other than an empty string
local function env_flag(name)
    local value = os.getenv(name)
    return value ~= nil and value ~= ""
end
T.verbose = env_flag("QT6_TEST_VERBOSE")

-- Unbuffered, so the output up to a crash is not lost if a binding takes the process down
io.stdout:setvbuf("no")

local tests = {}
local cleanups

local function fail(message)
    -- level 3: skip `fail` and the assertion helper, point at the test's line
    error(message, 3)
end

local function show(value, seen)
    if type(value) == "number" then
        if math.type(value) == "integer" then return tostring(value) end
        return string.format("%.9g", value)
    elseif type(value) == "string" then
        return string.format("%q", value)
    elseif type(value) == "table" then
        seen = seen or {}
        if seen[value] then return "{...}" end
        seen[value] = true
        local items, keys = {}, {}
        for k in pairs(value) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            local key = (math.type(k) == "integer" and #items + 1 == k) and "" or (tostring(k) .. "=")
            items[#items + 1] = key .. show(value[k], seen)
        end
        return "{" .. table.concat(items, ", ") .. "}"
    end
    return tostring(value)
end

--- Register a test case.
function T.test(name, fn)
    tests[#tests + 1] = { name = name, fn = fn }
end

--- Run `fn` after the current test, whether it passed or not. Cleanups run last-in
--- first-out; use them to delete what a test created before Lua collects it.
function T.cleanup(fn)
    cleanups[#cleanups + 1] = fn
end

function T.ok(condition, message)
    if not condition then
        fail(message or "expected a truthy value, got " .. show(condition))
    end
end

function T.eq(actual, expected, message)
    if actual ~= expected then
        fail(string.format("%sexpected %s, got %s", message and (message .. ": ") or "", show(expected), show(actual)))
    end
end

function T.ne(actual, unexpected, message)
    if actual == unexpected then
        fail(string.format("%sdid not expect %s", message and (message .. ": ") or "", show(actual)))
    end
end

function T.near(actual, expected, tolerance, message)
    tolerance = tolerance or 1e-5
    if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
        fail(string.format("%sexpected %s +/- %s, got %s", message and (message .. ": ") or "", show(expected), show(tolerance), show(actual)))
    end
end

function T.is_nil(value, message)
    if value ~= nil then
        fail(string.format("%sexpected nil, got %s", message and (message .. ": ") or "", show(value)))
    end
end

function T.type_is(value, expected, message)
    if type(value) ~= expected then
        fail(string.format("%sexpected a %s, got a %s", message and (message .. ": ") or "", expected, type(value)))
    end
end

local function deep_equal(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

--- Structural comparison of two tables (sequences and dictionaries).
function T.same(actual, expected, message)
    if not deep_equal(actual, expected) then
        fail(string.format("%sexpected %s, got %s", message and (message .. ": ") or "", show(expected), show(actual)))
    end
end

--- Assert that the sequence `list` holds `value`.
function T.contains(list, value, message)
    for _, item in ipairs(list) do
        if item == value then return end
    end
    fail(string.format("%sexpected %s to contain %s", message and (message .. ": ") or "", show(list), show(value)))
end

--- Assert that calling `fn` raises an error whose message contains `pattern` (plain text).
function T.throws(fn, pattern)
    local ok, err = pcall(fn)
    if ok then
        fail("expected an error, but the call succeeded")
    end
    if pattern and not tostring(err):find(pattern, 1, true) then
        fail(string.format("expected an error containing %s, got %s", show(pattern), show(tostring(err))))
    end
end

--- Compare a point or size-like object: T.xy(point, x, y).
function T.xy(object, x, y, tolerance)
    tolerance = tolerance or 1e-9
    local ax, ay = object:x(), object:y()
    if math.abs(ax - x) > tolerance or math.abs(ay - y) > tolerance then
        fail(string.format("expected (%s, %s), got (%s, %s)", show(x), show(y), show(ax), show(ay)))
    end
end

--- Compare a QRect/QRectF: T.rect(r, x, y, width, height).
function T.rect(r, x, y, w, h, tolerance)
    tolerance = tolerance or 1e-9
    local ax, ay, aw, ah = r:x(), r:y(), r:width(), r:height()
    if math.abs(ax - x) > tolerance or math.abs(ay - y) > tolerance
        or math.abs(aw - w) > tolerance or math.abs(ah - h) > tolerance then
        fail(string.format("expected rect (%s, %s, %s, %s), got (%s, %s, %s, %s)",
            show(x), show(y), show(w), show(h), show(ax), show(ay), show(aw), show(ah)))
    end
end

--- Run `fn` for as long as the event loop needs to deliver what it started: processes events until
--- `condition()` is true or `timeout_ms` has passed. Returns whether the condition became true.
function T.wait_for(condition, timeout_ms)
    timeout_ms = timeout_ms or 2000
    local clock = qt6.QElapsedTimer()
    clock:start()
    while not condition() do
        if clock:elapsed() > timeout_ms then return false end
        qt6.QCoreApplication.process_events()
        qt6.QThread.msleep(1)
    end
    return true
end

--- Run every registered test, print a summary and raise an error if any failed.
function T.run()
    local verbose = T.verbose
    local filter = os.getenv("QT6_TEST_FILTER")
    if filter == "" then filter = nil end
    local failures = {}
    if filter then
        local selected = {}
        for _, case in ipairs(tests) do
            if case.name:find(filter, 1, true) then selected[#selected + 1] = case end
        end
        tests = selected
    end
    for _, case in ipairs(tests) do
        cleanups = {}
        if verbose then io.write("  ...   " .. case.name .. "\r") end
        local ok, err = pcall(case.fn)
        for i = #cleanups, 1, -1 do
            local cleaned, cleanup_err = pcall(cleanups[i])
            if not cleaned and ok then
                ok, err = false, "cleanup failed: " .. tostring(cleanup_err)
            end
        end
        cleanups = nil
        collectgarbage()
        if ok then
            if verbose then print("  ok    " .. case.name .. "      ") end
        else
            failures[#failures + 1] = case.name
            print("  FAIL  " .. case.name .. "\n        " .. tostring(err):gsub("\n", "\n        "))
        end
    end
    local total = #tests
    print(string.format("%d tests, %d passed, %d failed", total, total - #failures, #failures))
    tests = {}
    if #failures > 0 then
        error(string.format("%d of %d tests failed", #failures, total), 0)
    end
end

return T
