-- Tests for src/lua/extensions/hushbreak_calibrate.lua, run against stand-ins for the
-- parts of VLC's Lua API the extension uses. Run with `lua tests/run.lua`.

local core = require("hushbreak_core")

local root = arg and arg[0] and arg[0]:match("^(.*)[/\\]tests[/\\]run%.lua$") or "."
local SCRIPT = root .. "/src/lua/extensions/hushbreak_calibrate.lua"

-- Load the extension into its own environment holding `vlc`, the way VLC runs it. The
-- functions it defines (descriptor, activate, ...) land in that environment.
local function load_extension(vlc)
    local env = setmetatable({ vlc = vlc }, { __index = _G })
    local setfenv = rawget(_G, "setfenv") -- Lua 5.1 only, what VLC embeds
    local chunk
    if setfenv then
        chunk = assert(loadfile(SCRIPT))
        setfenv(chunk, env)
    else
        local f = assert(io.open(SCRIPT, "rb"))
        local source = f:read("*a")
        f:close()
        chunk = assert(load(source, "@" .. SCRIPT, "t", env))
    end
    chunk()
    return env
end

-- The messages API, the least an opened extension has.
local function vlc_messages()
    local nothing = function() end
    return { msg = { dbg = nothing, info = nothing, warn = nothing, err = nothing } }
end

-- The API once the extension is opened: a user data folder, lua-config, and a dialog
-- whose widgets the test can fill in and whose buttons it can press.
local function vlc_opened(dir, lua_config)
    local widgets, buttons = {}, {}
    local function widget(text)
        local w = { text = text }
        function w.get_text(self) return self.text end
        function w.set_text(self, value) self.text = value end
        widgets[#widgets + 1] = w
        return w
    end
    local vlc = vlc_messages()
    vlc.config = {
        userdatadir = function() return dir end,
        get = function(name) return name == "lua-config" and lua_config or nil end,
    }
    vlc.dialog = function()
        -- A new dialog starts with no widgets: reopening shows fresh inputs.
        for i = #widgets, 1, -1 do
            widgets[i] = nil
        end
        return {
            add_label = function(_, text) return widget(text) end,
            add_text_input = function(_, text) return widget(text) end,
            add_button = function(_, label, fn) buttons[label] = fn; return widget(label) end,
            delete = function() end,
        }
    end
    vlc.widgets, vlc.buttons = widgets, buttons
    return vlc
end

local function temp_dir()
    local path = os.tmpname()
    os.remove(path)
    local windows = package.config:sub(1, 1) == "\\"
    if windows and not path:match("^%a:") then
        path = (os.getenv("TEMP") or ".") .. path
    end
    os.execute((windows and 'mkdir "' or 'mkdir -p "') .. path .. '"')
    return path
end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

local function input_after(vlc, label_text)
    for i, w in ipairs(vlc.widgets) do
        if w.text == label_text then
            return vlc.widgets[i + 1]
        end
    end
    error("no widget after " .. label_text)
end

test("the extension loads without any vlc table, as VLC reads its descriptor at startup", function()
    -- #23: VLC 3 scans extensions with no `vlc` global at all (measured: "attempt to index
    -- global 'vlc' (a nil value)"); an error there makes VLC skip the extension, and no
    -- menu entry appears.
    local ok, env = pcall(load_extension, nil)
    assert_eq(ok, true, tostring(env))
    local d = env.descriptor()
    assert_eq(d.title, "Hushbreak")
    assert_eq(d.version, core.VERSION, "descriptor version follows M.VERSION")
    assert_eq(type(env.activate), "function")
    assert_eq(type(env.deactivate), "function")
end)

test("Apply saves the volume settings and asks the interface to re-read them", function()
    local dir = temp_dir()
    local vlc = vlc_opened(dir, "hushbreak={duck_percent=70}")
    local env = load_extension(vlc)
    env.activate()
    local duck = input_after(vlc, "Softer by (% of the current volume):")
    local floor = input_after(vlc, "Never below (% of full volume):")
    assert_eq(duck.text, "70", "opens with the value from lua-config")
    assert_eq(floor.text, "0", "and the default for the rest")

    duck.text, floor.text = "80", "10 %"
    vlc.buttons["Apply"]()
    -- Written in text mode: CRLF on Windows, which the interface reads either way.
    assert_eq((read(dir .. "/hushbreak-settings.txt"):gsub("\r", "")), "duck_percent=80\nmin_volume=10\n")
    local settings = core.parse_settings(read(dir .. "/hushbreak-settings.txt"))
    assert_eq(settings.duck_percent, 80)
    assert_eq(core.parse_marker(read(dir .. "/hushbreak-marker.txt")), "settings")

    -- Reopened, the dialog shows what was saved, not lua-config.
    env.deactivate()
    env.activate()
    assert_eq(input_after(vlc, "Softer by (% of the current volume):").text, "80")

    os.remove(dir .. "/hushbreak-settings.txt")
    os.remove(dir .. "/hushbreak-marker.txt")
    os.remove(dir)
end)

test("Apply refuses a value outside 0..100 and writes nothing", function()
    local dir = temp_dir()
    local vlc = vlc_opened(dir, nil)
    local env = load_extension(vlc)
    env.activate()
    input_after(vlc, "Softer by (% of the current volume):").text = "150"
    vlc.buttons["Apply"]()
    assert_eq(read(dir .. "/hushbreak-settings.txt"), nil)
    assert_eq(read(dir .. "/hushbreak-marker.txt"), nil)
    os.remove(dir)
end)

test("the calibration buttons write a marker the interface can parse", function()
    local dir = temp_dir()
    local vlc = vlc_opened(dir, nil)
    local env = load_extension(vlc)
    env.activate()
    vlc.buttons["Music is back now"]()
    local action, at = core.parse_marker(read(dir .. "/hushbreak-marker.txt"))
    assert_eq(action, "end")
    assert_eq(math.abs(at - os.time()) <= 2, true, "stamped with the time of the press")
    os.remove(dir .. "/hushbreak-marker.txt")
    os.remove(dir)
end)
