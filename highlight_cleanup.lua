-- Remove orphan AnkiKOAi vocab/mem highlights left after background send.

local PluginConstants = require("plugin_constants")

local HighlightCleanup = {}

HighlightCleanup.MAX_AGE_SEC = 7 * 24 * 3600

local function normalize_phrase(text)
    return (text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
end

function HighlightCleanup.should_remove_annotation(ann, entry, now)
    if not ann or not entry then
        return false
    end
    now = now or os.time()
    local kind = entry.card_kind or ""
    if kind ~= "vocabulary" and kind ~= "memorization" then
        return false
    end
    if ann.color ~= PluginConstants.HIGHLIGHT_COLOR_SAVED then
        return false
    end
    if not entry.highlight_pos0 or ann.pos0 ~= entry.highlight_pos0 then
        return false
    end
    if entry.highlight_pos1 and ann.pos1 ~= entry.highlight_pos1 then
        return false
    end
    if normalize_phrase(ann.text) ~= normalize_phrase(entry.phrase) then
        return false
    end
    local sent_at = entry.sent_at or 0
    if sent_at <= 0 or (now - sent_at) > HighlightCleanup.MAX_AGE_SEC then
        return false
    end
    return true
end

function HighlightCleanup.find_removable_positions(annotations, recent_entries, now)
    local out = {}
    local seen = {}
    annotations = annotations or {}
    recent_entries = recent_entries or {}
    for _, entry in ipairs(recent_entries) do
        if entry.highlight_pos0 and not seen[entry.highlight_pos0 .. "|" .. (entry.highlight_pos1 or "")] then
            for _, ann in ipairs(annotations) do
                if HighlightCleanup.should_remove_annotation(ann, entry, now) then
                    out[#out + 1] = {
                        pos0 = ann.pos0,
                        pos1 = ann.pos1,
                    }
                    seen[entry.highlight_pos0 .. "|" .. (entry.highlight_pos1 or "")] = true
                    break
                end
            end
        end
    end
    return out
end

function HighlightCleanup.run(ui)
    if not ui or not ui.highlight or not ui.annotation then
        return 0
    end
    local CardStorage = require("card_storage")
    local HighlightStatus = require("highlight_status")
    local annotations = ui.annotation.annotations or {}
    local positions = HighlightCleanup.find_removable_positions(
        annotations, CardStorage.load_recent_sent())
    local removed = 0
    for _, pos in ipairs(positions) do
        if HighlightStatus.remove_highlight(ui, pos.pos0, pos.pos1) then
            removed = removed + 1
        end
    end
    return removed
end

return HighlightCleanup
