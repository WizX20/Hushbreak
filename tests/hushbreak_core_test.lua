-- Tests for src/lua/intf/modules/hushbreak_core.lua. Run with `lua tests/run.lua`.
-- The fixture is a real answer of Triton's now-playing feed for KINK (2026-09-18,
-- 14 entries): four ad spots, the "commercial insert" trigger, ~80 s of untitled entries
-- (heard as commercials), four jingles, and two songs.

local core = require("hushbreak_core")

local FEED = read_fixture("feed-kink.xml")

-- Cue times (epoch seconds) of the fixture's ad block.
local KPN_START = 1789729173.912
local INTERPOLIS_START = 1789729223.546
local INTERPOLIS_STOP = 1789729248.546 -- + 25 s; the insert trigger sits here
local SUPERSONIC_START = 1789729362.509 -- first titled song after the block
local BAD_DECISIONS_STOP = 1789729637.435 + 280.322
local FEED_LAG = 50
local WINDOW = 8 -- numberToFetch of the live feed URL

local function entries()
    return core.parse_feed(FEED)
end

local function without_insert(list)
    local kept = {}
    for _, e in ipairs(list) do
        if e.ad_type ~= "insert" then
            kept[#kept + 1] = e
        end
    end
    return kept
end

test("parse_feed reads every entry with kind, times and title", function()
    local list = entries()
    assert_eq(#list, 14, "entries")
    assert_eq(list[1].kind, "track")
    assert_eq(list[1].title, "Bad Decisions")
    assert_near(list[1].start, 1789729637.435, 0.001)
    assert_near(list[1].stop, BAD_DECISIONS_STOP, 0.001)
    assert_eq(list[10].kind, "ad")
    assert_eq(list[10].ad_type, "insert")
    assert_eq(list[11].ad_type, "break")
    assert_eq(list[11].title, "INTERPOLIS GRIPOPCYBER")
end)

test("parse_feed tolerates garbage and nil", function()
    assert_eq(#core.parse_feed(nil), 0)
    assert_eq(#core.parse_feed("<html>nope</html>"), 0)
    assert_eq(#core.parse_feed('<?xml version="1.0"?><nowplaying-info-list/>'), 0)
end)

test("spots are the ad entries with a duration", function()
    local spots = core.spots(entries())
    assert_eq(#spots, 4)
    assert_eq(spots[1].title, "INTERPOLIS GRIPOPCYBER")
    assert_eq(spots[4].title, "KPN RDS EXTRA RC OLR OMRUIL")
end)

test("active_spot finds the spot playing at a cue time", function()
    local list = entries()
    assert_eq(core.active_spot(list, INTERPOLIS_START + 10).title, "INTERPOLIS GRIPOPCYBER")
    assert_eq(core.active_spot(list, KPN_START).title, "KPN RDS EXTRA RC OLR OMRUIL")
    -- The few milliseconds between two spots fall inside the margin of the earlier one.
    assert_eq(core.active_spot(list, 1789729223.52).title, "KV WK38 ALWAYS")
    assert_eq(core.active_spot(list, INTERPOLIS_STOP + 1), nil)
    assert_eq(core.active_spot(list, KPN_START - 1), nil)
end)

test("last_spot_end is the end of the newest spot", function()
    local list = entries()
    assert_near(core.last_spot_end(list), INTERPOLIS_STOP, 0.001)
    assert_near(core.last_spot_end(without_insert(list)), INTERPOLIS_STOP, 0.001, "the trigger is not a spot")
    assert_eq(core.last_spot_end({}), nil)
end)

local function without_titled_tracks(list)
    local kept = {}
    for _, e in ipairs(list) do
        if not (e.kind == "track" and e.title ~= "") then
            kept[#kept + 1] = e
        end
    end
    return kept
end

test("song_after_spots is the first titled track after the block", function()
    local list = entries()
    assert_near(core.song_after_spots(list), SUPERSONIC_START, 0.001, "Supersonic, not Bad Decisions")
    assert_eq(core.song_after_spots(without_titled_tracks(list)), nil, "untitled tracks do not count")
    assert_eq(core.song_after_spots({}), nil)
end)

test("block_ended needs the song after the last spot to be heard, or a long grace period", function()
    local list = entries()
    local grace, lead = 180, 3
    assert_eq(core.block_ended(list, INTERPOLIS_START + 5, grace, lead), false, "spot still playing")
    assert_eq(core.block_ended(list, INTERPOLIS_STOP + 1, grace, lead), false, "song known but not reached")
    assert_eq(core.block_ended(list, SUPERSONIC_START - lead - 0.1, grace, lead), false, "just before the lead")
    assert_eq(core.block_ended(list, SUPERSONIC_START - lead, grace, lead), true,
        "the fade-up starts `lead` before the song")
    assert_eq(core.block_ended(list, SUPERSONIC_START, grace), true, "no lead: at the song")
    assert_eq(core.block_ended(without_insert(list), SUPERSONIC_START, grace), true, "the trigger is not needed")
    local unconfirmed = without_titled_tracks(list)
    assert_eq(core.block_ended(unconfirmed, INTERPOLIS_STOP + 1, grace), false, "the trigger alone is not enough")
    assert_eq(core.block_ended(unconfirmed, INTERPOLIS_STOP + 100, grace), false, "a stalled feed does not un-duck")
    assert_eq(core.block_ended(unconfirmed, INTERPOLIS_STOP + 0.5 + grace + 0.1, grace), true, "past grace")
    assert_eq(core.block_ended({}, 0, grace), true, "nothing known")
end)

test("merge_entries keeps old entries, prefers fresh ones and prunes past the horizon", function()
    local list = entries()
    local older, newer = {}, {}
    for i, e in ipairs(list) do
        if i > 6 then older[#older + 1] = e end
        if i <= 8 then newer[#newer + 1] = e end
    end
    local merged = core.merge_entries(older, newer, 0)
    assert_eq(#merged, 14, "union")
    assert_eq(merged[1].title, "Bad Decisions", "newest first")
    assert_eq(merged[14].title, "KPN RDS EXTRA RC OLR OMRUIL")
    local corrected = {
        { kind = "ad", ad_type = "break", start = list[11].start, stop = list[11].stop + 5, title = "x" },
    }
    assert_near(core.merge_entries(list, corrected, 0)[11].stop, list[11].stop + 5, 0.001, "fresh entry wins")
    assert_eq(#core.merge_entries(list, {}, INTERPOLIS_STOP + 1), 9, "spots pruned past the horizon")
    assert_eq(#core.merge_entries({}, {}, 0), 0)
end)

-- The feed as it looked at wall-clock time `at`: an entry appears `FEED_LAG` seconds
-- after its cue start, and only the newest `WINDOW` entries are served.
local function feed_as_of(list, at)
    local seen = {}
    for _, e in ipairs(list) do
        if e.start + FEED_LAG <= at and #seen < WINDOW then
            seen[#seen + 1] = e
        end
    end
    return seen
end

-- Replays a block the way the interface script sees it: a listener `delay` seconds
-- behind cue time, polling every second and merging each answer into what it kept.
-- Returns the wall-clock time at which block_ended first turns true.
local function replay_until_ended(list, delay, grace, lead)
    local kept = {}
    for wall = KPN_START + delay, BAD_DECISIONS_STOP + delay do
        local stream_now = wall - delay
        kept = core.merge_entries(kept, feed_as_of(list, wall), stream_now - grace - 60)
        if core.block_ended(kept, stream_now, grace, lead) then
            return wall
        end
    end
    return nil
end

test("the insert trigger does not end the break: commercials go on after it", function()
    -- After the last spot the feed shows the trigger, an untitled 8 s entry, an untitled
    -- 71 s entry and four jingles before the first titled song; the volume came up
    -- ~1 minute early when the trigger counted as the end of the break.
    local list = entries()
    local delay, grace, lead = 53, 180, 3
    local function ended_at(wall)
        return core.block_ended(feed_as_of(list, wall), wall - delay, grace, lead)
    end
    assert_eq(ended_at(INTERPOLIS_STOP + delay + 1), false, "trigger just heard")
    assert_eq(ended_at(INTERPOLIS_STOP + delay + 10), false, "untitled entry after the trigger")
    assert_eq(ended_at(INTERPOLIS_STOP + delay + 60), false, "in the middle of the 71 s entry")
    assert_eq(ended_at(SUPERSONIC_START + FEED_LAG - 1), false, "jingles, song not published yet")
    -- The grace period starts at the last spot and outlasts the whole measured tail.
    assert_eq(INTERPOLIS_STOP + core.SPOT_MARGIN + grace > SUPERSONIC_START, true, "grace covers the tail")
end)

test("the fade-up lands on the song for any delay, not on the song's publication", function()
    local list = entries()
    local grace, lead = 180, 3
    -- The song is published at cue + 50; a listener 53 s behind hears it 3 s later, one
    -- 80 s behind (VLC drift) 30 s later. Un-ducking at publication is early by that much.
    assert_near(replay_until_ended(list, 53, grace, lead), SUPERSONIC_START + 53 - lead, 1, "fresh VLC")
    assert_near(replay_until_ended(list, 80, grace, lead), SUPERSONIC_START + 80 - lead, 1, "drifted VLC")
    assert_near(replay_until_ended(list, 120, grace, lead), SUPERSONIC_START + 120 - lead, 1, "far behind")
end)

test("spots that scroll out of the feed window are remembered until the song", function()
    -- One more untitled entry in the tail and the block's spots have left the 8-entry
    -- window before the song is published; without the kept history block_ended would
    -- see no spots at all and un-duck in the middle of the jingles.
    local list = entries()
    local tail = {}
    for _, e in ipairs(list) do
        if e.title == "Supersonic" then
            tail[#tail + 1] = { kind = "track", ad_type = nil, start = e.start, stop = e.start + 10, title = "" }
            tail[#tail + 1] = { kind = "track", ad_type = nil, start = e.start + 10, stop = e.stop, title = e.title }
        else
            tail[#tail + 1] = e
        end
    end
    table.sort(tail, function(a, b) return a.start > b.start end)
    local song = SUPERSONIC_START + 10
    local delay, grace, lead = 53, 180, 3
    local at_publication = feed_as_of(tail, song + FEED_LAG - 1)
    assert_eq(core.last_spot_end(at_publication), nil, "spots have scrolled out of the window")
    assert_eq(core.block_ended(at_publication, song + FEED_LAG - 1 - delay, grace, lead), true,
        "the window alone would un-duck now")
    assert_near(replay_until_ended(tail, delay, grace, lead), song + delay - lead, 1, "kept history waits for the song")
end)

test("fade_plan gives ~120 ms steps, at least two", function()
    local steps, pause = core.fade_plan(3)
    assert_eq(steps, 25)
    assert_near(pause, 0.12, 0.001)
    steps, pause = core.fade_plan(0.1)
    assert_eq(steps, 2)
    assert_near(pause, 0.05, 0.001)
end)

test("block_start walks back over contiguous spots", function()
    assert_near(core.block_start(entries()), KPN_START, 0.001)
    assert_eq(core.block_start({}), nil)
end)

test("ducked_volume applies the percentage and the floor", function()
    assert_eq(core.ducked_volume(256, 60, 0), 102)
    assert_eq(core.ducked_volume(256, 60, 50), 128, "floor wins")
    assert_eq(core.ducked_volume(100, 60, 50), 100, "never louder than normal")
    assert_eq(core.ducked_volume(256, 100, 0), 0)
    assert_eq(core.ducked_volume(256, 0, 0), 256)
    assert_eq(core.ducked_volume(200, 60), 80, "floor defaults to 0")
end)

test("fade_steps ends exactly on the target", function()
    local down = core.fade_steps(256, 102, 6)
    assert_eq(#down, 6)
    assert_eq(down[6], 102)
    for i = 2, #down do
        assert_eq(down[i] <= down[i - 1], true, "monotonic")
    end
    local up = core.fade_steps(102, 256, 6)
    assert_eq(up[6], 256)
    assert_eq(core.fade_steps(100, 100, 3)[3], 100)
end)

test("next_poll waits for the end of the newest entry plus the feed lag", function()
    local list = entries()
    local lag, retry, idle = 50, 2, 60
    assert_near(core.next_poll(list, BAD_DECISIONS_STOP + 40, lag, retry, idle), 10.3, 0.01, "just before publication")
    assert_eq(core.next_poll(list, BAD_DECISIONS_STOP - 100, lag, retry, idle), idle, "far ahead: capped at idle")
    assert_eq(core.next_poll(list, BAD_DECISIONS_STOP + 51, lag, retry, idle), retry, "feed is late: retry")
    assert_eq(core.next_poll({}, 0, lag, retry, idle), idle, "nothing known")
end)

test("next_transition is the next spot edge or fade-up point in listener time", function()
    local list = entries()
    local delay, lead = 53, 3
    assert_near(core.next_transition(list, KPN_START + delay - 5, delay), 5, 0.001, "before the block")
    assert_near(core.next_transition(list, INTERPOLIS_START + delay + 1, delay), 25 - 1 + 0.5, 0.001,
        "end of the last spot")
    assert_near(core.next_transition(list, INTERPOLIS_STOP + delay + 10, delay, lead),
        SUPERSONIC_START - lead - INTERPOLIS_STOP - 10, 0.001, "the fade-up before the song")
    assert_eq(core.next_transition(list, SUPERSONIC_START + delay + 1, delay, lead), nil, "all edges passed")
    assert_eq(core.next_transition(without_titled_tracks(list), INTERPOLIS_STOP + delay + 10, delay, lead), nil,
        "no song known: nothing to wake up for")
    assert_eq(core.next_transition({}, 0, delay), nil)
end)

test("drift grows with stalls and resets when the stream restarts", function()
    local drift = core.new_drift(100, 0)
    assert_eq(drift:update(110, 10), 0, "playing normally")
    assert_eq(drift:update(120, 15), 5, "5 s stall")
    assert_eq(drift:update(130, 25), 5, "stall persists")
    assert_eq(drift:update(131, 1), 0, "position jumped back: restart")
    assert_eq(drift:update(141, 11), 0)
    assert_eq(drift:update(140, 11), 0, "never negative")
end)

test("mount_from_uri", function()
    assert_eq(core.mount_from_uri("https://22343.live.streamtheworld.com:443/KINK_SC"), "KINK")
    assert_eq(core.mount_from_uri("https://25233.live.streamtheworld.com:443/KINK_DNA_SC"), "KINK_DNA")
    assert_eq(core.mount_from_uri("https://25343.live.streamtheworld.com/KINK_DISTORTION_SC?dist=x"), "KINK_DISTORTION")
    assert_eq(core.mount_from_uri("https://example.com/KINK_SC"), nil)
    assert_eq(core.mount_from_uri(nil), nil)
end)

test("feed_url lists all event types", function()
    local url = core.feed_url("KINK")
    assert_eq(url:find("mountName=KINK", 1, true) ~= nil, true)
    assert_eq(url:find("eventType", 1, true), nil, "no eventType filter: it would drop every entry")
end)

test("parse_settings reads the key=value file the dialog writes", function()
    local settings = core.parse_settings("duck_percent=80\r\nmin_volume=10\n")
    assert_eq(settings.duck_percent, 80)
    assert_eq(settings.min_volume, 10)
    settings = core.parse_settings("# written by hand\n\n  fade_up = 2.5 \nresync=false\nmount=KINK_DNA\n=nokey\n")
    assert_eq(settings.fade_up, 2.5)
    assert_eq(settings.resync, false)
    assert_eq(settings.mount, "KINK_DNA")
    assert_eq(settings[""], nil, "a line without a key is skipped")
    assert_eq(next(core.parse_settings("")), nil)
    assert_eq(next(core.parse_settings(nil)), nil)
end)

test("parse_marker", function()
    local action, at = core.parse_marker("end 1789729300\n")
    assert_eq(action, "end")
    assert_eq(at, 1789729300)
    assert_eq(core.parse_marker("START 5"), "start")
    assert_eq(core.parse_marker(""), nil)
    assert_eq(core.parse_marker(nil), nil)
end)

test("calibrated_delay from the first commercial or the first song heard by the listener", function()
    local list = entries()
    assert_eq(core.calibrated_delay(list, "end", SUPERSONIC_START + 53.4), 53, "'end' is the song, not the last spot")
    assert_eq(core.calibrated_delay(list, "start", KPN_START + 80), 80)
    assert_eq(core.calibrated_delay(without_titled_tracks(list), "end", SUPERSONIC_START + 53), nil,
        "song not published yet")
    assert_eq(core.calibrated_delay({}, "end", 0), nil)
    assert_eq(core.calibrated_delay(list, "reconnect", 0), nil)
end)

test("calibrated_delay refuses stale marks and implausible results, with a reason", function()
    local list = entries()
    local at = SUPERSONIC_START + 53
    assert_eq(core.calibrated_delay(list, "end", at, at + 1), 53, "read a second after the press")
    assert_eq(core.calibrated_delay(list, "end", at, at + core.MARKER_MAX_AGE), 53, "at the age limit")
    local delay, reason = core.calibrated_delay(list, "end", at, at + core.MARKER_MAX_AGE + 1)
    assert_eq(delay, nil, "a mark left behind while VLC was closed")
    assert_eq(reason:find("old", 1, true) ~= nil, true, reason)
    delay, reason = core.calibrated_delay(list, "end", at + 7200, at + 7200)
    assert_eq(delay, nil, "hours after the block: 7253 s is not a lag")
    assert_eq(reason:find("plausible", 1, true) ~= nil, true, reason)
    delay, reason = core.calibrated_delay(list, "start", KPN_START + 5, KPN_START + 5)
    assert_eq(delay, nil, "pressed before the block could be heard")
    assert_eq(reason:find("plausible", 1, true) ~= nil, true, reason)
    local late = SUPERSONIC_START + core.DELAY_MAX
    assert_eq(core.calibrated_delay(list, "end", late, late), core.DELAY_MAX, "the limits are inclusive")
    delay, reason = core.calibrated_delay({}, "start", at, at)
    assert_eq(delay, nil)
    assert_eq(reason, "the feed shows no ad block yet")
    delay, reason = core.calibrated_delay(list, "reconnect", at, at)
    assert_eq(delay, nil)
    assert_eq(reason:find("unknown", 1, true) ~= nil, true, reason)
end)
