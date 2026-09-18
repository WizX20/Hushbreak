--[[
hushbreak_calibrate.lua - VLC extension with three buttons for the Hushbreak
interface script: mark the moment an ad block starts or ends as you hear it, or
reconnect the stream.

The extension only writes a marker file; the interface script reads it on its next
loop and recomputes the delay from the feed. See lua/intf/hushbreak.lua.
]]

local MARKER_FILE = vlc.config.userdatadir() .. "/hushbreak-marker.txt"

local dialog, status

function descriptor()
    return {
        title = "Hushbreak calibration",
        version = "0.1.0",
        author = "WizX20",
        url = "https://github.com/WizX20/Hushbreak",
        shortdesc = "Hushbreak calibration",
        description = "Tell Hushbreak when you hear an ad block start or end, so it can "
            .. "measure how far your stream lags behind the feed. Requires the Hushbreak "
            .. "interface script to be running.",
        capabilities = {},
    }
end

local function write_marker(action)
    local f, err = io.open(MARKER_FILE, "w")
    if not f then
        status:set_text("Could not write " .. MARKER_FILE .. ": " .. tostring(err))
        return
    end
    f:write(action .. " " .. os.time() .. "\n")
    f:close()
    status:set_text(string.format("Marked '%s' at %s. Hushbreak picks it up within a second.",
        action, os.date("%H:%M:%S")))
    vlc.msg.info("[hushbreak] calibration marker: " .. action)
end

local function on_start()
    write_marker("start")
end

local function on_end()
    write_marker("end")
end

local function on_reconnect()
    write_marker("reconnect")
end

function activate()
    dialog = vlc.dialog("Hushbreak calibration")
    dialog:add_label("Press a button at the exact moment you hear it:", 1, 1, 3, 1)
    dialog:add_button("Ad block starts now", on_start, 1, 2, 1, 1)
    dialog:add_button("Ad block ends now", on_end, 2, 2, 1, 1)
    dialog:add_button("Reconnect stream", on_reconnect, 3, 2, 1, 1)
    status = dialog:add_label("The 'ends now' button is the most reliable: by then the feed "
        .. "always knows the whole block.", 1, 3, 3, 1)
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
