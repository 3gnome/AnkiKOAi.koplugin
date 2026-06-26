-- Highlight Inbox — batch highlights as Wiki, Vocabulary, or Memorization cards.

local NetworkMgr   = require("ui/network/manager")
local Menu         = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local UIManager    = require("ui/uimanager")
local ConfirmBox   = require("ui/widget/confirmbox")
local _            = require("gettext")

local CardGenerator   = require("card_generator")
local CardFields      = require("card_fields")
local CardStorage     = require("card_storage")
local CardDefaults    = require("card_defaults")
local SendFlow        = require("send_flow")
local DictionaryLookup
do
    local ok, mod = pcall(require, "dictionary_lookup")
    if ok then DictionaryLookup = mod end
end
local PoetryMemorize  = require("poetry_memorize")
local PluginConstants = require("plugin_constants")
local ReadingLocation = require("reading_location")
local get_selection_in_context = require("selection_context")
local HighlightInbox  = {}
local Nav             = require("nav")
local SelectableMenu  = require("selectable_menu")

local MODE_WIKI  = "wiki"
local MODE_VOCAB = "vocabulary"
local MODE_MEM   = "memorization"

local MODE_ORDER = { MODE_WIKI, MODE_VOCAB, MODE_MEM }

local function mode_label(config, mode)
    if mode == MODE_WIKI then
        return CardDefaults.wiki_hub_label(config)
    elseif mode == MODE_VOCAB then
        return CardDefaults.vocabulary_hub_label(config)
    elseif mode == MODE_MEM then
        return PluginConstants.MEMORIZATION_CARD_LABEL
    end
    return mode
end

local function normalize(s)
    return (s or ""):lower():match("^%s*(.-)%s*$")
end

local function clean(s, max_len)
    if not s then return "" end
    s = s:gsub("[\r\n]+", " "):match("^%s*(.-)%s*$")
    if max_len and #s > max_len then s = s:sub(1, max_len) end
    return s
end

local function capitalize_first(s)
    return (s:gsub("^%l", string.upper))
end

local function cambridge_url(phrase, config)
    local lang = config and config.target_language or "English"
    if lang ~= "English" then return nil end
    local slug = (phrase or ""):lower():gsub("%s+", "-")
    return "https://dictionary.cambridge.org/dictionary/english/" .. slug
end

local function mode_button_label(config, mode)
    return _("Mode: ") .. mode_label(config, mode) .. " " .. _("(Tap to change)")
end

local function next_mode(mode)
    for i, m in ipairs(MODE_ORDER) do
        if m == mode then
            return MODE_ORDER[(i % #MODE_ORDER) + 1]
        end
    end
    return MODE_WIKI
end

local function build_highlights(ui)
    local raw = (ui.annotation and ui.annotation.annotations) or {}
    local highlights = {}
    for idx, ann in ipairs(raw) do
        if ann.drawer and ann.text and ann.text ~= "" then
            table.insert(highlights, {
                ann       = ann,
                ann_index = idx,
                text      = ann.text,
                chapter   = ann.chapter,
            })
        end
    end
    return highlights
end

function HighlightInbox.has_highlights(ui)
    return #build_highlights(ui) > 0
end

function HighlightInbox.notify_empty()
    UIManager:show(Notification:new {
        text    = _("No highlights found in this book."),
        timeout = 3,
    })
end

local function load_already_carded()
    local already_carded = {}
    for _i, card in ipairs(CardStorage.load_cards()) do
        already_carded[normalize(card.phrase)] = true
    end
    return already_carded
end

local function default_selected(highlights, already_carded, send_mode)
    local selected = {}
    for i, h in ipairs(highlights) do
        if send_mode == MODE_MEM then
            selected[i] = true
        else
            selected[i] = not already_carded[normalize(h.text)]
        end
    end
    return selected
end

-- Internal: build and show the selection menu with current state.
local function show_menu(ui, config, highlights, already_carded, selected, inbox_opts, send_mode)
    inbox_opts = inbox_opts or {}
    send_mode = send_mode or MODE_WIKI
    local menu_ref = {}
    local back_label = inbox_opts.back_label or _("← Back")
    local guard = { busy = false }

    local function go_back()
        if guard.busy or not inbox_opts.on_back then return end
        guard.busy = true
        Nav.after_close(function()
            if menu_ref[1] then UIManager:close(menu_ref[1]) end
        end, function()
            guard.busy = false
            inbox_opts.on_back()
        end)
    end

    local function soft_rebuild()
        UIManager:scheduleIn(0, function()
            if menu_ref[1] then UIManager:close(menu_ref[1]) end
            show_menu(ui, config, highlights, already_carded, selected, inbox_opts, send_mode)
        end)
    end

    local function hard_rebuild()
        UIManager:scheduleIn(0, function()
            if menu_ref[1] then UIManager:close(menu_ref[1]) end
            local fresh = build_highlights(ui)
            local carded = load_already_carded()
            show_menu(ui, config, fresh, carded, default_selected(fresh, carded, send_mode),
                inbox_opts, send_mode)
        end)
    end

    local items   = {}

    local function selected_for_generate()
        local to_do = {}
        for i, h in ipairs(highlights) do
            if selected[i] then
                if send_mode == MODE_MEM
                    or not already_carded[normalize(h.text)] then
                    table.insert(to_do, h)
                end
            end
        end
        return to_do
    end

    local function generate_action_label(n)
        return (send_mode == MODE_MEM and _("Send Selected to Anki (") or _("Generate Selected ("))
            .. tostring(n) .. ")"
    end

    local generate_count = #selected_for_generate()

    table.insert(items, {
        text     = mode_button_label(config, send_mode),
        bold     = true,
        callback = function()
            send_mode = next_mode(send_mode)
            soft_rebuild()
        end,
    })

    table.insert(items, {
        text     = _("View README"),
        callback = function()
            local ReadmeViewer = require("readme_viewer")
            local readme_id = send_mode
            ReadmeViewer.show_or_notify(readme_id)
        end,
    })

    local function highlight_context(h)
        local raw = h.text or ""
        if ui and ui.document then
            return clean(get_selection_in_context(ui.document, raw, 10), 2000)
        end
        return clean(raw, 2000)
    end

    local function apply_highlight_meta(card, h, context)
        if h.ann then
            card.highlight_pos0 = h.ann.pos0
            card.highlight_pos1 = h.ann.pos1
        end
        card._context = context
    end

    local function run_wiki_batch(to_do, title, author)
        local total     = #to_do
        local done      = 0
        local sent      = 0
        local failed    = 0
        local last_err  = nil
        local wiki_model = CardFields.default_wiki_model(config)
        local auto_send = CardDefaults.auto_send_wiki(config)
        local default_deck = CardDefaults.wiki_deck(config)
        local anki_cfg = CardFields.merged_anki_settings(config)
        local prog_notif

        local function show_progress(i)
            if prog_notif then UIManager:close(prog_notif) end
            prog_notif = Notification:new {
                text    = _("Generating ") .. tostring(i) .. "/" .. tostring(total) .. "…",
                timeout = 60,
            }
            UIManager:show(prog_notif)
        end

        local function finish()
            if prog_notif then UIManager:close(prog_notif) end
            local msg
            if auto_send then
                msg = tostring(sent) .. _(" card(s) sent to Anki")
                if done > 0 then
                    msg = msg .. ", " .. tostring(done) .. _(" saved locally")
                end
            else
                msg = tostring(done) .. _(" card(s) saved")
            end
            if failed > 0 then
                msg = msg .. ", " .. tostring(failed) .. _(" failed")
                if last_err and last_err ~= "" then
                    local detail = last_err:gsub("[\r\n]+", " "):match("^%s*(.-)%s*$") or last_err
                    if #detail > 100 then detail = detail:sub(1, 100) .. "…" end
                    msg = msg .. ": " .. detail
                end
            end
            UIManager:show(Notification:new { text = msg, timeout = 8 })
        end

        local function after_card(card, i)
            if not card then
                failed = failed + 1
                generate_next(i + 1)
                return
            end
            apply_highlight_meta(card, to_do[i], clean(to_do[i].text or "", 2000))
            CardStorage.save_or_update(card)
            if auto_send and default_deck then
                card.target_deck = default_deck
                SendFlow.quick_send(anki_cfg, card, function(ok, err)
                    if ok then
                        sent = sent + 1
                    else
                        done = done + 1
                        if err then last_err = err end
                    end
                    generate_next(i + 1)
                end, { ui = ui, use_configured_deck = true })
            else
                done = done + 1
                generate_next(i + 1)
            end
        end

        local function generate_next(i)
            if i > total then finish(); return end
            local h      = to_do[i]
            local highlight_text = clean(h.text or "", 2000)
            local phrase = capitalize_first(highlight_text)
            show_progress(i)
            UIManager:scheduleIn(0.05, function()
                local card, err = CardGenerator.generate(
                    config, phrase, highlight_text, title, author, wiki_model
                )
                if not card then
                    failed = failed + 1
                    last_err = err
                    generate_next(i + 1)
                    return
                end
                CardFields.apply_reading_source(
                    card, title, author, cambridge_url(card.phrase, config),
                    ReadingLocation.describe(ui))
                card.book_title  = title
                card.book_author = author
                after_card(card, i)
            end)
        end

        NetworkMgr:runWhenOnline(function()
            generate_next(1)
        end)
    end

    local function run_dictionary_batch(to_do, title, author)
        local model  = CardFields.default_vocabulary_model(config)
        local total  = #to_do
        local done   = 0
        local sent   = 0
        local failed = 0
        local auto_send = CardDefaults.auto_send_vocabulary(config)
        local default_deck = CardDefaults.vocabulary_deck(config)
        local anki_cfg = CardFields.merged_anki_settings(config)
        local pref_dict = CardDefaults.vocabulary_dictionary(config)
        local prog_notif

        local function show_progress(i)
            if prog_notif then UIManager:close(prog_notif) end
            prog_notif = Notification:new {
                text    = _("Generating ") .. tostring(i) .. "/" .. tostring(total) .. "…",
                timeout = 60,
            }
            UIManager:show(prog_notif)
        end

        local function finish()
            if prog_notif then UIManager:close(prog_notif) end
            local msg
            if auto_send then
                msg = tostring(sent) .. _(" card(s) sent to Anki")
                if done > 0 then
                    msg = msg .. ", " .. tostring(done) .. _(" saved locally")
                end
            else
                msg = tostring(done) .. _(" card(s) saved")
            end
            if failed > 0 then
                msg = msg .. ", " .. tostring(failed) .. _(" failed")
            end
            UIManager:show(Notification:new { text = msg, timeout = 5 })
        end

        local function after_vocab_card(card, i)
            CardStorage.save_or_update(card)
            if auto_send and default_deck then
                card.target_deck = default_deck
                SendFlow.quick_send(anki_cfg, card, function(ok)
                    if ok then
                        sent = sent + 1
                    else
                        done = done + 1
                    end
                    generate_next(i + 1)
                end, { ui = ui, use_configured_deck = true })
            else
                done = done + 1
                generate_next(i + 1)
            end
        end

        local function generate_next(i)
            if i > total then finish(); return end
            local h      = to_do[i]
            local phrase = capitalize_first(clean(h.text or "", 2000))
            local context = highlight_context(h)
            show_progress(i)
            UIManager:scheduleIn(0.05, function()
                if not DictionaryLookup then
                    failed = failed + 1
                    generate_next(i + 1)
                    return
                end
                local entries, _err = DictionaryLookup.lookup_all(ui, phrase)
                local entry = nil
                if entries then
                    if pref_dict and pref_dict ~= "" then
                        for _j, e in ipairs(entries) do
                            if e.dict == pref_dict then entry = e; break end
                        end
                    end
                    if not entry then entry = entries[1] end
                end
                if entry then
                    local card = {
                        phrase          = capitalize_first(clean(entry.word or phrase, 2000)),
                        definition      = entry.definition or "",
                        context         = context,
                        text            = context,
                        model           = model,
                        target_model    = model,
                        dictionary_only = true,
                        dictionary_name = entry.dict or "",
                        book_title      = title,
                        book_author     = author,
                    }
                    apply_highlight_meta(card, h, context)
                    CardFields.apply_reading_source(
                        card, title, author, nil, ReadingLocation.describe(ui))
                    CardFields.normalize(card, config)
                    after_vocab_card(card, i)
                else
                    failed = failed + 1
                    generate_next(i + 1)
                end
            end)
        end

        generate_next(1)
    end

    local function run_memorization_batch(to_do, title, author)
        local cfg = PoetryMemorize.config(config)
        local total = #to_do
        local done_passages, saved_local, failed = 0, 0, 0
        local prog_notif

        local function show_progress(label)
            if prog_notif then UIManager:close(prog_notif) end
            prog_notif = Notification:new {
                text    = label,
                timeout = 120,
            }
            UIManager:show(prog_notif)
        end

        local function finish()
            if prog_notif then UIManager:close(prog_notif) end
            local msg = tostring(done_passages) .. _(" passage(s) sent to Anki")
            if saved_local > 0 then
                msg = msg .. ", " .. tostring(saved_local)
                    .. _(" saved locally (Anki unavailable)")
            end
            if failed > 0 then
                msg = msg .. ", " .. tostring(failed) .. _(" failed")
            end
            UIManager:show(Notification:new { text = msg, timeout = 6 })
        end

        local function passage_text(h)
            return PoetryMemorize.extract_selection_text(ui, {
                text = h.text or "",
                pos0 = h.ann and h.ann.pos0,
                pos1 = h.ann and h.ann.pos1,
            }, 2000)
        end

        local function send_one_passage(text, meta, on_done)
            show_progress(_("Sending memorization cards…"))
            UIManager:scheduleIn(0.05, function()
                PoetryMemorize.send_highlight(config, text, ui, meta, function(ok)
                    if ok then
                        done_passages = done_passages + 1
                        if on_done then on_done(true) end
                        return
                    end
                    local piece_cfg = PoetryMemorize.config(config)
                    local lines = PoetryMemorize.split_units(
                        PoetryMemorize.prepare_text(text), piece_cfg)
                    meta.piece_label = meta.piece_label
                        or PoetryMemorize.derive_piece_label(meta, lines)
                    local deck = PoetryMemorize.resolve_deck(
                        piece_cfg, meta.book_title, meta.piece_label)
                    if CardStorage.save_memorization_pending(text, meta, deck) then
                        saved_local = saved_local + 1
                    else
                        failed = failed + 1
                    end
                    if on_done then on_done(false) end
                end)
            end)
        end

        if cfg.merge_batch and total > 1 then
            local parts = {}
            for _, h in ipairs(to_do) do
                local t = passage_text(h)
                if t ~= "" then table.insert(parts, t) end
            end
            local merged = table.concat(parts, "\n")
            if merged == "" then
                UIManager:show(Notification:new {
                    text    = _("No text to memorize."),
                    timeout = 4,
                })
                return
            end
            send_one_passage(merged, {
                book_title  = title,
                book_author = author,
            }, finish)
            return
        end

        local function send_next(i)
            if i > total then finish(); return end
            local h = to_do[i]
            local text = passage_text(h)
            show_progress(_("Sending ") .. tostring(i) .. "/" .. tostring(total) .. "…")
            send_one_passage(text, {
                book_title  = title,
                book_author = author,
            }, function()
                send_next(i + 1)
            end)
        end

        send_next(1)
    end

    -- ▶ Generate / Send Selected ─────────────────────────────────────────────
    table.insert(items, {
        text               = generate_action_label(generate_count),
        bold               = true,
        _anki_action_count = true,
        select_enabled     = generate_count > 0,
        callback = function()
            local to_do = selected_for_generate()
            if #to_do == 0 then
                UIManager:show(Notification:new {
                    text    = _("Nothing selected."),
                    timeout = 3,
                })
                return
            end

            guard.busy = true
            if menu_ref[1] then UIManager:close(menu_ref[1]) end
            menu_ref[1] = nil
            guard.busy = false

            local book_props = (ui.document and ui.document:getProps()) or {}
            local title = clean(book_props.title or "", 100)
            local author = book_props.authors or ""
            if type(author) == "table" then author = table.concat(author, ", ") end
            author = clean((author ~= "" and author or "Unknown Author"), 100)

            if send_mode == MODE_WIKI then
                run_wiki_batch(to_do, title, author)
            elseif send_mode == MODE_VOCAB then
                run_dictionary_batch(to_do, title, author)
            else
                local cfg = PoetryMemorize.config(config)
                local summary = _("Send ") .. tostring(#to_do)
                    .. _(" highlight(s) as memorization decks.\n\n")
                if cfg.merge_batch and #to_do > 1 then
                    summary = summary
                        .. _("Merge batch: ON — selections are combined into one passage.\n\n")
                else
                    summary = summary
                        .. _("Each selection becomes step cards (+ optional full card) in Memorize::Book::location.\n")
                end
                summary = summary
                    .. _("Note type: ") .. (cfg.model or "Memorization") .. "\n\n"
                    .. _("See docs/anki-memorization.md for Anki setup.")

                local function start_batch()
                    run_memorization_batch(to_do, title, author)
                end

                if cfg.auto_send then
                    start_batch()
                else
                    PoetryMemorize.maybe_show_intro(function()
                        UIManager:show(ConfirmBox:new {
                            text = summary,
                            ok_text = _("Send to Anki"),
                            ok_callback = start_batch,
                        })
                    end)
                end
            end
        end,
    })

    local entries = {}
    for i, h in ipairs(highlights) do
        local preview = clean(h.text or "", 2000)
        if #preview > 60 then preview = preview:sub(1, 60) .. "…" end
        local chapter = (h.chapter and h.chapter ~= "") and ("  [" .. h.chapter .. "]") or ""
        table.insert(entries, {
            key   = i,
            label = preview .. chapter,
            data  = h,
        })
    end

    local list_state = { entries = entries, selected = selected, opts = nil }
    local list_opts = {
        entries  = entries,
        selected = selected,
        rebuild  = function()
            UIManager:scheduleIn(0.05, function()
                if menu_ref[1] and list_state then
                    SelectableMenu.sync_in_place(menu_ref[1], list_state)
                end
            end)
        end,
        label_fn = function(entry, sel)
            local h = entry.data
            local is_carded = (send_mode ~= MODE_MEM)
                and already_carded[normalize(h.text)]
            local check = is_carded and "✓ " or (sel[entry.key] and "☑ " or "☐ ")
            return check .. entry.label
        end,
        on_delete_selected = function(picked)
            for _i, entry in ipairs(picked) do
                CardStorage.delete_by_phrase(entry.data.text)
            end
            local indices = {}
            for _i, entry in ipairs(picked) do
                if entry.data.ann_index then
                    table.insert(indices, entry.data.ann_index)
                end
            end
            table.sort(indices, function(a, b) return a > b end)
            if ui.highlight and ui.highlight.deleteHighlight then
                for _i, idx in ipairs(indices) do
                    ui.highlight:deleteHighlight(idx)
                end
            end
        end,
        after_delete = hard_rebuild,
        delete_selected_label = _("Delete Selected Highlights"),
        delete_selected_confirm = _("Remove selected highlight(s) from this book?\n\n")
            .. _("Saved AnkiKOAi cards for those phrases will also be deleted."),
        action_count_fn = function()
            return #selected_for_generate()
        end,
        action_count_label_fn = generate_action_label,
    }
    list_state.opts = list_opts
    SelectableMenu.append_list(items, list_opts)

    local total_label = tostring(#highlights) .. _(" highlight(s)")
    Nav.prepend_back(items, nil, menu_ref, back_label)
    local m = Nav.wrap_menu(Menu:new(Nav.apply_compact_menu {
        title      = _("Highlights to Anki  (") .. total_label .. ")",
        item_table = items,
    }), function()
        if guard.busy then return end
        go_back()
    end)
    menu_ref[1] = m
    Nav.show(m)
end

-- Public entry point. Call with self.ui and CONFIGURATION from main.lua.
function HighlightInbox.show(ui, config, inbox_opts)
    inbox_opts = inbox_opts or {}
    local highlights = build_highlights(ui)

    if #highlights == 0 then
        HighlightInbox.notify_empty()
        return
    end

    local already_carded = load_already_carded()
    local selected = default_selected(highlights, already_carded, MODE_WIKI)

    show_menu(ui, config, highlights, already_carded, selected, inbox_opts, MODE_WIKI)
end

return HighlightInbox
