-- LPCG-style poetry memorization: overlapping line context → recite next line.
-- See https://ankilpcg.readthedocs.io/en/stable/theory.html

local ConfirmBox   = require("ui/widget/confirmbox")
local InfoMessage  = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local TextViewer   = require("ui/widget/textviewer")
local UIManager    = require("ui/uimanager")
local _            = require("gettext")

local AnkiSync         = require("anki_sync")
local CardFields       = require("card_fields")
local CardStorage      = require("card_storage")
local NoteTypeProfiles = require("note_type_profiles")
local ReadingLocation  = require("reading_location")

local PoetryMemorize = {}

PoetryMemorize.INTRO_TEXT = _([[
Creates overlapping step cards in Anki so you recite each new line or chunk aloud.

• Poetry: one step per line (long lines split by word count)
• Prose: split by sentences, then ~7-word chunks
• Each step shows prior lines as cue; you recite the next part
• Optional one full-passage recitation card per selection
• Deck: Memorize::Book title::page (created automatically)
• Anki note type must be named "Memorization"

Set up templates and deck options in the plugin docs (anki-memorization.md).]])

function PoetryMemorize.build_send_summary(cfg, lines, deck, meta)
    cfg = cfg or {}
    meta = meta or {}
    local step_cards = #lines
    local total = step_cards + (cfg.include_full_recitation ~= false and 1 or 0)
    local preview = lines[1] or ""
    if #preview > 50 then preview = preview:sub(1, 50) .. "…" end

    local body = _("Will send to Anki:\n")
        .. _("• ") .. tostring(total) .. _(" cards (")
        .. tostring(step_cards) .. _(" step")
        .. (step_cards == 1 and "" or "s")
    if cfg.include_full_recitation ~= false then
        body = body .. _(" + 1 full recitation")
    end
    body = body .. ")\n"
        .. _("• Deck: ") .. deck .. "\n"
        .. _("• Note type: ") .. (cfg.model or NoteTypeProfiles.MEMORIZATION_MODEL) .. "\n"
        .. _("• Context: ") .. tostring(cfg.context_lines or 3) .. _(" prior steps shown as cue\n")
        .. _("• Chunk size: ~") .. tostring(cfg.max_words_per_unit or 7) .. _(" words (prose)\n")
    if preview ~= "" then
        body = body .. _("• First chunk: \"") .. preview .. "\"\n"
    end
    if meta.location and meta.location ~= "" then
        body = body .. _("• Location: ") .. meta.location .. "\n"
    end
    return body
end

function PoetryMemorize.maybe_show_intro(then_fn, on_cancel)
    local saved = CardStorage.load_anki_settings() or {}
    if saved.skip_memorize_intro then
        then_fn()
        return
    end

    -- Use TextViewer (scrollable body) rather than ButtonDialog: the intro is a
    -- long multi-line description, which would overflow a ButtonDialog title.
    local intro_dlg
    intro_dlg = TextViewer:new {
        title         = _("Memorization cards"),
        text          = PoetryMemorize.INTRO_TEXT,
        show_menu     = false,
        buttons_table = {
            {{ text = _("Continue"), callback = function()
                UIManager:close(intro_dlg)
                then_fn()
            end }},
            {{ text = _("View README"), callback = function()
                local ok, rv = pcall(require, "readme_viewer")
                if ok and rv and rv.show_or_notify then
                    rv.show_or_notify("memorization")
                end
            end }},
            {{ text = _("Don't show again"), callback = function()
                UIManager:close(intro_dlg)
                saved.skip_memorize_intro = true
                CardStorage.save_anki_settings(saved)
                then_fn()
            end }},
            {{ text = _("Cancel"), callback = function()
                UIManager:close(intro_dlg)
                if on_cancel then on_cancel() end
            end }},
        },
    }
    UIManager:show(intro_dlg)
end

local function safe_deck_part(s, max_len)
    s = (s or ""):gsub("::", " "):gsub(":", " -"):match("^%s*(.-)%s*$") or ""
    if max_len and #s > max_len then
        s = s:sub(1, max_len - 3) .. "..."
    end
    return s
end

function PoetryMemorize.config(base)
    local cfg = {
        parent_deck               = "Memorize",
        model                     = NoteTypeProfiles.MEMORIZATION_MODEL,
        context_lines             = 3,
        max_words_per_unit        = 7,
        auto_create_deck          = true,
        include_full_recitation   = true,
        tags                      = { "KOReader", "memorization" },
    }
    if base and type(base.memorize) == "table" then
        for k, v in pairs(base.memorize) do cfg[k] = v end
    end
    local anki = CardFields.merged_anki_settings(base)
    if anki.url and anki.url ~= "" then cfg.url = anki.url end
    if anki.memorize_parent_deck and anki.memorize_parent_deck ~= "" then
        cfg.parent_deck = anki.memorize_parent_deck
    end
    if anki.memorize_model and anki.memorize_model ~= "" then
        cfg.model = anki.memorize_model
    end
    if anki.memorize_context_lines then
        cfg.context_lines = tonumber(anki.memorize_context_lines) or cfg.context_lines
    end
    if anki.memorize_max_words then
        cfg.max_words_per_unit = tonumber(anki.memorize_max_words) or cfg.max_words_per_unit
    end
    if anki.memorize_tags and type(anki.memorize_tags) == "table" then
        cfg.tags = anki.memorize_tags
    end
    if anki.memorize_include_full_recitation ~= nil then
        cfg.include_full_recitation = anki.memorize_include_full_recitation
    end
    if anki.sync_after_send ~= nil then
        cfg.sync_after_send = anki.sync_after_send
    end
    return cfg
end

function PoetryMemorize.split_lines(text)
    local lines = {}
    if not text or text == "" then return lines end
    for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        line = line:match("^%s*(.-)%s*$") or ""
        if line ~= "" then
            table.insert(lines, line)
        end
    end
    return lines
end

local function count_words(s)
    local n = 0
    for _ in (s or ""):gmatch("%S+") do n = n + 1 end
    return n
end

local function split_word_chunks(text, max_words)
    max_words = math.max(4, tonumber(max_words) or 12)
    local words = {}
    for w in (text or ""):gmatch("%S+") do table.insert(words, w) end
    if #words == 0 then return {} end
    if #words <= max_words then return { table.concat(words, " ") } end

    local chunks = {}
    for i = 1, #words, max_words do
        local part = {}
        for j = i, math.min(i + max_words - 1, #words) do
            table.insert(part, words[j])
        end
        table.insert(chunks, table.concat(part, " "))
    end
    return chunks
end

local function split_sentences(text)
    local out = {}
    text = text:match("^%s*(.-)%s*$") or ""
    if text == "" then return out end

    local len = #text
    local start = 1
    local i = 1
    while i <= len do
        local ch = text:sub(i, i)
        if ch == "." or ch == "!" or ch == "?" or ch == ";" then
            local j = i + 1
            if j <= len and text:sub(j, j):match("[\"']") then j = j + 1 end
            if j > len or text:sub(j, j):match("%s") then
                local seg = text:sub(start, j - 1):match("^%s*(.-)%s*$")
                if seg ~= "" then table.insert(out, seg) end
                start = j
                while start <= len and text:sub(start, start):match("%s") do
                    start = start + 1
                end
                i = start
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end
    if start <= len then
        local tail = text:sub(start):match("^%s*(.-)%s*$")
        if tail ~= "" then table.insert(out, tail) end
    end
    return out
end

local function expand_long_units(units, max_words)
    local out = {}
    for _i, unit in ipairs(units) do
        if count_words(unit) > max_words then
            for _i, chunk in ipairs(split_word_chunks(unit, max_words)) do
                table.insert(out, chunk)
            end
        else
            table.insert(out, unit)
        end
    end
    return out
end

-- Poetry: one unit per line break. Prose: sentences, then word chunks if needed.
function PoetryMemorize.split_units(text, cfg)
    cfg = cfg or {}
    local max_words = cfg.max_words_per_unit or 12

    local lines = PoetryMemorize.split_lines(text)
    if #lines >= 2 then
        return expand_long_units(lines, max_words)
    end

    local block = lines[1] or text:match("^%s*(.-)%s*$") or ""
    if block == "" then return {} end

    local sentences = split_sentences(block)
    if #sentences == 0 then
        sentences = { block }
    end

    local units = expand_long_units(sentences, max_words)
    if #units <= 1 then
        units = split_word_chunks(block, max_words)
    end
    return units
end

function PoetryMemorize.derive_title(lines, meta)
    meta = meta or {}
    if meta.book_title and meta.book_title ~= "" then
        local label = safe_deck_part(meta.book_title, 36)
        local loc = meta.location
        if loc and loc ~= "" then
            return label .. " · " .. loc
        end
        return label .. " · " .. _("excerpt")
    end
    local first = (lines and lines[1]) or ""
    local words = {}
    for w in first:gmatch("%S+") do
        table.insert(words, w)
        if #words >= 6 then break end
    end
    local t = table.concat(words, " ")
    if count_words(first) > 6 then t = t .. "…" end
    return (t ~= "" and t) or _("Selection")
end

-- Leaf subdeck label only (book title lives in the parent deck level).
function PoetryMemorize.derive_piece_label(meta, lines)
    meta = meta or {}
    if meta.book_title and meta.book_title ~= "" then
        if meta.location and meta.location ~= "" then
            return safe_deck_part(meta.location, 40)
        end
        return _("excerpt")
    end
    return PoetryMemorize.derive_title(lines, meta)
end

function PoetryMemorize.resolve_deck(cfg, book_title, piece_label)
    local parts = { safe_deck_part(cfg.parent_deck or "Memorize", 40) }
    local book = safe_deck_part(book_title, 40)
    local piece = safe_deck_part(piece_label, 50)
    if book ~= "" then table.insert(parts, book) end
    if piece ~= "" and piece ~= book then table.insert(parts, piece) end
    return table.concat(parts, "::")
end

local function merge_tags(base_tags, extra)
    local out, seen = {}, {}
    for _i, tag in ipairs(base_tags or {}) do
        if tag ~= "" and not seen[tag] then
            seen[tag] = true
            table.insert(out, tag)
        end
    end
    for _i, tag in ipairs(extra or {}) do
        if tag ~= "" and not seen[tag] then
            seen[tag] = true
            table.insert(out, tag)
        end
    end
    return out
end

function PoetryMemorize.build_notes(lines, opts)
    opts = opts or {}
    local notes = {}
    local full_text = table.concat(lines, "\n")
    local ctx_n = math.max(0, tonumber(opts.context_lines) or 3)
    local title = opts.title or PoetryMemorize.derive_title(lines)
    local source = opts.source or ""

    for i = 1, #lines do
        local ctx_lines = {}
        local ctx_start = math.max(1, i - ctx_n)
        for j = ctx_start, i - 1 do
            table.insert(ctx_lines, lines[j])
        end
        table.insert(notes, {
            deckName  = opts.deck,
            modelName = opts.model,
            fields    = {
                Title     = title,
                Context   = table.concat(ctx_lines, "\n"),
                Target    = lines[i],
                FullText  = full_text,
                Source    = source,
                LineIndex = tostring(i),
                FullRecite = "",
            },
            options = {
                allowDuplicate = true,
                duplicateScope = "deck",
            },
            tags = merge_tags(opts.tags, { "memorization::step" }),
        })
    end

    if opts.include_full_recitation ~= false then
        table.insert(notes, {
            deckName  = opts.deck,
            modelName = opts.model,
            fields    = {
                Title      = title,
                Context    = "",
                Target     = "",
                FullText   = full_text,
                Source     = source,
                LineIndex  = "",
                FullRecite = "yes",
            },
            options = {
                allowDuplicate = true,
                duplicateScope = "deck",
            },
            tags = merge_tags(opts.tags, { "memorization::full" }),
        })
    end

    return notes
end

function PoetryMemorize.send_lines(lines, base_config, meta, done)
    meta = meta or {}
    local cfg = PoetryMemorize.config(base_config)
    if not cfg.url or cfg.url == "" or cfg.url:find("192%.168%.x%.x") then
        if done then done(nil, _("Anki URL not set. Use AnkiKOAi → Settings.")) end
        return
    end

    local title = meta.title or PoetryMemorize.derive_title(lines, meta)
    local source = meta.source or ""
    local piece_label = meta.piece_label or PoetryMemorize.derive_piece_label(meta, lines)
    local deck = meta.deck or PoetryMemorize.resolve_deck(cfg, meta.book_title, piece_label)
    local notes = PoetryMemorize.build_notes(lines, {
        title                   = title,
        source                  = source,
        deck                    = deck,
        model                   = cfg.model,
        context_lines           = cfg.context_lines,
        max_words_per_unit      = cfg.max_words_per_unit,
        include_full_recitation = cfg.include_full_recitation,
        tags                    = cfg.tags,
    })

    if cfg.auto_create_deck then
        local ok_deck, err_deck = AnkiSync.ensure_deck(cfg.url, deck)
        if not ok_deck then
            if done then done(nil, err_deck) end
            return
        end
    end

    local sent, failed = 0, 0
    local last_err = nil
    for _i, note in ipairs(notes) do
        local ok, err = AnkiSync.add_note(cfg.url, note)
        if ok then
            sent = sent + 1
        else
            failed = failed + 1
            last_err = err
        end
    end

    if sent == 0 then
        if done then done(nil, last_err or _("No notes sent")) end
        return
    end

    local saved = CardStorage.load_anki_settings() or {}
    saved.last_memorize_deck = deck
    CardStorage.save_anki_settings(saved)

    local msg = tostring(sent) .. _(" cards sent to ") .. deck
    if failed > 0 then
        msg = msg .. " (" .. tostring(failed) .. _(" failed") .. ")"
    end
    msg = msg .. AnkiSync.sync_status_suffix(cfg)
    if done then done(true, msg, { deck = deck, sent = sent, failed = failed }) end
end

function PoetryMemorize.send_highlight(base_config, text, ui, meta, done)
    local cfg = PoetryMemorize.config(base_config)
    local lines = PoetryMemorize.split_units(text, cfg)
    if #lines == 0 then
        if done then done(nil, _("No text to memorize.")) end
        return
    end

    meta = meta or {}
    if not meta.source then
        local book = CardFields.format_book_source(meta.book_title, meta.book_author)
        meta.source = ReadingLocation.append_to_source(book, ui)
    end
    meta.location = ReadingLocation.describe(ui)
    if not meta.title then
        meta.title = PoetryMemorize.derive_title(lines, meta)
    end
    meta.piece_label = meta.piece_label or PoetryMemorize.derive_piece_label(meta, lines)

    PoetryMemorize.send_lines(lines, base_config, meta, done)
end

local function show_memorize_send_confirm(base_config, text, ui, meta, cfg, lines, deck)
    local body = PoetryMemorize.build_send_summary(cfg, lines, deck, meta)

    if cfg.url and cfg.url ~= "" and not cfg.url:find("192%.168%.x%.x") then
        local existing, err = AnkiSync.count_notes_in_deck(cfg.url, deck)
        if existing and existing > 0 then
            body = _("This book and page already have cards in Anki (")
                .. tostring(existing) .. _(" in this deck).\n\n")
                .. _("Sending again adds duplicate step/full cards.\n\n")
                .. body
        elseif err then
            body = body .. "\n\n" .. _("(Could not check for duplicates: ") .. err .. ")"
        end
    end

    body = body .. "\n\n" .. _(
        "Save for later if Anki is unreachable. Send pending cards from My Cards or the hub menu.")

    -- Use TextViewer (scrollable body) rather than ButtonDialog: ButtonDialog
    -- only scrolls its button rows, so a long summary overflows the screen.
    local dlg
    dlg = TextViewer:new {
        title         = _("Send memorization cards"),
        text          = body,
        show_menu     = false,
        buttons_table = {
            {{ text = _("Send to Anki"), callback = function()
                UIManager:close(dlg)
                local loading = Notification:new {
                    text    = _("Sending memorization cards…"),
                    timeout = 120,
                }
                UIManager:show(loading)
                UIManager:scheduleIn(0.05, function()
                    PoetryMemorize.send_highlight(base_config, text, ui, meta, function(ok, err_or_msg)
                        UIManager:close(loading)
                        if ok then
                            UIManager:show(Notification:new { text = err_or_msg, timeout = 5 })
                        else
                            UIManager:show(InfoMessage:new {
                                text    = (err_or_msg or _("Send failed"))
                                    .. "\n\n" .. _("Use Save for later to queue on this device."),
                                timeout = 8,
                            })
                        end
                        if meta.on_done then meta.on_done() end
                    end)
                end)
            end }},
            {{ text = _("Save for later"), callback = function()
                UIManager:close(dlg)
                if not meta.source then
                    local book = CardFields.format_book_source(meta.book_title, meta.book_author)
                    meta.source = ReadingLocation.append_to_source(book, ui)
                end
                local ok_save = CardStorage.save_memorization_pending(text, meta, deck)
                if ok_save then
                    UIManager:show(Notification:new {
                        text    = _("Saved locally. Send from My Cards when Anki is available."),
                        timeout = 5,
                    })
                else
                    UIManager:show(InfoMessage:new {
                        text    = _("Could not save memorization passage."),
                        timeout = 5,
                    })
                end
                if meta.on_done then meta.on_done() end
            end }},
            {{ text = _("Cancel"), callback = function()
                UIManager:close(dlg)
                if meta.on_done then meta.on_done() end
            end }},
        },
    }
    UIManager:show(dlg)
end

function PoetryMemorize.confirm_and_send(base_config, text, ui, meta)
    local cfg = PoetryMemorize.config(base_config)
    local lines = PoetryMemorize.split_units(text, cfg)
    if #lines == 0 then
        UIManager:show(InfoMessage:new {
            text    = _("Select one or more lines to memorize."),
            timeout = 4,
        })
        if meta.on_done then meta.on_done() end
        return
    end

    meta = meta or {}
    meta.location = ReadingLocation.describe(ui)
    if not meta.title then
        meta.title = PoetryMemorize.derive_title(lines, meta)
    end
    meta.piece_label = meta.piece_label or PoetryMemorize.derive_piece_label(meta, lines)
    local deck = meta.deck
        or PoetryMemorize.resolve_deck(cfg, meta.book_title, meta.piece_label)

    PoetryMemorize.maybe_show_intro(function()
        show_memorize_send_confirm(base_config, text, ui, meta, cfg, lines, deck)
    end, meta.on_done)
end

return PoetryMemorize
