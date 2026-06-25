-- Local card storage for AnkiKOAi.

local DataStorage = require("datastorage")
local json        = require("json")
local logger      = require("logger")
local PluginConstants = require("plugin_constants")
local _           = require("gettext")

local function data_path(name)
    return DataStorage:getDataDir() .. "/" .. name
end

local CARDS_FILE    = data_path(PluginConstants.CARDS_FILE)
local SETTINGS_FILE = data_path(PluginConstants.SETTINGS_FILE)

local CardStorage = {}

local function normalize(phrase)
    return (phrase or ""):lower():match("^%s*(.-)%s*$")
end

-- Naive English stemmer: strip common inflectional suffixes.
local function stem(word)
    local w = normalize(word)
    -- Order matters — try longest suffixes first.
    w = w:gsub("ies$", "y")       -- "stories" → "story"
    w = w:gsub("ying$", "y")      -- "studying" → "study" (approximate)
    w = w:gsub("ving$", "ve")     -- "having" → "have"
    w = w:gsub("ting$", "t")      -- "sitting" → "sit" (approximate)
    w = w:gsub("ning$", "n")      -- "running" → "run"
    w = w:gsub("ging$", "g")      -- "nagging" → "nag"
    w = w:gsub("ding$", "d")      -- "adding" → "add"
    w = w:gsub("bing$", "b")      -- "rubbing" → "rub"
    w = w:gsub("ping$", "p")      -- "tapping" → "tap"
    w = w:gsub("ming$", "m")      -- "swimming" → "swim"
    w = w:gsub("zing$", "z")      -- "buzzing" → "buz" (close enough)
    w = w:gsub("sing$", "s")      -- "missing" → "mis" (approximate)
    w = w:gsub("ing$", "")        -- "taxing" → "tax"
    w = w:gsub("ied$", "y")       -- "studied" → "study"
    w = w:gsub("ved$", "ve")      -- "moved" → "move"
    w = w:gsub("ced$", "ce")      -- "danced" → "dance"
    w = w:gsub("sed$", "se")      -- "closed" → "close"
    w = w:gsub("ted$", "t")       -- "dotted" → "dot"
    w = w:gsub("ned$", "n")       -- "planned" → "plan"
    w = w:gsub("ged$", "g")       -- "nagged" → "nag"
    w = w:gsub("ded$", "d")       -- "added" → "add"
    w = w:gsub("bed$", "b")       -- "rubbed" → "rub"
    w = w:gsub("ped$", "p")       -- "tapped" → "tap"
    w = w:gsub("med$", "m")       -- "trimmed" → "trim"
    w = w:gsub("ed$", "")         -- "walked" → "walk"
    w = w:gsub("es$", "")         -- "cogs" won't match but "boxes" → "box"
    w = w:gsub("s$", "")          -- "cogs" → "cog"
    w = w:gsub("ly$", "")         -- "quickly" → "quick"
    w = w:gsub("er$", "")         -- "bigger" → "bigg" (approximate)
    w = w:gsub("est$", "")        -- "biggest" → "bigg"
    return w
end

local function load_raw()
    local f = io.open(CARDS_FILE, "r")
    if not f then return {} end
    local content = f:read("*all")
    f:close()
    if not content or content == "" then return {} end
    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" then return data end
    return {}
end

local function save_raw(entries)
    local ok, encoded = pcall(json.encode, entries)
    if not ok then
        logger.warn(PluginConstants.ID, "save_raw: JSON encode failed:", encoded)
        return false
    end
    local tmp = CARDS_FILE .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then
        logger.warn(PluginConstants.ID, "save_raw: cannot open temp file for write:", tmp)
        return false
    end
    local wrote = f:write(encoded)
    local closed = f:close()
    if not wrote or not closed then
        logger.warn(PluginConstants.ID, "save_raw: write/close failed (disk full?):", tmp)
        os.remove(tmp)
        return false
    end
    if os.rename(tmp, CARDS_FILE) then return true end
    -- Some platforms (e.g. Windows) fail to rename onto an existing file.
    os.remove(CARDS_FILE)
    if os.rename(tmp, CARDS_FILE) then return true end
    logger.warn(PluginConstants.ID, "save_raw: rename of temp file failed:", tmp)
    os.remove(tmp)
    return false
end

-- Identity test used for de-duplication / upsert. Memorization passages are
-- keyed on their full text (the phrase is a title-derived label shared by many
-- passages from the same book/page); all other cards key on the phrase.
local function same_card(a, b)
    local a_mem = a.card_kind == "memorization"
    local b_mem = b.card_kind == "memorization"
    if a_mem or b_mem then
        if a_mem and b_mem then
            local at = normalize(a.memorization_text)
            return at ~= "" and at == normalize(b.memorization_text)
        end
        return false
    end
    return normalize(a.phrase) == normalize(b.phrase)
end

-- Upsert by card identity (used for auto-save after generation).
function CardStorage.save_or_update(card)
    local entries = load_raw()
    for i, e in ipairs(entries) do
        if same_card(e, card) then
            local merged = CardStorage.serialize_entry(card)
            merged.sent_to_anki = e.sent_to_anki
            merged.date = e.date or merged.date
            entries[i] = merged
            if not save_raw(entries) then return false, "write_failed" end
            return true, "updated"
        end
    end
    table.insert(entries, CardStorage.serialize_entry(card))
    if not save_raw(entries) then return false, "write_failed" end
    return true, "saved"
end

function CardStorage.serialize_entry(card)
    return {
        phrase      = card.phrase      or "",
        ipa         = card.ipa         or "",
        definition  = card.definition  or "",
        synonyms    = card.synonyms    or "",
        text        = card.text        or "",
        links       = card.links       or (card.anki_fields and card.anki_fields.Links) or "",
        source      = card.source      or "",
        book_title  = card.book_title  or "",
        book_author = card.book_author or "",
        highlight_pos0 = card.highlight_pos0,
        highlight_pos1 = card.highlight_pos1,
        _context       = card._context       or "",
        _wiki_sources  = card._wiki_sources,
        target_deck    = card.target_deck    or "",
        target_model   = card.target_model   or "",
        model          = card.model          or "",
        card_kind      = card.card_kind      or "",
        memorization_text = card.memorization_text or "",
        memorization_deck = card.memorization_deck or "",
        anki_fields    = card.anki_fields,
        date           = os.date("%Y-%m-%d"),
        updated_at     = os.time(),
        sent_to_anki   = card.sent_to_anki == true,
    }
end

-- Already sent to Anki for this phrase in the same book?
function CardStorage.find_sent_duplicate(phrase, book_title)
    local key  = normalize(phrase)
    local book = normalize(book_title or "")
    for _, e in ipairs(load_raw()) do
        if e.sent_to_anki and normalize(e.phrase) == key then
            if book == "" or normalize(e.book_title or "") == book then
                return e
            end
        end
    end
    return nil
end

-- Returns the full list of saved cards.
function CardStorage.load_cards()
    return load_raw()
end

function CardStorage.is_memorization(card)
    return card and card.card_kind == "memorization"
        and card.memorization_text and card.memorization_text ~= ""
end

function CardStorage.count_unsent()
    local n = 0
    for _, e in ipairs(load_raw()) do
        if not e.sent_to_anki then n = n + 1 end
    end
    return n
end

-- Queue a memorization passage for sending when Anki is reachable.
function CardStorage.save_memorization_pending(text, meta, deck)
    meta = meta or {}
    text = text or ""
    if text == "" then return false, "empty" end
    local title = (meta.title and meta.title ~= "") and meta.title
        or text:match("^%s*(.-)%s*$") or _("Passage")
    if #title > 60 then title = title:sub(1, 60) .. "…" end
    local phrase = _("Memorization") .. ": " .. title
    local ok, reason = CardStorage.save_or_update({
        card_kind           = "memorization",
        phrase              = phrase,
        memorization_text   = text,
        memorization_deck   = deck or "",
        book_title          = meta.book_title or "",
        book_author         = meta.book_author or "",
        source              = meta.source or "",
        target_deck         = deck or "",
        sent_to_anki        = false,
    })
    return ok, reason
end

-- Update editable fields of an already-saved card (matched by original phrase).
-- Does not touch book metadata, date or sent_to_anki.
function CardStorage.update_card(original_phrase, new_card)
    local key     = normalize(original_phrase)
    local entries = load_raw()
    for _, e in ipairs(entries) do
        if normalize(e.phrase) == key then
            e.phrase       = new_card.phrase       or ""
            e.ipa          = new_card.ipa          or ""
            e.definition   = new_card.definition   or ""
            e.synonyms     = new_card.synonyms     or ""
            e.text         = new_card.text         or ""
            e.source       = new_card.source       or ""
            e.model        = new_card.model        or e.model or ""
            e.anki_fields  = new_card.anki_fields   or e.anki_fields
            e.updated_at   = os.time()
            save_raw(entries)
            return true
        end
    end
    return false
end

-- Remove card by 1-based index.
function CardStorage.delete_card(idx)
    local entries = load_raw()
    table.remove(entries, idx)
    save_raw(entries)
end

-- Delete multiple cards by 1-based indices (highest first).
function CardStorage.delete_indices(indices)
    if not indices or #indices == 0 then return end
    local sorted = {}
    for _, idx in ipairs(indices) do table.insert(sorted, idx) end
    table.sort(sorted, function(a, b) return a > b end)
    for _, idx in ipairs(sorted) do
        CardStorage.delete_card(idx)
    end
end

-- Delete every card for which match_fn(card, index) is true.
function CardStorage.delete_where(match_fn)
    local entries = load_raw()
    local to_remove = {}
    for i, card in ipairs(entries) do
        if match_fn(card, i) then table.insert(to_remove, i) end
    end
    CardStorage.delete_indices(to_remove)
end

-- Empty the entire card list.
function CardStorage.clear_all()
    save_raw({})
end

-- Remove saved card matching phrase (exact, then fuzzy). Returns true if removed.
function CardStorage.delete_by_phrase(phrase)
    local card = CardStorage.find_by_phrase(phrase)
    if not card then
        card = CardStorage.find_by_phrase_fuzzy(phrase)
    end
    if not card then return false end
    local entries = load_raw()
    for i, e in ipairs(entries) do
        if e == card or normalize(e.phrase) == normalize(card.phrase) then
            CardStorage.delete_card(i)
            return true
        end
    end
    return false
end

-- Find and return a saved card by phrase (case-insensitive, trimmed).
-- Returns the card table or nil.
function CardStorage.find_by_phrase(phrase)
    local key     = normalize(phrase)
    local entries = load_raw()
    for _, e in ipairs(entries) do
        if normalize(e.phrase) == key then
            return e
        end
    end
    return nil
end

-- Find a saved card by phrase with fuzzy stem matching.
-- Tries exact (normalized) match first, then falls back to stem comparison.
-- Returns the card table or nil.
function CardStorage.find_by_phrase_fuzzy(phrase)
    local exact = CardStorage.find_by_phrase(phrase)
    if exact then return exact end
    local key     = stem(phrase)
    if key == "" then return nil end
    local entries = load_raw()
    for _, e in ipairs(entries) do
        if stem(e.phrase) == key then
            return e
        end
    end
    return nil
end

-- Find a saved card by highlight position.
-- Returns the card table or nil.
function CardStorage.find_by_position(pos0, pos1)
    if not pos0 then return nil end
    local entries = load_raw()
    local fallback
    for _, e in ipairs(entries) do
        if e.highlight_pos0 == pos0 then
            if pos1 and e.highlight_pos1 and e.highlight_pos1 == pos1 then
                return e
            end
            if not fallback then fallback = e end
        end
    end
    return fallback
end

-- Returns true if phrase is already saved (case-insensitive, trimmed).
function CardStorage.is_saved(phrase)
    local key     = normalize(phrase)
    local entries = load_raw()
    for _, e in ipairs(entries) do
        if normalize(e.phrase) == key then
            return true
        end
    end
    return false
end

-- Mark a phrase as sent to Anki; optionally record deck and note type used.
function CardStorage.mark_sent(phrase, target_deck, target_model)
    local key     = normalize(phrase)
    local entries = load_raw()
    for _, e in ipairs(entries) do
        if normalize(e.phrase) == key then
            e.sent_to_anki = true
            if target_deck and target_deck ~= "" then
                e.target_deck = target_deck
            end
            if target_model and target_model ~= "" then
                e.target_model = target_model
            end
            break
        end
    end
    save_raw(entries)
end

-- Mark a memorization passage as sent. Memorization cards must be matched on
-- their full text (the phrase is a title-derived label that many passages from
-- the same book/page can share), otherwise the wrong pending card gets flagged.
function CardStorage.mark_sent_memorization(memorization_text, target_deck)
    local key     = normalize(memorization_text)
    if key == "" then return end
    local entries = load_raw()
    for _, e in ipairs(entries) do
        if e.card_kind == "memorization"
           and normalize(e.memorization_text) == key then
            e.sent_to_anki = true
            if target_deck and target_deck ~= "" then
                e.target_deck       = target_deck
                e.memorization_deck = target_deck
            end
            break
        end
    end
    save_raw(entries)
end

-- Persist Anki connection settings (override configuration.lua at runtime).
function CardStorage.save_anki_settings(settings)
    local ok, encoded = pcall(json.encode, settings)
    if not ok then
        logger.warn(PluginConstants.ID, "save_anki_settings: JSON encode failed:", encoded)
        return false
    end
    -- Write to a temp file then rename so a failed write can't corrupt settings.
    local tmp = SETTINGS_FILE .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then
        logger.warn(PluginConstants.ID, "save_anki_settings: cannot open temp file:", tmp)
        return false
    end
    local wrote = f:write(encoded)
    local closed = f:close()
    if not wrote or not closed then
        logger.warn(PluginConstants.ID, "save_anki_settings: write/close failed:", tmp)
        os.remove(tmp)
        return false
    end
    if os.rename(tmp, SETTINGS_FILE) then return true end
    os.remove(SETTINGS_FILE)
    if os.rename(tmp, SETTINGS_FILE) then return true end
    logger.warn(PluginConstants.ID, "save_anki_settings: rename failed:", tmp)
    os.remove(tmp)
    return false
end

-- Load saved Anki settings. Returns a table or nil if not yet set.
function CardStorage.load_anki_settings()
    local f = io.open(SETTINGS_FILE, "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    if not content or content == "" then return nil end
    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" then return data end
    return nil
end

return CardStorage
