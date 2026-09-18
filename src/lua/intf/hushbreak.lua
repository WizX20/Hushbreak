--[[
hushbreak.lua - VLC interface script that hushes the ad breaks on Triton Digital
(StreamTheWorld) radio streams such as KINK.

Triton publishes a now-playing feed per station with cue events: every song, jingle
and ad spot has a start time and a duration. Hushbreak follows that feed and fades the
VLC volume down while an ad break plays, then fades it back up. Change the volume by
hand during a break and Hushbreak leaves it alone.

The feed publishes each entry only ~50 s after its cue start, which is ~3 s before a
freshly connected VLC plays it. Hushbreak therefore never polls blindly: it knows when
the current entry ends and polls right after, and it wakes up exactly when a spot
starts or ends for the listener.

Run:      vlc --extraintf luaintf --lua-intf hushbreak KINK.pls
Settings: vlc --extraintf luaintf --lua-intf hushbreak \
              --lua-config "hushbreak={duck_percent=60,min_volume=10}" KINK.pls
  duck_percent  how much softer during ads, in percent (60 = 40% of normal)
  min_volume    floor for the ducked volume, in percent of full volume (0)
  delay         seconds a freshly connected VLC lags behind the feed's cue times
                (53 for KINK: 47 s stream buffer + ~6 s VLC buffer)
  feed_lag      seconds between an entry's cue start and its appearance in the feed (50)
  grace         seconds to stay ducked after the last known spot when the feed has not
                confirmed the end of the block (8)
  retry         seconds between polls while the feed is late (2)
  idle          longest pause between polls (60)
  mount         Triton mount name; derived from the stream URL when omitted
  resync        restart the stream on startup so the lag is known (true)
  feed          override the feed URL; "{mount}" is replaced by the mount name

Calibration by ear: the "Hushbreak calibration" extension (View menu) writes a marker
file; this script picks it up and recomputes the delay from what you heard.
See README.md for installation.
]]

local core = require("hushbreak_core")

local settings = {
    duck_percent = 60,
    min_volume = 0,
    delay = 53,
    feed_lag = 50,
    grace = 8,
    retry = 2,
    idle = 60,
    mount = nil,
    resync = true,
    feed = nil,
}
for key, value in pairs(config or {}) do
    settings[key] = value
end

local MARKER_FILE = vlc.config.userdatadir() .. "/hushbreak-marker.txt"
local FADE_STEPS, FADE_STEP_SECONDS = 6, 0.12

local function log(fmt, ...)
    vlc.msg.info("[hushbreak] " .. string.format(fmt, ...))
end

-- VLC's monotonic clock in seconds (mdate is in microseconds).
local function mono()
    return vlc.misc.mdate() / 1000000
end

-- VLC cancels the interface thread when it quits; mwait is where that lands.
local function sleep(seconds)
    vlc.misc.mwait(vlc.misc.mdate() + seconds * 1000000)
end

-- VLC's own file functions handle non-ASCII paths on Windows; plain io is the fallback.
local open_file = (vlc.io and vlc.io.open) or io.open
local function remove_file(path)
    if vlc.io and vlc.io.unlink then
        vlc.io.unlink(path)
    else
        os.remove(path)
    end
end

local function read_url(url)
    local ok, stream = pcall(vlc.stream, url)
    if not ok or not stream then
        return nil
    end
    local parts = {}
    while true do
        local chunk = stream:read(65536)
        if not chunk or #chunk == 0 then
            break
        end
        parts[#parts + 1] = chunk
    end
    return table.concat(parts)
end

-- Playback position of the current input in seconds, or nil when nothing plays.
local function input_position()
    local input = vlc.object.input()
    if not input then
        return nil
    end
    local ok, t = pcall(vlc.var.get, input, "time")
    if not ok or not t then
        return nil
    end
    return t / 1000000
end

-- Restart the current playlist item: a new connection, lag back to the base delay.
local function restart_stream()
    local id = vlc.playlist.current()
    if not id or id < 0 then
        return false
    end
    local go = vlc.playlist.gotoitem or vlc.playlist["goto"]
    go(id)
    return true
end

local function set_volume(level)
    vlc.volume.set(level)
end

local function fade(from, to)
    for _, level in ipairs(core.fade_steps(from, to, FADE_STEPS)) do
        set_volume(level)
        if level ~= to then
            sleep(FADE_STEP_SECONDS)
        end
    end
end

-- The calibration extension writes one line, "<start|end|reconnect> <epoch>". Read and remove it.
local function read_marker()
    local f = open_file(MARKER_FILE, "r")
    if not f then
        return nil
    end
    local line = f:read("*l")
    f:close()
    remove_file(MARKER_FILE)
    return core.parse_marker(line)
end

-- Startup ---------------------------------------------------------------------------

log("Hushbreak %s starting: duck %.0f%%, floor %.0f%%, base delay %.0f s",
    core.VERSION, settings.duck_percent, settings.min_volume, settings.delay)

-- VLC may still be opening the playlist item; give it a moment.
local waited = 0
while not vlc.object.input() and waited < 30 do
    sleep(0.5)
    waited = waited + 0.5
end

local mount = settings.mount
if not mount then
    local item = vlc.input.item()
    mount = item and core.mount_from_uri(item:uri())
    if mount then
        log("mount %s (from the stream URL)", mount)
    else
        log("cannot derive the Triton mount from the stream URL; set mount=... in lua-config")
    end
end
local feed_url
if settings.feed then
    feed_url = settings.feed:gsub("{mount}", mount or "")
elseif mount then
    feed_url = core.feed_url(mount)
end

if settings.resync and (input_position() or 0) > 30 then
    -- The server resumes an existing session where it left off; how far behind that is
    -- cannot be read from VLC. A new session starts at the base delay.
    log("restarting the stream so the lag is known (resync=false to skip)")
    if restart_stream() then
        sleep(4)
    end
end

local base_delay = settings.delay
local drift = core.new_drift(mono(), input_position() or 0)
local reported_delay = -100

local entries = {}
local next_poll_at = 0
local ducked, normal_volume, low_volume, last_title = false, 0, 0, ""

-- Main loop -------------------------------------------------------------------------

while true do
    local position = input_position()
    if not position then
        -- Nothing playing: forget any ducked state, the next input starts clean.
        ducked = false
        sleep(1)
    else
        local now = os.time()
        local delay = base_delay + drift:update(mono(), position)

        if feed_url and now >= next_poll_at then
            local fetched = core.parse_feed(read_url(feed_url))
            if #fetched > 0 then
                entries = fetched
            else
                -- Unreachable, or a valid but empty answer: keep the previous list in use.
                vlc.msg.warn("[hushbreak] feed not reachable")
            end
            next_poll_at = now + core.next_poll(entries, now, settings.feed_lag, settings.retry, settings.idle)
        end

        local action, at = read_marker()
        if action == "reconnect" then
            log("restarting the stream (calibration)")
            restart_stream()
        elseif action == "start" or action == "end" then
            local calibrated = at and core.calibrated_delay(entries, action, at)
            if calibrated then
                -- The new base is what you heard versus cue time; drift starts over from here.
                base_delay = calibrated
                drift:reset(mono(), position)
                delay = base_delay
                log("calibrated on block %s: delay is now %.0f s", action, base_delay)
            else
                vlc.msg.warn("[hushbreak] calibration ignored: the feed shows no ad block yet")
            end
        end

        if math.abs(delay - reported_delay) >= 2 then
            log("delay versus the feed: %.0f s (base %.0f + VLC drift %.0f)", delay, base_delay, delay - base_delay)
            reported_delay = delay
        end

        local stream_now = now - delay
        local spot = core.active_spot(entries, stream_now)
        local volume = math.floor((vlc.volume.get() or 0) + 0.5)

        if spot and not ducked then
            normal_volume = volume
            low_volume = core.ducked_volume(normal_volume, settings.duck_percent, settings.min_volume)
            fade(normal_volume, low_volume)
            ducked = true
            log("ad break: volume %d -> %d (%s)", normal_volume, low_volume, spot.title)
        elseif spot and ducked and spot.title ~= last_title then
            log("  next spot: %s", spot.title)
        elseif ducked and core.block_ended(entries, stream_now, settings.grace) then
            if volume == low_volume then
                fade(low_volume, normal_volume)
                log("ad break over: volume back to %d", normal_volume)
            else
                log("ad break over: volume was changed by hand (%d), leaving it", volume)
            end
            ducked = false
        end
        last_title = spot and spot.title or ""

        -- Wake up for the next poll or spot boundary, but at least once a second so the
        -- calibration marker is noticed promptly.
        local wait = next_poll_at - now
        local transition = core.next_transition(entries, now, delay)
        if transition and transition < wait then
            wait = transition
        end
        sleep(math.max(0.25, math.min(wait, 1)))
    end
end
