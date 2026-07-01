#!/usr/bin/env luajit
-- Run: luajit spec/highlight_cleanup_spec.lua (from plugin root)

local root = arg[0]:match("(.*)[/\\]") or "."
package.path = package.path .. ";" .. root .. "/?.lua;" .. root .. "/spec/?.lua"

local passed, failed = 0, 0

local function assert_true(c, msg)
    if not c then
        failed = failed + 1
        print("FAIL:", msg)
        return
    end
    passed = passed + 1
end

local function assert_eq(a, e, msg)
    if a ~= e then
        failed = failed + 1
        print("FAIL:", msg, "expected", e, "got", a)
        return
    end
    passed = passed + 1
end

local HighlightCleanup = require("highlight_cleanup")
local PluginConstants = require("plugin_constants")

local now = os.time()

assert_true(not HighlightCleanup.should_remove_annotation(
    { text = "word", color = "green", pos0 = "a", pos1 = "b" },
    { card_kind = "vocabulary", phrase = "word", highlight_pos0 = "a", highlight_pos1 = "b", sent_at = now },
    now
), "green wiki-like never removed")

assert_true(HighlightCleanup.should_remove_annotation(
    { text = "inchoate", color = PluginConstants.HIGHLIGHT_COLOR_SAVED, pos0 = "p0", pos1 = "p1" },
    { card_kind = "vocabulary", phrase = "inchoate", highlight_pos0 = "p0", highlight_pos1 = "p1", sent_at = now },
    now
), "orange vocab with matching positions removed")

assert_true(not HighlightCleanup.should_remove_annotation(
    { text = "inchoate", color = PluginConstants.HIGHLIGHT_COLOR_SAVED, pos0 = "p0", pos1 = "p1" },
    { card_kind = "vocabulary", phrase = "inchoate", highlight_pos0 = "other", highlight_pos1 = "p1", sent_at = now },
    now
), "wrong position not removed")

assert_true(not HighlightCleanup.should_remove_annotation(
    { text = "other", color = PluginConstants.HIGHLIGHT_COLOR_SAVED, pos0 = "p0", pos1 = "p1" },
    { card_kind = "vocabulary", phrase = "inchoate", highlight_pos0 = "p0", highlight_pos1 = "p1", sent_at = now },
    now
), "phrase mismatch not removed")

assert_true(not HighlightCleanup.should_remove_annotation(
    { text = "word", color = PluginConstants.HIGHLIGHT_COLOR_SAVED, pos0 = "a", pos1 = "b" },
    { card_kind = "wiki", phrase = "word", highlight_pos0 = "a", highlight_pos1 = "b", sent_at = now },
    now
), "wiki recent entry never removed")

local positions = HighlightCleanup.find_removable_positions({
    { text = "alpha", color = PluginConstants.HIGHLIGHT_COLOR_SAVED, pos0 = "x", pos1 = "y" },
    { text = "beta", color = PluginConstants.HIGHLIGHT_COLOR_SAVED, pos0 = "m", pos1 = "n" },
}, {
    { card_kind = "memorization", phrase = "beta", highlight_pos0 = "m", highlight_pos1 = "n", sent_at = now },
}, now)
assert_eq(#positions, 1, "one removable position")
assert_eq(positions[1].pos0, "m", "correct pos0")

print(string.format("Results: %d passed, %d failed", passed, failed))
os.exit(failed > 0 and 1 or 0)
