-- Minimal test runner: `lua tests/run.lua [pattern]` from the repository root.
-- Loads every tests/*_test.lua, runs the cases they register with `test(name, fn)`,
-- prints one line per case and exits non-zero when any case fails. No dependencies,
-- so the suite runs on any Lua from 5.1 up, including the one inside VLC.

local root = arg[0]:match("^(.*)[/\\]tests[/\\]run%.lua$") or "."
package.path = table.concat({
    root .. "/src/lua/intf/modules/?.lua",
    root .. "/tests/?.lua",
    package.path,
}, ";")

local filter = arg[1]
local passed, failed = 0, 0
local cases = {}

function test(name, fn) -- luacheck: ignore 111 (global by design: the test files use it)
    cases[#cases + 1] = { name = name, fn = fn }
end

local function fmt(v)
    if type(v) == "string" then
        return string.format("%q", v)
    end
    return tostring(v)
end

function assert_eq(actual, expected, what) -- luacheck: ignore 111
    if actual ~= expected then
        error(string.format("%sexpected %s, got %s", what and (what .. ": ") or "", fmt(expected), fmt(actual)), 2)
    end
end

function assert_near(actual, expected, tolerance, what) -- luacheck: ignore 111
    if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
        error(string.format("%sexpected %s ± %s, got %s",
            what and (what .. ": ") or "", fmt(expected), fmt(tolerance), fmt(actual)), 2)
    end
end

function read_fixture(name) -- luacheck: ignore 111
    local f = assert(io.open(root .. "/tests/fixtures/" .. name, "rb"))
    local body = f:read("*a")
    f:close()
    return body
end

local files = {}
local windows = package.config:sub(1, 1) == "\\"
local list = io.popen(windows and ('dir /b "' .. root:gsub("/", "\\") .. '\\tests"') or ('ls "' .. root .. '/tests"'))
if list then
    for line in list:lines() do
        if line:match("_test%.lua$") then
            files[#files + 1] = line
        end
    end
    list:close()
end
table.sort(files)

for _, file in ipairs(files) do
    cases = {}
    dofile(root .. "/tests/" .. file)
    for _, case in ipairs(cases) do
        if not filter or case.name:find(filter, 1, true) then
            local ok, err = pcall(case.fn)
            if ok then
                passed = passed + 1
                print("  ok    " .. case.name)
            else
                failed = failed + 1
                print("  FAIL  " .. case.name .. "\n        " .. tostring(err))
            end
        end
    end
end

print(string.format("\n%d passed, %d failed (%s)", passed, failed, _VERSION))
os.exit(failed == 0 and 0 or 1)
