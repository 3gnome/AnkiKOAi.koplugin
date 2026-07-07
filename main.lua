-- AnkiKOAi — KOReader plugin.
-- Highlight text → AI flashcard → sync to Anki via AnkiConnect.

local Device         = require("device")
local logger         = require("logger")
local InfoMessage    = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr     = require("ui/network/manager")
local Notification   = require("ui/widget/notification")
local UIManager      = require("ui/uimanager")
local util           = require("util")
local _              = require("gettext")

local get_selection_in_context = require("selection_context")

local CardGenerator    = require("card_generator")
local CardViewer       = require("card_viewer")
local CardStorage      = require("card_storage")
local AnkiSync         = require("anki_sync")
local CardManager      = require("card_manager")
local CardSync         = require("card_sync")
local CardFields       = require("card_fields")
local CardDefaults     = require("card_defaults")
local NoteTypePicker   = require("note_type_picker")
local NoteTypeProfiles = require("note_type_profiles")
local SendFlow         = require("send_flow")
local UiBusy           = require("ui_busy")
local PluginConstants  = require("plugin_constants")
local ReadingLocation  = require("reading_location")
local HighlightStatus  = require("highlight_status")
local PoetryMemorize   = require("poetry_memorize")
local PluginMenu       = require("plugin_menu")
local HighlightInbox   = require("highlight_inbox")

local DictionaryLookup
do
    local ok, mod = pcall(require, "dictionary_lookup")
    if ok then
        DictionaryLookup = mod
    else
        logger.warn(PluginConstants.ID, "dictionary_lookup failed to load:", mod)
    end
end

local MAX_HL    = 2000
local MAX_TITLE = 100
local PENDING_MIGRATION_NOTICE = nil

-- Load configuration from configuration.lua; saved anki settings (from the
-- settings UI) are merged on top at startup and at send time.
local CONFIGURATION = nil
do
    local ok, conf = pcall(require, "configuration")
    if ok then CONFIGURATION = conf end
    local saved_anki = CardStorage.load_anki_settings()
    if saved_anki then
        local _, migrate_msg = CardFields.migrate_anki_settings(saved_anki)
        if migrate_msg then
            CardStorage.save_anki_settings(saved_anki)
            PENDING_MIGRATION_NOTICE = migrate_msg
        end
        CONFIGURATION = CONFIGURATION or {}
        CONFIGURATION.anki = saved_anki
        -- Promote plugin-level settings from saved anki settings to top level.
        for _i, key in ipairs({
            "target_language",
            "text_provider",
            "dashscope_api_key",
            "gemini_api_key",
            "openai_api_key",
            "openrouter_api_key",
            "openrouter_model",
        }) do
            if saved_anki[key] and saved_anki[key] ~= "" then
                CONFIGURATION[key] = saved_anki[key]
            end
        end
    end
    CONFIGURATION = CONFIGURATION or {}
    local ok_migrate, migrate_err = pcall(CardStorage.ensure_queue_migrated)
    if not ok_migrate then
        logger.warn(PluginConstants.ID, "queue migration skipped:", migrate_err)
    end
    if CONFIGURATION.anki then
        if CONFIGURATION.anki.text_provider == "ankivocab" then
            CONFIGURATION.anki.text_provider = "dashscope"
        end
    end
    if CONFIGURATION and CONFIGURATION.anki then
        CardFields.migrate_anki_settings(CONFIGURATION.anki)
    end
end

local AnkiKOAi = InputContainer:new {
    name        = PluginConstants.ID,
    is_doc_only = true,
}

-- Strip control chars, normalise whitespace, and truncate.
local function clean_str(s, max_len)
    if not s then return "" end
    s = s:gsub("[\r\n]+", " "):match("^%s*(.-)%s*$")
    if max_len and #s > max_len then s = s:sub(1, max_len) end
    return s
end

local function capitalize_first(s)
    return (s:gsub("^%l", string.upper))
end

local function cambridge_url(phrase)
    local lang = CONFIGURATION and CONFIGURATION.target_language or "English"
    if lang ~= "English" then return nil end
    local slug = (phrase or ""):lower():gsub("%s+", "-")
    return "https://dictionary.cambridge.org/dictionary/english/" .. slug
end

-- Safely unwrap rhi.selected_text which may be a string, a table with a
-- .text field, or a nested structure depending on the KOReader backend.
local function extract_text(sel)
    if type(sel) == "string" then return sel end
    if type(sel) ~= "table"  then return "" end
    if type(sel.text) == "string" then return sel.text end
    -- Nested spans/lines: collect string leaves
    local parts = {}
    local function collect(t)
        for _i, v in ipairs(t) do
            if type(v) == "string" then
                parts[#parts + 1] = v
            elseif type(v) == "table" then
                if type(v.text) == "string" then parts[#parts + 1] = v.text end
                if v.spans    then collect(v.spans)    end
                if v.segments then collect(v.segments) end
                if v.lines    then collect(v.lines)    end
            end
        end
    end
    collect(sel)
    return table.concat(parts)
end

-- Read highlighted text from the live highlight module (KOReader stores it in
-- selected_text.text). Falls back to the annotation when editing an existing mark.
local function get_highlight_text(hl, index)
    local sel = hl and hl.selected_text
    local text = extract_text(sel or "")
    if text == "" and sel and sel.text then
        text = extract_text(sel.text)
    end
    if text == "" and index and hl.ui and hl.ui.annotation then
        local ann = hl.ui.annotation.annotations[index]
        if ann and ann.text then
            text = ann.text
        end
    end
    return util.cleanupSelectedText(text or "")
end

-- KOReader's WiFi gate can block forever in the desktop emulator (fake WiFi,
-- DNS checks that never satisfy isOnline). Run the task directly there.
local function schedule_online_task(fn)
    if Device.isEmulator or Device.isDesktop or not Device:hasWifiToggle() then
        UIManager:scheduleIn(0.05, fn)
        return
    end
    if NetworkMgr:isOnline() then
        UIManager:scheduleIn(0.05, fn)
    else
        NetworkMgr:runWhenOnline(function()
            UIManager:scheduleIn(0.05, fn)
        end)
    end
end

-- Close the highlight button dialog only (keep selection until a flow or dismiss).
local function dismiss_highlight_dialog(hl)
    if not hl then return end
    if hl.highlight_dialog then
        UIManager:close(hl.highlight_dialog)
        hl.highlight_dialog = nil
    end
end

-- Fully release text selection so the reader accepts new highlights.
local function release_highlight_for_reading(hl)
    if not hl then return end
    dismiss_highlight_dialog(hl)
    if hl.clear then
        hl:clear()
    end
    hl.selected_text = nil
    hl.hold_pos = nil
    if hl.select_mode then
        hl.select_mode = false
    end
end

-- Reopen the highlight action menu (Manage / My Cards / Generate), not the
-- edit-highlight dialog. showHighlightDialog() requires an existing annotation
-- index and crashes when index is nil (fresh text selection).
local function reopen_highlight_menu(hl, index, sel_copy)
    UIManager:scheduleIn(0.05, function()
        if sel_copy then
            hl.selected_text = sel_copy
        elseif not hl.selected_text and index then
            local item = hl.ui.annotation.annotations[index]
            if item then
                hl.selected_text = util.tableDeepCopy(item)
            end
        end
        hl:onShowHighlightMenu(index)
    end)
end

-- Snapshot selection before closing the highlight dialog (onClose clears it).
local function capture_highlight_context(hl, index)
    return {
        index         = index,
        selected_text = hl.selected_text and util.tableDeepCopy(hl.selected_text) or nil,
        text          = get_highlight_text(hl, index),
    }
end

-- Build the effective Anki config by merging saved settings on top of
-- the config table loaded at startup.
local function get_anki_config()
    local cfg  = {}
    local base = CONFIGURATION and CONFIGURATION.anki
    if base then
        for k, v in pairs(base) do cfg[k] = v end
    end
    local fresh = CardStorage.load_anki_settings()
    if fresh then
        for k, v in pairs(fresh) do cfg[k] = v end
    end
    return cfg
end

local function apply_card_source(card, title, author, ui)
    local loc = ReadingLocation.describe(ui)
    CardFields.apply_reading_source(
        card, title, author, cambridge_url(card.phrase), loc)
end

local function attach_send_callbacks(viewer, card, ui)
    local send_cb = SendFlow.viewer_callbacks(get_anki_config(), card, ui)
    viewer.can_quick_send = send_cb.can_quick_send
    viewer.on_send        = send_cb.on_send
    viewer.on_quick_send  = send_cb.on_quick_send
end

-- ── Quick Lookup cache + popup (purple highlights) ──────────────────────────
local quick_lookup_cache = {}

local PTF_BOLD_ON  = "\xEF\xBF\xB2"
local PTF_BOLD_OFF = "\xEF\xBF\xB3"

local function show_quick_lookup_popup(phrase, lookup, on_delete)
    local Blitbuffer      = require("ffi/blitbuffer")
    local ButtonTable     = require("ui/widget/buttontable")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Font            = require("ui/font")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local Geom            = require("ui/geometry")
    local GestureRange    = require("ui/gesturerange")
    local InputContainer  = require("ui/widget/container/inputcontainer")
    local Size            = require("ui/size")
    local TextBoxWidget   = require("ui/widget/textboxwidget")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")

    local screen_w = Device.screen:getWidth()
    local screen_h = Device.screen:getHeight()
    local popup_w  = math.floor(screen_w * 0.82)
    local pad      = Size.padding.large

    local COLOR_BLUE = Blitbuffer.ColorRGB32(0x00, 0x3A, 0x75, 0xFF)
    local COLOR_RED  = Blitbuffer.ColorRGB32(0xBB, 0x00, 0x00, 0xFF)

    local inner_w = popup_w - pad * 2

    local phrase_w = TextBoxWidget:new {
        text      = capitalize_first(phrase),
        face      = Font:getFace("cfont", 24),
        fgcolor   = COLOR_BLUE,
        width     = inner_w,
        alignment = "center",
        bold      = true,
    }
    local ipa_w = TextBoxWidget:new {
        text      = lookup.ipa or "",
        face      = Font:getFace("cfont", 20),
        fgcolor   = COLOR_RED,
        width     = inner_w,
        alignment = "center",
    }
    local def_w = TextBoxWidget:new {
        text      = lookup.definition or "",
        face      = Font:getFace("cfont", 20),
        width     = inner_w,
        alignment = "center",
    }

    local content = VerticalGroup:new {
        align = "center",
        phrase_w,
        VerticalSpan:new { width = Size.padding.default },
        ipa_w,
        VerticalSpan:new { width = Size.padding.default },
        def_w,
    }

    -- Add a "Delete Highlight" button if a delete callback is provided.
    -- popup_ref is set after the popup widget is created (below).
    local popup_ref = {}
    if on_delete then
        local btn_table = ButtonTable:new {
            width = inner_w,
            buttons = {{
                {
                    text     = _("Delete Highlight"),
                    callback = function()
                        if popup_ref[1] then UIManager:close(popup_ref[1]) end
                        on_delete()
                    end,
                },
            }},
            zero_sep = true,
        }
        content[#content + 1] = VerticalSpan:new { width = Size.padding.large }
        content[#content + 1] = btn_table
    end

    local frame = FrameContainer:new {
        background   = Blitbuffer.COLOR_WHITE,
        bordersize   = Size.border.window,
        radius       = Size.radius.window,
        padding      = pad,
        content,
    }

    local popup
    popup = InputContainer:new {
        ges_events = {
            TapClose = {
                GestureRange:new {
                    ges   = "tap",
                    range = Geom:new { x = 0, y = 0, w = screen_w, h = screen_h },
                },
            },
        },
        CenterContainer:new {
            dimen = Geom:new { w = screen_w, h = screen_h },
            frame,
        },
    }
    function popup:onTapClose()
        UIManager:close(self)
        return true
    end
    function popup:onAnyKeyPressed()
        UIManager:close(self)
        return true
    end

    popup_ref[1] = popup
    UIManager:show(popup)
end

-- ── Wiki Card flow (AI + wiki sources) ──────────────────────────────────────

local function run_wiki_card_flow(hl, ctx, ui, flow_opts)
    flow_opts = flow_opts or {}
    ctx = ctx or {}
    logger.info(PluginConstants.ID, "generate wiki card")
    local highlight_module = ui.highlight

    local title  = clean_str(ui.document:getProps().title, MAX_TITLE)
    local author = ui.document:getProps().authors
    if type(author) == "table" then
        author = table.concat(author, ", ")
    end
    author = clean_str(
        (author and author ~= "") and author or "Unknown Author",
        MAX_TITLE
    )

    local sel = ctx.selected_text
    local highlighted = ctx.text or get_highlight_text(highlight_module, ctx.index)
    local phrase      = capitalize_first(clean_str(highlighted, MAX_HL))
    if phrase == "" then
        UIManager:show(InfoMessage:new {
            text    = _("No text selected. Select words first, then choose Wiki Card (AI)."),
            timeout = 4,
        })
        return
    end
    local highlight_pos0 = sel and sel.pos0
    local highlight_pos1 = sel and sel.pos1
    local highlight_text = clean_str(highlighted, MAX_HL)

    local already_highlighted = false
    local anns = (ui.annotation and ui.annotation.annotations) or {}
    for _i, ann in ipairs(anns) do
        if ann.drawer and ann.pos0 == highlight_pos0 and ann.pos1 == highlight_pos1 then
            already_highlighted = true
            break
        end
    end
    if not already_highlighted then
        if highlight_module.highlight then
            highlight_module.highlight.color = PluginConstants.HIGHLIGHT_COLOR_SAVED
        end
        -- Restore selection briefly so saveHighlight() can run after hub closed dialog.
        if sel then highlight_module.selected_text = sel end
        highlight_module:saveHighlight()
    end

    highlight_module:onClose()

    local anki_cfg = get_anki_config()
    local default_model = CardFields.default_wiki_model(CONFIGURATION)
    local generate_model = default_model

    local function do_generate(chosen_model)
        -- Transient provider errors (429/5xx) are retried inside
        -- CardGenerator.call_llm with backoff, so handle the result directly.
        local card, err = CardGenerator.generate(
            CONFIGURATION, phrase, highlight_text, title, author, chosen_model
        )
        if not card then
            UIManager:show(InfoMessage:new {
                text    = _("Card generation failed: ") .. (err or "unknown"),
                timeout = 5,
            })
            return
        end

        card.book_title     = title
        card.book_author    = author
        apply_card_source(card, title, author, ui)
        card.highlight_pos0 = highlight_pos0
        card.highlight_pos1 = highlight_pos1
        card._context       = highlight_text
        card.model          = chosen_model
        card.target_model   = chosen_model
        CardFields.normalize(card, CONFIGURATION)
        local saved_ok = CardStorage.save_or_update(card)
        if not saved_ok then
            UIManager:show(InfoMessage:new {
                text    = _("Could not save card to device storage (disk full or read-only?)."),
                timeout = 6,
            })
        end
        HighlightStatus.mark_saved(ui, highlight_pos0, highlight_pos1)

        local viewer_ref = {}

        local function make_viewer(c, show_back_flag)
            local v
            v = CardViewer:new {
                card      = c,
                show_back = show_back_flag or false,

                on_show_answer = function()
                    local cur = viewer_ref[1] or v
                    UIManager:close(cur)
                    local nv = make_viewer(c, true)
                    viewer_ref[1] = nv
                end,

                on_show_front = function()
                    local cur = viewer_ref[1] or v
                    UIManager:close(cur)
                    local nv = make_viewer(c, false)
                    viewer_ref[1] = nv
                end,

                on_save = function()
                    CardStorage.save_or_update(c)
                    return true
                end,

                on_update = function(updated_card)
                    CardStorage.save_or_update(updated_card)
                end,

                on_regenerate = function()
                    if viewer_ref[1] then
                        UIManager:close(viewer_ref[1])
                    end
                    UiBusy.run(_("Regenerating…"), function()
                        local new_card, new_err = CardGenerator.generate(
                            CONFIGURATION, phrase, highlight_text, title, author,
                            c.model or generate_model
                        )
                        if not new_card then
                            UIManager:show(InfoMessage:new {
                                text    = _("Regenerate failed: ") .. (new_err or "unknown"),
                                timeout = 5,
                            })
                            viewer_ref[1] = make_viewer(c, false)
                            return
                        end
                        new_card.book_title     = title
                        new_card.book_author    = author
                        apply_card_source(new_card, title, author, ui)
                        new_card.highlight_pos0 = highlight_pos0
                        new_card.highlight_pos1 = highlight_pos1
                        new_card._context       = highlight_text
                        new_card.model          = c.model or generate_model
                        new_card.target_model   = new_card.model
                        CardStorage.save_or_update(new_card)
                        viewer_ref[1] = make_viewer(new_card, false)
                    end)
                end,

                on_regen_text = function()
                    if viewer_ref[1] then UIManager:close(viewer_ref[1]) end
                    schedule_online_task(function()
                        UiBusy.run(_("Refining article…"), function()
                            local new_text, err = CardGenerator.generate_text(CONFIGURATION, c.phrase, c)
                            if not new_text then
                                UIManager:show(InfoMessage:new {
                                    text    = _("Regen failed: ") .. (err or "unknown"),
                                    timeout = 5,
                                })
                                viewer_ref[1] = make_viewer(c, true)
                                return
                            end
                            c.text = new_text
                            CardFields.sync_flat_from_anki(c)
                            CardStorage.save_or_update(c)
                            viewer_ref[1] = make_viewer(c, true)
                        end)
                    end)
                end,
            }
            attach_send_callbacks(v, c, ui)
            UIManager:show(v)
            return v
        end

        local function open_viewer(c, show_back_flag)
            local v = make_viewer(c, show_back_flag)
            viewer_ref[1] = v
            return v
        end

        local function finish_card_send(card)
            local default_deck = CardDefaults.wiki_deck(CONFIGURATION)
            if default_deck then
                card.target_deck = default_deck
            end
            if CardDefaults.auto_send_wiki(CONFIGURATION) then
                SendFlow.quick_send(anki_cfg, card, function(ok, _err)
                    release_highlight_for_reading(highlight_module)
                    if ok then
                        UIManager:show(Notification:new {
                            text    = _("Wiki card sent to Anki"),
                            timeout = 4,
                        })
                    else
                        open_viewer(card, false)
                    end
                end, { ui = ui, use_configured_deck = true })
            else
                release_highlight_for_reading(highlight_module)
                open_viewer(card, false)
            end
        end

        finish_card_send(card)
    end

    local function begin_generation(chosen_model)
        generate_model = chosen_model
        schedule_online_task(function()
            UiBusy.run(_("Generating flashcard for: ") .. phrase, function()
                do_generate(chosen_model)
            end)
        end)
    end

    if CardDefaults.auto_send_wiki(CONFIGURATION) then
        begin_generation(CardDefaults.wiki_model(CONFIGURATION))
    else
        NoteTypePicker.show(anki_cfg, function(chosen_model)
            begin_generation(chosen_model)
        end, {
            current_model = default_model,
            title         = _("Choose note type (Wiki Card)"),
            parent_fn     = flow_opts.parent_fn,
            profile_filter = "wiki",
            info_text     = _(
                "Wiki Card (AI): term on front, Wikipedia-style article + links on back. "
                .. "Default Anki note type: Wiki Card. See docs/anki-vocabulary.md."),
            readme_id     = "wiki",
            fallback_models = {
                NoteTypeProfiles.DEFAULT_MODEL,
                "Basic",
            },
        })
    end
end

-- ── Vocabulary Card flow (KOReader dictionary only, no AI) ──────────────────

local function run_dictionary_vocabulary_flow(hl, ctx, ui, flow_opts)
    flow_opts = flow_opts or {}
    ctx = ctx or {}
    logger.info(PluginConstants.ID, "generate dictionary vocabulary card")
    local highlight_module = ui.highlight

    local title  = clean_str(ui.document:getProps().title, MAX_TITLE)
    local author = ui.document:getProps().authors
    if type(author) == "table" then
        author = table.concat(author, ", ")
    end
    author = clean_str(
        (author and author ~= "") and author or "Unknown Author",
        MAX_TITLE
    )

    local sel = ctx.selected_text
    local highlighted = ctx.text or get_highlight_text(highlight_module, ctx.index)
    local phrase      = capitalize_first(clean_str(highlighted, MAX_HL))
    if phrase == "" then
        UIManager:show(InfoMessage:new {
            text    = _("No text selected. Select words first, then choose Vocabulary Card (No AI)."),
            timeout = 4,
        })
        return
    end
    local highlight_pos0 = sel and sel.pos0
    local highlight_pos1 = sel and sel.pos1
    local context     = clean_str(
        get_selection_in_context.paragraph(ui.document, highlighted),
        MAX_HL
    )

    local already_highlighted = false
    local anns = (ui.annotation and ui.annotation.annotations) or {}
    for _i, ann in ipairs(anns) do
        if ann.drawer and ann.pos0 == highlight_pos0 and ann.pos1 == highlight_pos1 then
            already_highlighted = true
            break
        end
    end
    -- Only persist a highlight when we actually have a selection (the
    -- highlight-dialog path always does; the single-word dictionary-popup
    -- path may not if KOReader cleared it first).
    if not already_highlighted and sel then
        if highlight_module.highlight then
            highlight_module.highlight.color = PluginConstants.HIGHLIGHT_COLOR_SAVED
        end
        highlight_module.selected_text = sel
        highlight_module:saveHighlight()
    end

    highlight_module:onClose()
    -- Selection is saved; release before lookup/send so page turns work again.
    release_highlight_for_reading(highlight_module)

    local anki_cfg = get_anki_config()
    local default_model = CardFields.default_vocabulary_model(CONFIGURATION)

    local function open_dictionary_card(chosen_model, lookup)
        local card = {
            phrase            = capitalize_first(clean_str(lookup.word or phrase, MAX_HL)),
            definition        = lookup.definition or "",
            context           = context,
            text              = context,
            model             = chosen_model,
            target_model      = chosen_model,
            dictionary_only   = true,
            dictionary_name   = lookup.dict or "",
            book_title        = title,
            book_author       = author,
            highlight_pos0    = highlight_pos0,
            highlight_pos1    = highlight_pos1,
            anki_fields       = {
                Phrase     = capitalize_first(clean_str(lookup.word or phrase, MAX_HL)),
                Definition = lookup.definition or "",
                Context    = context,
            },
        }
        apply_card_source(card, title, author, ui)
        CardFields.normalize(card, CONFIGURATION)
        local saved_ok = CardStorage.save_or_update(card)
        if not saved_ok then
            UIManager:show(InfoMessage:new {
                text    = _("Could not save card to device storage (disk full or read-only?)."),
                timeout = 6,
            })
        end
        HighlightStatus.mark_saved(ui, highlight_pos0, highlight_pos1)

        local viewer_ref = {}
        local lookup_word = phrase

        local function apply_lookup(c, lookup, show_back_flag)
            c.phrase = capitalize_first(clean_str(lookup.word or lookup_word, MAX_HL))
            c.definition = lookup.definition or ""
            c.dictionary_name = lookup.dict or ""
            c.anki_fields = c.anki_fields or {}
            c.anki_fields.Phrase = c.phrase
            c.anki_fields.Definition = c.definition
            CardFields.normalize(c, CONFIGURATION)
            CardStorage.save_or_update(c)
        end

        local function make_viewer(c, show_back_flag)
            local v
            v = CardViewer:new {
                card      = c,
                show_back = show_back_flag or false,

                on_show_answer = function()
                    local cur = viewer_ref[1] or v
                    UIManager:close(cur)
                    viewer_ref[1] = make_viewer(c, true)
                end,

                on_show_front = function()
                    local cur = viewer_ref[1] or v
                    UIManager:close(cur)
                    viewer_ref[1] = make_viewer(c, false)
                end,

                on_save = function()
                    CardStorage.save_or_update(c)
                    return true
                end,

                on_update = function(updated_card)
                    CardStorage.save_or_update(updated_card)
                end,

                on_change_definition = function()
                    if not DictionaryLookup then return end
                    if viewer_ref[1] then UIManager:close(viewer_ref[1]) end
                    local word = c.phrase or lookup_word
                    UiBusy.run(_("Dictionary lookup: ") .. word, function()
                        local ok, err = DictionaryLookup.pick(ui, word,
                            function(lookup)
                                apply_lookup(c, lookup, show_back_flag)
                                viewer_ref[1] = make_viewer(c, show_back_flag)
                            end, { always_pick = true })
                        if ok == nil then
                            UIManager:show(InfoMessage:new {
                                text    = _("Dictionary lookup failed: ") .. (err or "unknown"),
                                timeout = 5,
                            })
                            viewer_ref[1] = make_viewer(c, show_back_flag)
                        end
                    end)
                end,
            }
            attach_send_callbacks(v, c, ui)
            UIManager:show(v)
            return v
        end

        local function finish_vocab_send(card)
            local default_deck = CardDefaults.vocabulary_deck(CONFIGURATION)
            if default_deck then
                card.target_deck = default_deck
            end
            if CardDefaults.auto_send_vocabulary(CONFIGURATION) then
                SendFlow.quick_send(anki_cfg, card, function(ok, _err)
                    if ok then
                        UIManager:show(Notification:new {
                            text    = _("Vocabulary card sent to Anki"),
                            timeout = 4,
                        })
                    else
                        viewer_ref[1] = make_viewer(card, false)
                    end
                end, {
                    ui = ui,
                    use_configured_deck = true,
                    -- AnkiWeb sync via AnkiConnect can block the reader for minutes.
                    skip_sync = Device:hasWifiToggle() and not Device.isEmulator,
                })
            else
                UIManager:show(Notification:new {
                    text    = _("Saved locally. Send from My Cards when Anki is available."),
                    timeout = 4,
                })
                viewer_ref[1] = make_viewer(card, false)
            end
        end

        finish_vocab_send(card)
    end

    local function begin_lookup(chosen_model)
        if not DictionaryLookup then
            UIManager:show(InfoMessage:new {
                text    = _("Dictionary lookup is unavailable. Restart KOReader after updating the plugin."),
                timeout = 5,
            })
            return
        end
        local pick_opts = {
            preferred_dictionary = CardDefaults.vocabulary_dictionary(CONFIGURATION),
            auto_pick = CardDefaults.auto_send_vocabulary(CONFIGURATION),
            parent_fn = flow_opts.parent_fn,
        }
        UiBusy.run(_("Dictionary lookup: ") .. phrase, function()
            local ok, err = DictionaryLookup.pick(ui, phrase, function(lookup)
                open_dictionary_card(chosen_model, lookup)
            end, pick_opts)
            if ok == nil then
                UIManager:show(InfoMessage:new {
                    text    = _("Dictionary lookup failed: ") .. (err or "unknown"),
                    timeout = 5,
                })
                if flow_opts.parent_fn then flow_opts.parent_fn() end
            end
        end)
    end

    local function start_vocab_with_model(chosen_model)
        if flow_opts.prefill_lookup then
            open_dictionary_card(chosen_model, flow_opts.prefill_lookup)
        else
            begin_lookup(chosen_model)
        end
    end

    if CardDefaults.auto_send_vocabulary(CONFIGURATION) then
        start_vocab_with_model(CardDefaults.vocabulary_model(CONFIGURATION))
    else
        NoteTypePicker.show(anki_cfg, function(chosen_model)
            start_vocab_with_model(chosen_model)
        end, {
            current_model = default_model,
            title         = _("Choose note type (Vocabulary Card)"),
            parent_fn     = flow_opts.parent_fn,
            profile_filter = "vocabulary",
            info_text     = _(
                "Vocabulary Card (No AI): uses KOReader dictionary only. "
                .. "Pick any note type — the word, definition, passage and source "
                .. "are mapped onto its fields by name (e.g. Front/Back also works). "
                .. "See docs/anki-vocabulary-card.md."),
            readme_id     = "vocabulary",
            fallback_models = {
                NoteTypeProfiles.VOCABULARY_CARD_MODEL,
                "Basic",
            },
        })
    end
end

local function run_memorization_flow(hl, ctx, ui, flow_opts)
    flow_opts = flow_opts or {}
    ctx = ctx or {}
    local highlight_module = ui.highlight
    local highlighted = ctx.text or get_highlight_text(highlight_module, ctx.index)
    local text = PoetryMemorize.extract_selection_text(ui, {
        text          = highlighted,
        selected_text = ctx.selected_text,
    }, MAX_HL)
    if text == "" then
        UIManager:show(InfoMessage:new {
            text    = _("Select text to memorize (sentence, stanza, or passage)."),
            timeout = 4,
        })
        return
    end

    local book_title = clean_str(ui.document:getProps().title, MAX_TITLE)
    local author = ui.document:getProps().authors
    if type(author) == "table" then
        author = table.concat(author, ", ")
    end
    author = clean_str(
        (author and author ~= "") and author or "Unknown Author",
        MAX_TITLE
    )

    PoetryMemorize.confirm_and_send(CONFIGURATION, text, ui, {
        book_title  = book_title,
        book_author = author,
        on_done     = flow_opts.parent_fn,
    })
end

-- Launch the Vocabulary Card flow from KOReader's single-word dictionary
-- popup (DictQuickLookup). The long-pressed word is still held as the live
-- highlight selection (that's how the popup's own "Highlight" button works),
-- so we snapshot it before the popup tears itself down.
local function hub_menu_actions(hl, ctx, ui)
    return {
        on_wiki_card = function(reopen_hub_fn)
            run_wiki_card_flow(hl, ctx, ui, {
                parent_fn = reopen_hub_fn,
            })
        end,
        on_vocabulary_card = function(reopen_hub_fn)
            run_dictionary_vocabulary_flow(hl, ctx, ui, {
                parent_fn = reopen_hub_fn,
            })
        end,
        on_memorization = function(reopen_hub_fn)
            release_highlight_for_reading(hl)
            run_memorization_flow(hl, ctx, ui, {
                parent_fn = reopen_hub_fn,
            })
        end,
        reopen_highlight_menu = function()
            reopen_highlight_menu(hl, ctx.index, ctx.selected_text)
        end,
        on_dismiss = function()
            release_highlight_for_reading(hl)
        end,
    }
end

local function open_hub_from_context(hl, ctx, ui)
    UIManager:scheduleIn(0.05, function()
        PluginMenu.show(hl, ctx, ui, CONFIGURATION, hub_menu_actions(hl, ctx, ui))
    end)
end

local function open_highlight_inbox(hl, ctx, ui, inbox_opts)
    inbox_opts = inbox_opts or {}
    inbox_opts.title_prefix = inbox_opts.title_prefix or _("View All Highlights")
    if hl and ctx and not inbox_opts.on_back then
        inbox_opts.on_back = function()
            reopen_highlight_menu(hl, ctx.index, ctx.selected_text)
        end
        inbox_opts.back_label = inbox_opts.back_label or _("← Back to highlight menu")
    end
    HighlightInbox.show(ui, CONFIGURATION, inbox_opts)
end

local function dict_popup_context(hl, popup)
    local ctx = capture_highlight_context(hl, nil)
    if not ctx.text or ctx.text == "" then
        ctx.text = (popup and (popup.lookupword or popup.word)) or ""
    end
    return ctx
end

local function start_hub_from_dict_popup(ui, popup)
    local hl = (popup and popup.highlight) or ui.highlight
    local ctx = dict_popup_context(hl, popup)
    if popup and popup.onClose then
        popup:onClose(true)
    end
    open_hub_from_context(hl, ctx, ui)
end

local function start_vocab_from_dict_popup(ui, popup)
    local hl = (popup and popup.highlight) or ui.highlight
    local ctx = dict_popup_context(hl, popup)
    local prefill = nil
    if DictionaryLookup and DictionaryLookup.lookup_from_popup then
        prefill = DictionaryLookup.lookup_from_popup(popup, {
            preferred_dictionary = CardDefaults.vocabulary_dictionary(CONFIGURATION),
        })
    end
    -- Close the popup but keep the word selection (no_clear=true) so the card
    -- flow can promote it into a saved highlight.
    if popup and popup.onClose then
        popup:onClose(true)
    end
    UIManager:scheduleIn(0.05, function()
        run_dictionary_vocabulary_flow(hl, ctx, ui, { prefill_lookup = prefill })
    end)
end

local function dict_popup_show(dict_popup)
    return not dict_popup.is_wiki
        and not dict_popup:isDocless()
        and dict_popup.highlight ~= nil
end

function AnkiKOAi:init()
    if not self.ui or not self.ui.highlight then
        logger.warn(PluginConstants.ID, "highlight module not available — plugin not loaded")
        return
    end

    local HighlightCleanup = require("highlight_cleanup")
    UIManager:nextTick(function()
        HighlightCleanup.run(self.ui)
    end)

    -- ── AnkiKOAi hub (single highlight-menu entry) ──────────────────────────
    local ok, err = pcall(function()
    self.ui.highlight:addToHighlightDialog(PluginConstants.HIGHLIGHT_DIALOG_ID_HUB, function(hl, index)
        return {
            text      = PluginConstants.NAME,
            font_bold = true,
            enabled   = true,
            callback = function()
                local ctx = capture_highlight_context(hl, index)
                dismiss_highlight_dialog(hl)
                open_hub_from_context(hl, ctx, self.ui)
            end,
        }
    end)

    self.ui.highlight:addToHighlightDialog(PluginConstants.HIGHLIGHT_DIALOG_ID_MEM, function(hl, index)
        return {
            text      = _("Memorize"),
            font_bold = true,
            enabled   = true,
            show_in_highlight_dialog_func = function()
                return CardDefaults.quick_highlight_button(CONFIGURATION)
            end,
            callback = function()
                local ctx = capture_highlight_context(hl, index)
                dismiss_highlight_dialog(hl)
                release_highlight_for_reading(hl)
                UIManager:scheduleIn(0.05, function()
                    run_memorization_flow(hl, ctx, self.ui, {})
                end)
            end,
        }
    end)

    self.ui.highlight:addToHighlightDialog(
        PluginConstants.HIGHLIGHT_DIALOG_ID_VIEW_ALL or "97_ankikooai_view_all",
        function(hl, index)
        return {
            text    = _("View All Highlights"),
            font_bold = true,
            enabled = true,
            show_in_highlight_dialog_func = function()
                return true
            end,
            callback = function()
                local ctx = capture_highlight_context(hl, index)
                dismiss_highlight_dialog(hl)
                release_highlight_for_reading(hl)
                UIManager:scheduleIn(0.05, function()
                    open_highlight_inbox(hl, ctx, self.ui)
                end)
            end,
        }
    end)

    -- ── Vocabulary Card from the single-word dictionary popup ──────────────────
    -- Long-pressing a single word opens KOReader's dictionary popup
    -- (DictQuickLookup). Newer KOReader builds (master) expose
    -- ReaderDictionary:addToDictButtons; older/stable builds (e.g. v2026.03)
    -- instead broadcast a DictButtonsReady event handled by onDictButtonsReady
    -- below. We support both; they are mutually exclusive across versions.
    if self.ui.dictionary and self.ui.dictionary.addToDictButtons then
        self.ui.dictionary:addToDictButtons({
            id          = "ankikooai_hub",
            text        = PluginConstants.NAME,
            font_bold   = true,
            conditional = true,
            show_func   = dict_popup_show,
            callback    = function(dict_popup)
                start_hub_from_dict_popup(self.ui, dict_popup)
            end,
        })
        self.ui.dictionary:addToDictButtons({
            id          = "ankikooai_vocab",
            text        = _("Create Vocab Card"),
            font_bold   = true,
            conditional = true,
            show_func   = dict_popup_show,
            callback    = function(dict_popup)
                start_vocab_from_dict_popup(self.ui, dict_popup)
            end,
        })
    end

    -- ── Tap-to-Show Flashcard ─────────────────────────────────────────────────
    -- Short tap on a highlight with a saved card → show card viewer directly.
    -- No saved card → fall through to original highlight menu.
    local highlight_module = self.ui.highlight
    local orig_onTap = highlight_module.onTap
    local plugin_self = self

    highlight_module.onTap = function(hl_self, arg, ges)
        -- Pass through if mid-hold or no gesture
        if hl_self.hold_pos or not ges then
            return orig_onTap(hl_self, arg, ges)
        end
        local visible = hl_self.view and hl_self.view.highlight
                        and hl_self.view.highlight.visible_boxes
        if not visible or #visible == 0 then
            return orig_onTap(hl_self, arg, ges)
        end
        local pos = hl_self.view:screenToPageTransform(ges.pos)
        if not pos then
            return orig_onTap(hl_self, arg, ges)
        end

        -- Find tapped highlight and check for a saved card
        for _i, box in ipairs(visible) do
            local r = box.rect
            if r and pos.x >= r.x and pos.y >= r.y
               and pos.x <= r.x + r.w and pos.y <= r.y + r.h then
                local ann = hl_self.ui.annotation.annotations[box.index]
                if ann then
                    local card = CardStorage.find_by_position(ann.pos0, ann.pos1)
                                 or (ann.text and CardStorage.find_by_phrase_fuzzy(ann.text))
                    if card then
                        local hl_index = box.index
                        local viewer_ref = {}
                        local function make_viewer(show_back)
                            local v
                            v = CardViewer:new {
                                card      = card,
                                show_back = show_back,
                                read_only = false,
                                on_show_answer = function()
                                    local cur = viewer_ref[1] or v
                                    UIManager:close(cur)
                                    viewer_ref[1] = make_viewer(true)
                                end,
                                on_show_front = function()
                                    local cur = viewer_ref[1] or v
                                    UIManager:close(cur)
                                    viewer_ref[1] = make_viewer(false)
                                end,
                                on_save = function()
                                    CardStorage.save_or_update(card)
                                    return true
                                end,
                                on_update = function(updated_card)
                                    CardStorage.save_or_update(updated_card)
                                end,
                                on_highlight_dialog = function()
                                    hl_self:showHighlightDialog(hl_index)
                                end,
                            }
                            attach_send_callbacks(v, card, hl_self.ui)
                            UIManager:show(v)
                            return v
                        end
                        viewer_ref[1] = make_viewer(false)
                        return true
                    elseif ann.color == PluginConstants.HIGHLIGHT_COLOR_SENT then
                        UIManager:show(InfoMessage:new {
                            text    = _("Sent to Anki — see Recently sent"),
                            timeout = 3,
                        })
                        return true
                    end

                    -- ── Quick Lookup for purple highlights ───────────────
                    if ann.color == "purple" and ann.text and ann.text ~= "" then
                        local phrase_text = ann.text
                        local ann_ref     = ann
                        local ui_ref      = hl_self.ui
                        local hl_idx      = box.index

                        -- Delete callback: removes the highlight via KOReader's API.
                        local function delete_highlight()
                            hl_self:deleteHighlight(hl_idx)
                        end

                        -- Check annotation note for a previously saved lookup.
                        if ann_ref.note and ann_ref.note:match("^%[IPA%]") then
                            local ipa = ann_ref.note:match("%[IPA%] (.-) | ")
                            local def = ann_ref.note:match("| (.+)$")
                            if ipa and def then
                                show_quick_lookup_popup(phrase_text, { ipa = ipa, definition = def }, delete_highlight)
                                return true
                            end
                        end

                        -- Check session cache.
                        if quick_lookup_cache[phrase_text] then
                            show_quick_lookup_popup(phrase_text, quick_lookup_cache[phrase_text], delete_highlight)
                            return true
                        end

                        if not NetworkMgr:isOnline() then
                            -- Offline: fall through to normal highlight menu.
                            break
                        end
                        local loading = Notification:new {
                            text    = _("Looking up: ") .. phrase_text,
                            timeout = 15,
                        }
                        UIManager:show(loading)
                        UIManager:scheduleIn(0.05, function()
                            UIManager:close(loading)
                            local result, err = CardGenerator.generate_quick_lookup(
                                CONFIGURATION, phrase_text
                            )
                            if result then
                                quick_lookup_cache[phrase_text] = result
                                -- Persist to annotation note for offline access.
                                ann_ref.note = "[IPA] " .. (result.ipa or "")
                                            .. " | " .. (result.definition or "")
                                local Event = require("ui/event")
                                ui_ref:handleEvent(Event:new("AnnotationsModified",
                                    { ann_ref, nb_highlights_added = 0, nb_notes_added = 1 }))
                                show_quick_lookup_popup(phrase_text, result, delete_highlight)
                            else
                                UIManager:show(InfoMessage:new {
                                    text    = _("Lookup failed: ") .. (err or "unknown"),
                                    timeout = 3,
                                })
                            end
                        end)
                        return true
                    end
                end
                break  -- only check first hit; fall through to original
            end
        end
        return orig_onTap(hl_self, arg, ges)
    end

    -- ── Auto-Send on WiFi ────────────────────────────────────────────────────
    -- Polls every 20 min when WiFi is on and auto_send_wifi is enabled,
    -- flushes all unsent cards to AnkiConnect silently in the background.
    local AUTO_SEND_INTERVAL = 20 * 60  -- seconds between checks (20 minutes)
    local AUTO_SEND_BACKOFF_MAX = 60 * 60 -- extra delay cap when Anki stays unreachable
    local auto_send_backoff = 0
    local function auto_send_tick()
        local wait = AUTO_SEND_INTERVAL + auto_send_backoff
        UIManager:scheduleIn(wait, auto_send_tick)
        local cfg = get_anki_config()
        if not cfg.auto_send_wifi then return end
        if not cfg.url or cfg.url == "" then return end
        if not NetworkMgr:isOnline() then return end
        if CardStorage.count_unsent() == 0 then
            auto_send_backoff = 0
            return
        end
        if CardManager.is_send_all_in_progress() then
            return
        end

        -- Silent background flush — never show Trapper/progress while reading.
        -- (UiBusy here caused random "Sending saved cards to Anki…" overlays on
        -- the Kindle when Anki was off but WiFi was on and cards were pending.)
        UIManager:scheduleIn(0, function()
            CardManager.send_all_unsent(CONFIGURATION, nil, {
                background = true,
                on_done = function(sent, failed, reconciled)
                    if (sent or 0) + (reconciled or 0) > 0 then
                        auto_send_backoff = 0
                    elseif (failed or 0) == 0 and CardStorage.count_unsent() > 0 then
                        -- Anki unreachable (precheck failed); back off, don't hammer.
                        auto_send_backoff = math.min(
                            AUTO_SEND_BACKOFF_MAX,
                            auto_send_backoff + AUTO_SEND_INTERVAL
                        )
                    end
                end,
            })
        end)
    end
    -- First check after one interval to let KOReader settle on startup.
    UIManager:scheduleIn(AUTO_SEND_INTERVAL, auto_send_tick)

    if PENDING_MIGRATION_NOTICE then
        local notice = PENDING_MIGRATION_NOTICE
        PENDING_MIGRATION_NOTICE = nil
        UIManager:scheduleIn(2, function()
            UIManager:show(Notification:new {
                text    = notice,
                timeout = 8,
            })
        end)
    end

    -- ── Auto-Sync on Startup ──────────────────────────────────────────────
    -- One-shot silent cloud sync 45s after startup.
    UIManager:scheduleIn(45, function()
        local cfg = get_anki_config()
        if cfg.sync_server and NetworkMgr:isOnline() then
            CardSync.run_sync(cfg.sync_server, true)
        end
    end)

    end)
    if not ok then
        local trace = debug.traceback(tostring(err), 2)
        logger.warn(PluginConstants.ID, "init failed:", trace)
        UIManager:show(InfoMessage:new {
            text    = _("AnkiKOAi failed to load: ") .. tostring(err),
            timeout = 8,
        })
    end

end

-- Add a "Create Vocab Card" button to the single-word dictionary popup.
-- KOReader (stable builds, e.g. v2026.03) broadcasts DictButtonsReady with the
-- popup instance and its button table (rows of button specs) for plugins to
-- modify in place. We append a new row; we must NOT return true, so other
-- plugins (e.g. vocabulary builder) can still add their own buttons.
function AnkiKOAi:onDictButtonsReady(popup, buttons)
    if not popup or popup.is_wiki or popup.is_wiki_fullpage then return end
    if popup.highlight == nil then return end
    if type(buttons) ~= "table" then return end
    local has_hub, has_vocab = false, false
    for _i, row in ipairs(buttons) do
        if type(row) == "table" then
            for _j, btn in ipairs(row) do
                if btn.id == "ankikooai_hub" then has_hub = true end
                if btn.id == "ankikooai_vocab" then has_vocab = true end
            end
        end
    end
    if has_hub and has_vocab then return end
    local ui = self.ui
    table.insert(buttons, {
        {
            id        = "ankikooai_hub",
            text      = PluginConstants.NAME,
            font_bold = true,
            callback  = function()
                start_hub_from_dict_popup(ui, popup)
            end,
        },
        {
            id        = "ankikooai_vocab",
            text      = _("Create Vocab Card"),
            font_bold = true,
            callback  = function()
                start_vocab_from_dict_popup(ui, popup)
            end,
        },
    })
end

return AnkiKOAi
