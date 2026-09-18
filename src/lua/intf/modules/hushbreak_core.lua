--[[
hushbreak_core.lua - the pure, VLC-independent part of Hushbreak.

Everything in here is plain Lua 5.1+ with no VLC calls, so the test suite can run it
with a stock interpreter. The interface script (lua/intf/hushbreak.lua) does the VLC
side: reading the volume, sleeping, restarting the stream.

Vocabulary used throughout:
  cue time     the timeline of the station's ad-insertion system, as published in
               Triton's now-playing feed (epoch seconds). Every entry has a start and
               a duration, and consecutive entries border on each other.
  feed lag     the feed publishes an entry only ~50 s after its cue start.
  delay        how far the listener is behind cue time: the stream leaves the server
               ~47 s behind cue time and VLC buffers a few seconds more (53 s for a
               fresh connection), plus whatever "drift" VLC has picked up since.
  drift        extra delay VLC accumulates over a session: stalls and pauses. The
               server resumes where it left off, so VLC never catches up again.
]]

local M = {}

M.VERSION = "0.1.1"

-- VLC's volume scale: 0..512, where 256 is 100%.
M.FULL_VOLUME = 256

-- Feed parsing --------------------------------------------------------------------

local function cue_property(info, name)
    return info:match('<property name="' .. name .. '"><!%[CDATA%[(.-)%]%]></property>')
end

--- Parse Triton's now-playing XML into entries, newest first (the feed's order).
-- Each entry: { kind = "ad"|"track", ad_type = "break"|"insert"|nil,
--               start, stop (epoch seconds), title }.
-- An 'insert' event is the "COMMERCIAL INSERT TRIGGER" that sits at the end of Triton's
-- spots; it has no duration and, since commercials go on after it, marks nothing that
-- the ducking can use. A 'break' is a real spot with a duration.
function M.parse_feed(xml)
    local entries = {}
    if type(xml) ~= "string" then
        return entries
    end
    for kind, info in xml:gmatch('<nowplaying%-info[^>]-type="(%a+)"[^>]*>(.-)</nowplaying%-info>') do
        local start = tonumber(cue_property(info, "cue_time_start"))
        if start then
            start = start / 1000
            local duration = tonumber(cue_property(info, "cue_time_duration")) or 0
            entries[#entries + 1] = {
                kind = kind,
                ad_type = cue_property(info, "ad_type"),
                start = start,
                stop = start + duration / 1000,
                title = cue_property(info, "cue_title") or "",
            }
        end
    end
    return entries
end

--- The real ad spots (with a duration) among the entries.
function M.spots(entries)
    local spots = {}
    for _, e in ipairs(entries) do
        if e.kind == "ad" and e.ad_type == "break" then
            spots[#spots + 1] = e
        end
    end
    return spots
end

-- Spots are contiguous but leave gaps of a few milliseconds; this margin bridges them.
M.SPOT_MARGIN = 0.5

--- The spot playing at `stream_now` (a cue time), or nil.
function M.active_spot(entries, stream_now)
    for _, spot in ipairs(M.spots(entries)) do
        if stream_now >= spot.start and stream_now < spot.stop + M.SPOT_MARGIN then
            return spot
        end
    end
    return nil
end

--- End of the last known spot (cue time), or nil without spots.
function M.last_spot_end(entries)
    local last = nil
    for _, spot in ipairs(M.spots(entries)) do
        if not last or spot.stop > last then
            last = spot.stop
        end
    end
    return last
end

--- True when a titled track (a real song; jingles, news and promos carry no title)
-- started at or after the last known spot. Programme has resumed, whatever the feed
-- says about markers.
function M.song_started_after_spots(entries)
    local last = M.last_spot_end(entries)
    if not last then
        return false
    end
    for _, e in ipairs(entries) do
        if e.kind == "track" and e.title ~= "" and e.start >= last - 1.5 then
            return true
        end
    end
    return false
end

--- Whether ducking should stop. Only when the end of the break is certain: no spot is
-- active, and a titled song has started after the last spot. Without that, stay ducked
-- until `grace` seconds have passed since the last known spot.
--
-- The "COMMERCIAL INSERT TRIGGER" entry (ad_type=insert) that follows the last spot is
-- deliberately not an end marker: it marks the end of Triton's own spots, not of the
-- commercials. In the measured block it was followed by ~80 s of untitled entries the
-- listener heard as commercials, then jingles, and the song came 114 s after the last
-- spot. The next spot is published only ~3 s before it is heard, the feed server stalls
-- for seconds at a time, and a break can hold untitled promo or sponsor segments between
-- two runs of spots - so the grace period is long, and a song that stays ducked a little
-- longer after a missed song entry is the safer error than the volume coming up in the
-- middle of the commercials.
function M.block_ended(entries, stream_now, grace)
    if M.active_spot(entries, stream_now) then
        return false
    end
    local last = M.last_spot_end(entries)
    if not last then
        return true
    end
    if M.song_started_after_spots(entries) then
        return true
    end
    return stream_now >= last + M.SPOT_MARGIN + grace
end

--- Start (cue time) of the ad block containing the newest spot: walk back while the
-- previous spot borders on the next one.
function M.block_start(entries)
    local spots = M.spots(entries)
    table.sort(spots, function(a, b) return a.start > b.start end)
    if #spots == 0 then
        return nil
    end
    local start = spots[1].start
    for _, spot in ipairs(spots) do
        if spot.stop < start - 2 then
            break
        end
        start = spot.start
    end
    return start
end

-- Volume ---------------------------------------------------------------------------

--- The ducked level for a normal volume: `duck_percent` softer, never below
-- `min_volume_percent` of full volume, never above the normal volume.
function M.ducked_volume(normal, duck_percent, min_volume_percent)
    local floor = M.FULL_VOLUME * (min_volume_percent or 0) / 100
    local ducked = normal * (100 - duck_percent) / 100
    ducked = math.max(ducked, floor)
    ducked = math.min(ducked, normal)
    return math.floor(ducked + 0.5)
end

--- Intermediate levels for a fade from one volume to another, ending exactly on `to`.
function M.fade_steps(from, to, steps)
    local levels = {}
    for i = 1, steps do
        levels[i] = math.floor(from + (to - from) * i / steps + 0.5)
    end
    return levels
end

--- Number of steps and the pause between them for a fade that lasts `seconds`:
-- steps of about 120 ms, at least two.
function M.fade_plan(seconds)
    local steps = math.max(2, math.floor(seconds / 0.12 + 0.5))
    return steps, seconds / steps
end

-- Scheduling -----------------------------------------------------------------------

--- Seconds until the feed should be polled again.
-- Every entry carries its duration, so the moment the next entry appears is known:
-- the end of the newest entry plus the feed lag. Poll just after that instead of on a
-- fixed interval. When that moment has passed without a new entry, the feed is late:
-- retry every `retry` seconds. Without entries, poll every `idle` seconds.
function M.next_poll(entries, now, feed_lag, retry, idle)
    local newest = nil
    for _, e in ipairs(entries) do
        if not newest or e.stop > newest then
            newest = e.stop
        end
    end
    if not newest then
        return idle
    end
    local publish_at = newest + feed_lag + 0.3
    if now < publish_at then
        return math.min(publish_at - now, idle)
    end
    return retry
end

--- Seconds until the listener reaches the next spot boundary (a start or an end),
-- or nil when no boundary lies ahead. The interface script wakes up for these so the
-- fade lands on the boundary rather than on the next poll.
function M.next_transition(entries, now, delay)
    local soonest = nil
    for _, spot in ipairs(M.spots(entries)) do
        for _, edge in ipairs({ spot.start, spot.stop + M.SPOT_MARGIN }) do
            local at = edge + delay
            if at > now and (not soonest or at < soonest) then
                soonest = at
            end
        end
    end
    return soonest and (soonest - now) or nil
end

-- Drift ----------------------------------------------------------------------------

--- Tracks how far VLC has fallen behind since a reference point, from VLC's own
-- monotonic clock and the playback position: (elapsed wall time) - (advance of the
-- position). A position that jumps back means the stream restarted, which resets the
-- reference: a new connection starts at the base delay again.
local Drift = {}
Drift.__index = Drift

function M.new_drift(mono, position)
    return setmetatable({ base_mono = mono, base_position = position, last_position = position }, Drift)
end

function Drift:reset(mono, position)
    self.base_mono, self.base_position, self.last_position = mono, position, position
end

--- Returns the drift in seconds (never negative).
function Drift:update(mono, position)
    if position < self.last_position - 5 then
        self:reset(mono, position)
    end
    self.last_position = position
    return math.max(0, (mono - self.base_mono) - (position - self.base_position))
end

-- Misc -----------------------------------------------------------------------------

--- Triton mount name from a StreamTheWorld URL: ".../KINK_SC" -> "KINK",
-- ".../KINK_DNA_SC" -> "KINK_DNA". Nil for anything else.
function M.mount_from_uri(uri)
    if type(uri) ~= "string" then
        return nil
    end
    local name = uri:match("streamtheworld%.com[:%d]*/([%w_]+)")
    if not name then
        return nil
    end
    return (name:gsub("_SC$", ""))
end

--- The now-playing feed URL for a mount. Without an eventType filter the feed lists
-- ads and tracks both, so the scheduler also knows when the current song ends.
function M.feed_url(mount, count)
    return string.format(
        "https://np.tritondigital.com/public/nowplaying?mountName=%s&numberToFetch=%d",
        mount, count or 8)
end

--- Parse "kind epoch" marker lines written by the calibration extension.
function M.parse_marker(line)
    if type(line) ~= "string" then
        return nil
    end
    local action, at = line:match("^%s*(%a+)%s+(%d+)")
    if not action then
        return nil
    end
    return action:lower(), tonumber(at)
end

--- The delay implied by a calibration mark: the listener heard the block `action`
-- ("start" or "end") at epoch `at`. Nil when the feed has nothing to compare against.
function M.calibrated_delay(entries, action, at)
    local mark
    if action == "start" then
        mark = M.block_start(entries)
    elseif action == "end" then
        mark = M.last_spot_end(entries)
    end
    if not mark then
        return nil
    end
    return math.floor(at - mark + 0.5)
end

return M
