-- Tests for src/lua/intf/modules/hushbreak_core.lua. Run with `lua tests/run.lua`.
-- The fixture is a real answer of Triton's now-playing feed for KINK (2026-09-18,
-- 14 entries): four ad spots, the end-of-block trigger, and a run of tracks.

local core = require("hushbreak_core")

local FEED = read_fixture("feed-kink.xml")

-- Cue times (epoch seconds) of the fixture's ad block.
local KPN_START = 1789729173.912
local INTERPOLIS_START = 1789729223.546
local INTERPOLIS_STOP = 1789729248.546 -- + 25 s
local BAD_DECISIONS_STOP = 1789729637.435 + 280.322

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

test("last_spot_end and the end marker", function()
    local list = entries()
    assert_near(core.last_spot_end(list), INTERPOLIS_STOP, 0.001)
    assert_eq(core.has_end_marker(list), true)
    assert_eq(core.has_end_marker(without_insert(list)), false)
    assert_eq(core.last_spot_end({}), nil)
    assert_eq(core.has_end_marker({}), false)
end)

test("block_ended waits for the marker or the grace period", function()
    local list = entries()
    local grace = 8
    assert_eq(core.block_ended(list, INTERPOLIS_START + 5, grace), false, "spot still playing")
    assert_eq(core.block_ended(list, INTERPOLIS_STOP + 1, grace), true, "marker known")
    local unconfirmed = without_insert(list)
    assert_eq(core.block_ended(unconfirmed, INTERPOLIS_STOP + 1, grace), false, "within grace")
    assert_eq(core.block_ended(unconfirmed, INTERPOLIS_STOP + 0.5 + grace + 0.1, grace), true, "past grace")
    assert_eq(core.block_ended({}, 0, grace), true, "nothing known")
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
