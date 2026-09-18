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
  grace         seconds to stay ducked after the last known spot when the feed has
                not shown a song yet (180). Commercials go on after Triton's last
                spot (measured: 114 s until the song, most of it untitled entries),
                breaks can hold promo segments between two runs of spots, and the
                feed server stalls for seconds at a time; a long grace keeps the
                volume from coming up in the middle of the commercials.
  fade_down     seconds for the fade at the start of a break (0.7)
  fade_up       seconds for the fade back up when the break is over (3)
  retry         seconds between polls while the feed is late (2)
  idle          longest pause between polls (60)
  mount         Triton mount name; derived from the stream URL when omitted
  resync        restart a stream that was already playing when Hushbreak got to it,
                so the lag is known (true)
  feed          override the feed URL; "{mount}" is replaced by the mount name

Calibration by ear: the "Hushbreak calibration" extension (View menu) writes a marker
file when you hear the first commercial or the first song after the break; this script
picks it up and recomputes the delay from the feed.
See README.md for installation.
]]

local core = require("hushbreak_core")

local settings = {
    duck_percent = 60,
    min_volume = 0,
    delay = 53,
    feed_lag = 50,
    grace = 180,
    fade_down = 0.7,
    fade_up = 3,
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

local function fade(from, to, seconds)
    local steps, pause = core.fade_plan(seconds)
    for i, level in ipairs(core.fade_steps(from, to, steps)) do
        set_volume(level)
        if i < steps then
            sleep(pause)
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

local base_delay = settings.delay
local drift = core.new_drift(mono(), 0)
local reported_delay = -100

-- What is playing: the item's URL, the Triton mount and feed URL derived from it, and
-- whether the drift reference still has to be taken on the new input.
local current_uri, mount, feed_url, fresh_input = nil, nil, nil, false
local entries = {}
local next_poll_at = 0
local ducked, normal_volume, low_volume, last_title = false, 0, 0, ""

-- Follow the item VLC plays: derive the mount and the feed URL from its URL, drop the
-- entries of another station, and restart a stream that was already playing when
-- Hushbreak got to it. Called whenever the playing item changes, so a stream opened
-- long after VLC started, or a station change, is picked up too.
local function attach(uri)
    local new_mount = settings.mount or core.mount_from_uri(uri)
    if new_mount ~= mount then
        entries, next_poll_at, last_title = {}, 0, ""
    end
    mount = new_mount
    if settings.feed then
        feed_url = settings.feed:gsub("{mount}", mount or "")
    elseif mount then
        feed_url = core.feed_url(mount)
    else
        feed_url = nil
    end
    fresh_input = true
    if mount then
        log("mount %s (%s)", mount, settings.mount and "from lua-config" or "from the stream URL")
    else
        log("not a StreamTheWorld URL, nothing to do until the next item "
            .. "(set mount=... in lua-config to force one): %s", uri)
    end
    if feed_url and settings.resync and (input_position() or 0) > 30 then
        -- The server resumes an existing session where it left off; how far behind that is
        -- cannot be read from VLC. A new session starts at the base delay.
        log("restarting the stream so the lag is known (resync=false to skip)")
        restart_stream()
    end
end

-- Bring the volume back up after a break, over `seconds`, unless it was changed by
-- hand meanwhile; then forget the ducked state.
local function unduck(reason, seconds)
    local volume = math.floor((vlc.volume.get() or 0) + 0.5)
    if volume == low_volume then
        fade(low_volume, normal_volume, seconds)
        log("%s: volume back to %d", reason, normal_volume)
    else
        log("%s: volume was changed by hand (%d), leaving it", reason, volume)
    end
    ducked = false
end

-- Main loop -------------------------------------------------------------------------

while true do
    local item = vlc.input.item()
    local uri = item and item:uri() or nil
    if uri ~= current_uri then
        if ducked then
            unduck("stream changed during an ad break", 0)
        end
        current_uri = uri
        if uri then
            attach(uri)
        end
    end

    local position = input_position()
    if not position then
        -- Nothing playing. VLC's volume outlives the input, so a ducked level would
        -- carry over into the next input and the next break would duck from there.
        if ducked then
            unduck("input gone during an ad break", 0)
        end
        sleep(1)
    elseif not feed_url then
        -- Not a stream this script knows; wait for the next item.
        sleep(1)
    else
        if fresh_input then
            -- A new connection starts at the base delay; drift is counted from here.
            drift:reset(mono(), position)
            fresh_input = false
        end
        local now = os.time()
        local delay = base_delay + drift:update(mono(), position)

        if feed_url and now >= next_poll_at then
            local fetched = core.parse_feed(read_url(feed_url))
            if #fetched > 0 then
                -- The feed is a short window; keep a block's spots until well past the
                -- grace period, they scroll out while its tail is still playing.
                entries = core.merge_entries(entries, fetched, now - delay - settings.grace - 60)
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
            local calibrated, reason = core.calibrated_delay(entries, action, at or 0, now)
            if calibrated then
                -- The new base is what you heard versus cue time; drift starts over from here.
                base_delay = calibrated
                drift:reset(mono(), position)
                delay = base_delay
                log("calibrated on block %s: delay is now %.0f s", action, base_delay)
            else
                vlc.msg.warn("[hushbreak] calibration ignored: " .. reason)
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
            fade(normal_volume, low_volume, settings.fade_down)
            ducked = true
            log("ad break: volume %d -> %d (%s)", normal_volume, low_volume, spot.title)
        elseif spot and ducked and spot.title ~= last_title then
            log("  next spot: %s", spot.title)
        elseif ducked and core.block_ended(entries, stream_now, settings.grace, settings.fade_up) then
            unduck("ad break over", settings.fade_up)
        end
        last_title = spot and spot.title or ""

        -- Wake up for the next poll or boundary (a spot edge, or the fade-up before the
        -- song), but at least once a second so the calibration marker is noticed promptly.
        local wait = next_poll_at - now
        local transition = core.next_transition(entries, now, delay, settings.fade_up)
        if transition and transition < wait then
            wait = transition
        end
        sleep(math.max(0.25, math.min(wait, 1)))
    end
end
