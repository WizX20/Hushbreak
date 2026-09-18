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
local SUPERSONIC_START = 1789729362.523 -- first titled song after the block
local BAD_DECISIONS_STOP = 1789729637.435 + 280.322
local FEED_LAG = 50

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

test("song_started_after_spots sees titled tracks only", function()
    local list = entries()
    assert_eq(core.song_started_after_spots(list), true, "Supersonic follows the block")
    assert_eq(core.song_started_after_spots(without_titled_tracks(list)), false, "untitled tracks do not count")
    assert_eq(core.song_started_after_spots({}), false)
end)

test("block_ended needs a song after the last spot, or a long grace period", function()
    local list = entries()
    local grace = 180
    assert_eq(core.block_ended(list, INTERPOLIS_START + 5, grace), false, "spot still playing")
    assert_eq(core.block_ended(list, INTERPOLIS_STOP + 1, grace), true, "a song started after the block")
    assert_eq(core.block_ended(without_insert(list), INTERPOLIS_STOP + 1, grace), true, "the trigger is not needed")
    local unconfirmed = without_titled_tracks(list)
    assert_eq(core.block_ended(unconfirmed, INTERPOLIS_STOP + 1, grace), false, "the trigger alone is not enough")
    assert_eq(core.block_ended(unconfirmed, INTERPOLIS_STOP + 100, grace), false, "a stalled feed does not un-duck")
    assert_eq(core.block_ended(unconfirmed, INTERPOLIS_STOP + 0.5 + grace + 0.1, grace), true, "past grace")
    assert_eq(core.block_ended({}, 0, grace), true, "nothing known")
end)

-- The feed as it looked at wall-clock time `at`: an entry appears `FEED_LAG` seconds
-- after its cue start.
local function feed_as_of(list, at)
    local seen = {}
    for _, e in ipairs(list) do
        if e.start + FEED_LAG <= at then
            seen[#seen + 1] = e
        end
    end
    return seen
end

test("the insert trigger does not end the break: commercials go on after it", function()
    -- Replays the fixture's block for a listener 53 s behind cue time. After the last
    -- spot the feed shows the trigger, an untitled 8 s entry, an untitled 71 s entry and
    -- four jingles before the first titled song; the volume came up ~1 minute early
    -- when the trigger counted as the end of the break.
    local list = entries()
    local delay, grace = 53, 180
    local function ended_at(wall)
        return core.block_ended(feed_as_of(list, wall), wall - delay, grace)
    end
    assert_eq(ended_at(INTERPOLIS_STOP + delay + 1), false, "trigger just heard")
    assert_eq(ended_at(INTERPOLIS_STOP + delay + 10), false, "untitled entry after the trigger")
    assert_eq(ended_at(INTERPOLIS_STOP + delay + 60), false, "in the middle of the 71 s entry")
    assert_eq(ended_at(SUPERSONIC_START + FEED_LAG - 1), false, "jingles, song not published yet")
    assert_eq(ended_at(SUPERSONIC_START + FEED_LAG), true, "song published: 3 s before it is heard")
    -- The grace period starts at the last spot and outlasts the whole measured tail.
    assert_eq(INTERPOLIS_STOP + core.SPOT_MARGIN + grace > SUPERSONIC_START, true, "grace covers the tail")
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

test("next_transition is the next spot edge in listener time", function()
    local list = entries()
    local delay = 53
    assert_near(core.next_transition(list, KPN_START + delay - 5, delay), 5, 0.001, "before the block")
    assert_near(core.next_transition(list, INTERPOLIS_START + delay + 1, delay), 25 - 1 + 0.5, 0.001,
        "end of the last spot")
    assert_eq(core.next_transition(list, INTERPOLIS_STOP + delay + 10, delay), nil, "all edges passed")
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

test("parse_marker", function()
    local action, at = core.parse_marker("end 1789729300\n")
    assert_eq(action, "end")
    assert_eq(at, 1789729300)
    assert_eq(core.parse_marker("START 5"), "start")
    assert_eq(core.parse_marker(""), nil)
    assert_eq(core.parse_marker(nil), nil)
end)

test("calibrated_delay from a block start or end heard by the listener", function()
    local list = entries()
    assert_eq(core.calibrated_delay(list, "end", INTERPOLIS_STOP + 53.4), 53)
    assert_eq(core.calibrated_delay(list, "start", KPN_START + 80), 80)
    assert_eq(core.calibrated_delay({}, "end", 0), nil)
    assert_eq(core.calibrated_delay(list, "reconnect", 0), nil)
end)
