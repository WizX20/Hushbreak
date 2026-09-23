--[[
hushbreak_calibrate.lua - the Hushbreak dialog (View menu): the volume during ad breaks,
and three calibration buttons for the Hushbreak interface script - mark the moment you
hear the first commercial of an ad block or the first song after it, or reconnect the
stream.

The extension never touches the volume itself. It writes two files in VLC's user data
folder that the interface script reads: hushbreak-settings.txt (the volume settings,
"key=value" lines, read at every start) and a marker line that tells the running
interface to act on a calibration press or to re-read the settings at once.
See lua/intf/hushbreak.lua.

Nothing in the vlc table may be touched while this file loads. VLC runs every extension
once at startup just to read its descriptor(), and at that point the API is not there
yet (VLC 3, modules/lua/extension.c: the full API is only registered when the extension
is opened) - an error then makes VLC skip the extension without a trace in the menu.
Everything below reaches vlc.* from inside a function.
]]

-- Paths in VLC's user data folder, looked up when needed.
local function data_file(name)
    return vlc.config.userdatadir() .. "/" .. name
end
local function marker_file()
    return data_file("hushbreak-marker.txt")
end
local function settings_file()
    return data_file("hushbreak-settings.txt")
end

-- Defaults of the interface script, shown when neither the settings file nor lua-config
-- says otherwise.
local DEFAULTS = { duck_percent = 60, min_volume = 0 }

local dialog, duck_input, floor_input, settings_status, calibration_status

-- VLC's own file functions handle non-ASCII paths on Windows; plain io/os are the fallback.
local function open_file(path, mode)
    if vlc.io and vlc.io.open then
        return vlc.io.open(path, mode)
    end
    return io.open(path, mode)
end
local function remove_file(path)
    if vlc.io and vlc.io.unlink then
        vlc.io.unlink(path)
    else
        os.remove(path)
    end
end

function descriptor()
    return {
        title = "Hushbreak",
        version = "0.2.0",
        author = "WizX20",
        url = "https://github.com/WizX20/Hushbreak",
        shortdesc = "Hushbreak: volume during ad breaks, calibration",
        description = "Set how much softer the ad breaks play, and tell Hushbreak when you "
            .. "hear an ad block start or the music come back, so it can measure how far "
            .. "your stream lags behind the feed. Requires the Hushbreak interface script "
            .. "to be running.",
        capabilities = {},
    }
end

-- Write `text` to `path` through a temporary name and a rename, so the interface
-- script never reads a half-written file. Returns nil and a message on failure.
local function write_file(path, text)
    local tmp = path .. ".tmp"
    local f, err = open_file(tmp, "w")
    if not f then
        return nil, "Could not write " .. tmp .. ": " .. tostring(err)
    end
    f:write(text)
    f:close()
    remove_file(path)
    local ok, rename_err = os.rename(tmp, path)
    if not ok then
        return nil, "Could not write " .. path .. ": " .. tostring(rename_err)
    end
    return true
end

local function write_marker(action)
    return write_file(marker_file(), action .. " " .. os.time() .. "\n")
end

-- The volume settings as the interface script sees them: the settings file, else the
-- lua-config option, else the defaults.
local function current_settings()
    local values = {}
    for key, value in pairs(DEFAULTS) do
        values[key] = value
    end
    local ok, lua_config = pcall(vlc.config.get, "lua-config")
    lua_config = ok and lua_config or ""
    local hushbreak = lua_config:match("hushbreak%s*=%s*{(.-)}") or ""
    for key in pairs(DEFAULTS) do
        local value = tonumber(hushbreak:match(key .. "%s*=%s*([%d.]+)"))
        if value then
            values[key] = value
        end
    end
    local f = open_file(settings_file(), "r")
    if f then
        for line in f:lines() do
            local key, value = line:match("^%s*([%w_]+)%s*=%s*([%d.]+)%s*$")
            if key and DEFAULTS[key] then
                values[key] = tonumber(value)
            end
        end
        f:close()
    end
    return values
end

-- A whole number from 0 to 100 out of a text input, or nil and a message.
local function percent(widget, what)
    local value = tonumber((widget:get_text() or ""):match("^%s*(%d+)%s*%%?%s*$"))
    if not value or value > 100 then
        return nil, what .. " must be a whole number from 0 to 100."
    end
    return value
end

local function on_apply()
    local duck, err = percent(duck_input, "'Softer by'")
    if not duck then
        settings_status:set_text(err)
        return
    end
    local floor
    floor, err = percent(floor_input, "'Never below'")
    if not floor then
        settings_status:set_text(err)
        return
    end
    local ok
    ok, err = write_file(settings_file(), string.format("duck_percent=%d\nmin_volume=%d\n", duck, floor))
    if not ok then
        settings_status:set_text(err)
        return
    end
    write_marker("settings")
    settings_status:set_text(string.format(
        "Saved: ads play at %d %% of the normal volume, never below %d %% of full volume. "
            .. "Hushbreak applies it now and at every start.", 100 - duck, floor))
    vlc.msg.info(string.format("[hushbreak] settings from the dialog: duck %d%%, floor %d%%", duck, floor))
end

local function mark(action)
    local ok, err = write_marker(action)
    if not ok then
        calibration_status:set_text(err)
        return
    end
    calibration_status:set_text(string.format("Marked '%s' at %s. Hushbreak picks it up within a second.",
        action, os.date("%H:%M:%S")))
    vlc.msg.info("[hushbreak] calibration marker: " .. action)
end

local function on_start()
    mark("start")
end

local function on_end()
    mark("end")
end

local function on_reconnect()
    mark("reconnect")
end

function activate()
    local values = current_settings()
    dialog = vlc.dialog("Hushbreak")
    dialog:add_label("<b>Volume during ad breaks</b>", 1, 1, 3, 1)
    dialog:add_label("Softer by (% of the current volume):", 1, 2, 2, 1)
    duck_input = dialog:add_text_input(string.format("%d", values.duck_percent), 3, 2, 1, 1)
    dialog:add_label("Never below (% of full volume):", 1, 3, 2, 1)
    floor_input = dialog:add_text_input(string.format("%d", values.min_volume), 3, 3, 1, 1)
    dialog:add_button("Apply", on_apply, 3, 4, 1, 1)
    settings_status = dialog:add_label("60 = the ads play at 40 % of your volume. The floor keeps "
        .. "a quiet listening level from dropping to nothing.", 1, 5, 3, 1)
    dialog:add_label("<b>Calibration</b> - press a button at the exact moment you hear it:", 1, 6, 3, 1)
    dialog:add_button("First commercial starts now", on_start, 1, 7, 1, 1)
    dialog:add_button("Music is back now", on_end, 2, 7, 1, 1)
    dialog:add_button("Reconnect stream", on_reconnect, 3, 7, 1, 1)
    calibration_status = dialog:add_label("'Music is back' is the most reliable: press it when the first "
        .. "song after the commercials and jingles starts.", 1, 8, 3, 1)
end

function deactivate()
    if dialog then
        dialog:delete()
        dialog = nil
    end
end

function close()
    vlc.deactivate()
end
