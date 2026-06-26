-- Settings UI for AnkiKOAi.
-- Settings are saved to ankikooai_settings.json in the KOReader data dir.

local ButtonDialog   = require("ui/widget/buttondialog")
local ConfirmBox     = require("ui/widget/confirmbox")
local InfoMessage    = require("ui/widget/infomessage")
local InputDialog    = require("ui/widget/inputdialog")
local Menu           = require("ui/widget/menu")
local Notification   = require("ui/widget/notification")
local UIManager      = require("ui/uimanager")
local _              = require("gettext")

local AnkiSync       = require("anki_sync")
local CardFields     = require("card_fields")
local CardStorage    = require("card_storage")
local CardSync       = require("card_sync")
local CardDefaults   = require("card_defaults")
local DeckPicker         = require("deck_picker")
local Nav                = require("nav")
local NoteTypeProfiles   = require("note_type_profiles")
local NoteTypePicker     = require("note_type_picker")
local PluginConstants    = require("plugin_constants")
local PoetryMemorize     = require("poetry_memorize")
local PromptBuilder      = require("prompt_builder")

local SettingsViewer = {}

function SettingsViewer.show(base_config, on_saved, viewer_opts)
    viewer_opts = viewer_opts or {}
    local settings_parent_fn = viewer_opts.parent_fn
    -- Work on a merged copy: start with top-level config keys (API keys,
    -- provider settings), then overlay the anki subtable, then saved
    -- on-device settings on top so they take priority.
    local cfg = {}
    if base_config then
        for k, v in pairs(base_config) do
            if k ~= "anki" then cfg[k] = v end
        end
        if type(base_config.anki) == "table" then
            for k, v in pairs(base_config.anki) do cfg[k] = v end
        end
    end
    local saved = CardStorage.load_anki_settings()
    if saved then
        for k, v in pairs(saved) do cfg[k] = v end
    end
    local _migrated_cfg, migrate_msg = CardFields.migrate_anki_settings(cfg)
    if migrate_msg then
        CardStorage.save_anki_settings(cfg)
        UIManager:scheduleIn(0.2, function()
            UIManager:show(Notification:new {
                text    = migrate_msg,
                timeout = 8,
            })
        end)
    end
    if cfg.text_provider == "ankivocab" then
        cfg.text_provider = "dashscope"
    end
    cfg.custom_prompts = cfg.custom_prompts or {}
    local wiki_default = CardFields.default_wiki_model({ anki = cfg })
    if not cfg.prompt_edit_model or cfg.prompt_edit_model == "" then
        cfg.prompt_edit_model = wiki_default
    end

    local function wiki_note_type_value()
        return cfg.wiki_note_type or cfg.model or NoteTypeProfiles.DEFAULT_MODEL
    end

    local function sync_wiki_note_type(name)
        cfg.wiki_note_type = name
        cfg.model = name
    end

    -- ── Shared helpers ───────────────────────────────────────────────────

    local function val(key)
        local v = cfg[key]
        if key == "tags" and type(v) == "table" then
            return table.concat(v, ", ")
        end
        if v == nil or v == "" then return "" end
        return tostring(v)
    end

    local function short(key, max)
        local v = val(key)
        max = max or 30
        if #v > max then return v:sub(1, max) .. ".." end
        return v ~= "" and v or "(not set)"
    end

    local function mask_key(k)
        if not k or k == "" or k:find("^YOUR_") then return "(not set)" end
        return "\xE2\x80\xA2\xE2\x80\xA2\xE2\x80\xA2\xE2\x80\xA2" .. k:sub(-1)
    end

    local function save()
        CardFields.migrate_anki_settings(cfg)
        CardStorage.save_anki_settings(cfg)
        if on_saved then on_saved(cfg) end
    end

    local function current_book_title()
        local ui = viewer_opts.ui
        if ui and ui.document then
            local title = (ui.document:getProps().title or ""):match("^%s*(.-)%s*$") or ""
            if #title > 100 then title = title:sub(1, 100) end
            if title ~= "" then return title end
        end
        return ""
    end

    local map_book_to_deck

    -- Forward declarations for submenu functions.
    local show_main, show_ai_providers
    local show_api_keys, show_sync, show_prompts
    local show_memorization, show_defaults
    local show_defaults_wiki, show_defaults_vocab, show_defaults_mem
    local show_where_cards_go, show_deck_picker_shortcuts, show_book_overrides
    local show_favorite_decks
    local show_anki_connection, show_tags

    local CHECK_ON = "\xe2\x9c\x93 "

    local function toggle_label(on, label)
        if on then return CHECK_ON .. label .. ": ON" end
        return label .. ": OFF"
    end

    local SETTINGS_HELP_SUBTITLE = _("Tap gray rows for help.")

    local function show_settings_help(text)
        UIManager:show(InfoMessage:new {
            text    = text,
            timeout = 8,
        })
    end

    local function info_menu_item(label, help_text)
        return {
            text     = label,
            dim      = true,
            callback = function() show_settings_help(help_text) end,
        }
    end

    local function open_settings_menu(title, item_table, on_close, subtitle)
        local menu_instance
        menu_instance = Nav.wrap_menu(Menu:new(Nav.apply_compact_menu {
            title      = title,
            subtitle   = subtitle or SETTINGS_HELP_SUBTITLE,
            item_table = item_table,
        }), function()
            Nav.after_close(function()
                if menu_instance then UIManager:close(menu_instance) end
            end, on_close or function() end)
        end)
        Nav.show(menu_instance)
        return menu_instance
    end

    local function close_menu_then(menu_instance, fn)
        Nav.after_close(function()
            if menu_instance then UIManager:close(menu_instance) end
        end, fn)
    end

    local memorization_parent_fn = function() show_main() end
    local prompts_parent_fn = function() show_ai_providers() end

    local function migrate_on_wiki_model_change(old_model, new_model)
        cfg.custom_prompts = cfg.custom_prompts or {}
        PromptBuilder.migrate_model_prompt(cfg.custom_prompts, old_model, new_model)
        if cfg.prompt_edit_model == old_model then
            cfg.prompt_edit_model = new_model
        end
    end

    -- Helper: show an InputDialog for editing a text field.
    local function edit_field(title, key, hint, parent_fn, transform)
        local edit_dlg
        edit_dlg = InputDialog:new {
            title      = _(title),
            input      = val(key),
            input_hint = hint,
            buttons    = {{
                {
                    text     = _("Cancel"),
                    callback = function()
                        UIManager:close(edit_dlg)
                        parent_fn()
                    end,
                },
                {
                    text             = _("Save"),
                    is_enter_default = true,
                    callback         = function()
                        local new_val = edit_dlg:getInputText() or ""
                        UIManager:close(edit_dlg)
                        if transform then
                            transform(new_val)
                        else
                            cfg[key] = new_val
                        end
                        save()
                        parent_fn()
                    end,
                },
            }},
        }
        UIManager:show(edit_dlg)
        edit_dlg:onShowKeyboard()
    end

    -- Helper: show an InputDialog for editing an API key.
    local function edit_key(label, key, parent_fn)
        local raw = cfg[key] or ""
        local edit_dlg
        edit_dlg = InputDialog:new {
            title      = _(label),
            input      = (raw:find("^YOUR_") and "" or raw),
            input_hint = _("Paste your API key here"),
            buttons    = {{
                {
                    text     = _("Cancel"),
                    callback = function()
                        UIManager:close(edit_dlg)
                        parent_fn()
                    end,
                },
                {
                    text             = _("Save"),
                    is_enter_default = true,
                    callback         = function()
                        local new_key = edit_dlg:getInputText() or ""
                        UIManager:close(edit_dlg)
                        cfg[key] = new_key
                        save()
                        parent_fn()
                    end,
                },
            }},
        }
        UIManager:show(edit_dlg)
        edit_dlg:onShowKeyboard()
    end

    -- ── Submenu: AI Settings ─────────────────────────────────────────────

    show_ai_providers = function()
        local TEXT_PROVIDERS = { "dashscope", "gemini", "openai", "openrouter" }
        local menu_instance
        local wiki_on = cfg.use_wiki_sources ~= false
        local strict_on = cfg.strict_accuracy == true

        local function cycle(key, options)
            local cur = cfg[key] or options[1]
            local idx = 1
            for i, p in ipairs(options) do
                if p == cur then idx = i; break end
            end
            cfg[key] = options[(idx % #options) + 1]
            save()
            Nav.after_close(function()
                if menu_instance then UIManager:close(menu_instance) end
            end, show_ai_providers)
        end

        local strict_help
        if strict_on then
            strict_help = _(
                "Strict accuracy is ON. The AI adds extra rules: if not confident about any field, it must write exactly \"Unclear from context\" for that field. It should never guess to seem informative.\n\nStandard accuracy rules still apply (no invented citations, quotes, or sources)."
            )
        else
            strict_help = _(
                "Strict accuracy is OFF. Standard accuracy rules apply: state only confident facts, do not invent citations or quotes, prefer what the passage supports.\n\nTurn ON to require \"Unclear from context\" whenever the AI is not confident about a field."
            )
        end

        local item_table = {
            info_menu_item(_("About AI Settings"), _(
                "These settings apply to Wiki Card (AI) generation only — not Vocabulary or Memorization cards.\n\nChoose a text provider, enter API keys, and optionally adjust Wiki sources, Strict accuracy, and target language. Prompts & suffix opens advanced prompt editing."
            )),
            info_menu_item(_("About Strict accuracy"), strict_help),
            info_menu_item(_("About Wiki sources"), wiki_on
                and _(
                    "Wiki sources is ON. The plugin fetches Wiktionary and Wikipedia excerpts for prompts and uses wiki-specific accuracy rules (treat excerpts as primary sources; do not contradict them).\n\nTurn OFF to use passage-only accuracy rules without Wikimedia excerpts."
                )
                or _(
                    "Wiki sources is OFF. Prompts use passage-only accuracy rules without Wikimedia excerpts.\n\nTurn ON to fetch Wiktionary/Wikipedia snippets and add wiki-specific accuracy rules."
                )),
            info_menu_item(_("About target language"), _(
                "Target language for AI-generated card text (definitions, exploration articles, and notes). Example: English, German, Japanese."
            )),
            {
                text = _("Provider: ") .. (cfg.text_provider or "dashscope"),
                callback = function() cycle("text_provider", TEXT_PROVIDERS) end,
            },
            {
                text = _("API Keys…"),
                callback = function()
                    close_menu_then(menu_instance, show_api_keys)
                end,
            },
            {
                text = wiki_on and _("Wiki sources: ON") or _("Wiki sources: OFF"),
                callback = function()
                    cfg.use_wiki_sources = not wiki_on
                    save()
                    Nav.after_close(function()
                        if menu_instance then UIManager:close(menu_instance) end
                    end, show_ai_providers)
                end,
            },
            {
                text = strict_on and _("Strict accuracy: ON") or _("Strict accuracy: OFF"),
                callback = function()
                    cfg.strict_accuracy = not strict_on
                    save()
                    Nav.after_close(function()
                        if menu_instance then UIManager:close(menu_instance) end
                    end, show_ai_providers)
                end,
            },
            {
                text = _("Language: ") .. (cfg.target_language or "English"),
                callback = function()
                    close_menu_then(menu_instance, function()
                        edit_field("Target Language", "target_language",
                            "English", show_ai_providers)
                    end)
                end,
            },
            {
                text = _("Prompts & suffix"),
                callback = function()
                    close_menu_then(menu_instance, show_prompts)
                end,
            },
            {
                text = _("← Back"),
                callback = function() close_menu_then(menu_instance, show_main) end,
            },
        }

        menu_instance = open_settings_menu(_("AI Settings"), item_table, show_main)
    end

    -- ── Submenu: Prompts ───────────────────────────────────────────────

    local PROMPTS_DEFAULTS = {
        prompt_suffix      = "",
        prompt_edit_model  = NoteTypeProfiles.DEFAULT_MODEL,
        custom_prompts     = {},
    }

    local prompts_draft = nil

    local function prompts_snapshot_from_cfg()
        return {
            prompt_suffix = cfg.prompt_suffix or "",
            prompt_edit_model = (cfg.prompt_edit_model and cfg.prompt_edit_model ~= "")
                and cfg.prompt_edit_model
                or wiki_note_type_value(),
            custom_prompts = PromptBuilder.copy_custom_prompts(cfg.custom_prompts),
        }
    end

    local function prompts_drafts_equal(a, b)
        if not a or not b then return false end
        if a.prompt_suffix ~= b.prompt_suffix then return false end
        if a.prompt_edit_model ~= b.prompt_edit_model then return false end
        local keys = {}
        for k in pairs(a.custom_prompts or {}) do keys[k] = true end
        for k in pairs(b.custom_prompts or {}) do keys[k] = true end
        for k in pairs(keys) do
            if (a.custom_prompts[k] or "") ~= (b.custom_prompts[k] or "") then
                return false
            end
        end
        return true
    end

    local function apply_prompts_draft(draft)
        cfg.prompt_suffix = draft.prompt_suffix or ""
        cfg.prompt_edit_model = wiki_note_type_value()
        draft.prompt_edit_model = cfg.prompt_edit_model
        cfg.custom_prompts = PromptBuilder.copy_custom_prompts(draft.custom_prompts)
    end

    local function suffix_button_label(sfx)
        sfx = sfx or ""
        if sfx == "" then return _("(empty)") end
        if #sfx > 22 then return sfx:sub(1, 22) .. ".." end
        return sfx
    end

    local function custom_prompt_status(custom_prompts, key)
        local txt = custom_prompts and custom_prompts[key]
        if txt and txt ~= "" then return _("(custom)") end
        return _("(default)")
    end

    local PREVIEW_MAX_CHARS = 32000

    show_prompts = function()
        if not prompts_draft then
            prompts_draft = prompts_snapshot_from_cfg()
        end
        local draft = prompts_draft
        draft.prompt_edit_model = wiki_note_type_value()
        local saved_snapshot = prompts_snapshot_from_cfg()
        saved_snapshot.prompt_edit_model = wiki_note_type_value()
        local edit_model = wiki_note_type_value()
        local regen_key = PromptBuilder.regen_key(edit_model)
        local suffix = draft.prompt_suffix or ""
        local menu_instance

        local function open_prompt_preview(title, build_fn)
            close_menu_then(menu_instance, function()
                UIManager:scheduleIn(0.05, function()
                    local ok, body = pcall(build_fn)
                    if not ok then
                        UIManager:show(InfoMessage:new {
                            text    = _("Preview failed: ") .. tostring(body),
                            timeout = 6,
                        })
                        show_prompts()
                        return
                    end
                    if type(body) ~= "string" then body = tostring(body or "") end
                    if #body > PREVIEW_MAX_CHARS then
                        body = body:sub(1, PREVIEW_MAX_CHARS)
                            .. _("\n\n[Preview truncated — prompt is very long.]")
                    end
                    local rv_ok, ReadmeViewer = pcall(require, "readme_viewer")
                    if rv_ok and ReadmeViewer and ReadmeViewer.show_text_or_notify then
                        ReadmeViewer.show_text_or_notify(title, body, {
                            on_close = show_prompts,
                        })
                    else
                        UIManager:show(InfoMessage:new {
                            text    = _("Preview unavailable"),
                            timeout = 5,
                        })
                        show_prompts()
                    end
                end)
            end)
        end

        local function reopen_prompts()
            Nav.after_close(function()
                if menu_instance then UIManager:close(menu_instance) end
            end, show_prompts)
        end

        local function discard_and_close()
            prompts_draft = nil
            close_menu_then(menu_instance, prompts_parent_fn)
        end

        local function close_without_saving()
            if prompts_drafts_equal(draft, saved_snapshot) then
                discard_and_close()
                return
            end
            UIManager:show(ConfirmBox:new {
                text = _("Discard prompt changes?"),
                ok_text = _("Discard"),
                ok_callback = discard_and_close,
                cancel_text = _("Keep editing"),
            })
        end

        local function save_and_close()
            apply_prompts_draft(draft)
            save()
            prompts_draft = nil
            close_menu_then(menu_instance, prompts_parent_fn)
        end

        local function edit_prompt_field(title, key, hint, empty_ok)
            close_menu_then(menu_instance, function()
                local cur = (draft.custom_prompts and draft.custom_prompts[key]) or ""
                local edit_dlg
                edit_dlg = InputDialog:new {
                    title = title,
                    input = cur,
                    input_hint = hint,
                    buttons = {{
                        { text = _("Cancel"), callback = function()
                            UIManager:close(edit_dlg)
                            show_prompts()
                        end },
                        { text = _("Apply"), is_enter_default = true, callback = function()
                            local txt = edit_dlg:getInputText() or ""
                            UIManager:close(edit_dlg)
                            draft.custom_prompts = draft.custom_prompts or {}
                            if txt == "" and empty_ok then
                                draft.custom_prompts[key] = nil
                            else
                                draft.custom_prompts[key] = txt
                            end
                            show_prompts()
                        end },
                    }},
                }
                UIManager:show(edit_dlg)
                edit_dlg:onShowKeyboard()
            end)
        end

        local function edit_suffix()
            close_menu_then(menu_instance, function()
                local edit_dlg
                edit_dlg = InputDialog:new {
                    title = _("Prompt Suffix"),
                    input = suffix,
                    input_hint = _("Always emphasize etymology."),
                    buttons = {{
                        { text = _("Cancel"), callback = function()
                            UIManager:close(edit_dlg)
                            show_prompts()
                        end },
                        { text = _("Apply"), is_enter_default = true, callback = function()
                            draft.prompt_suffix = edit_dlg:getInputText() or ""
                            UIManager:close(edit_dlg)
                            show_prompts()
                        end },
                    }},
                }
                UIManager:show(edit_dlg)
                edit_dlg:onShowKeyboard()
            end)
        end

        local note_type_line = edit_model
        if #note_type_line > 28 then
            note_type_line = note_type_line:sub(1, 25) .. "…"
        end

        local item_table = {
            info_menu_item(_("About Prompts & suffix"), _(
                "Customize AI prompts for Wiki Card generation only — not Vocabulary or Memorization.\n\nPrompts apply to the note type set under Card defaults → Wiki Card (currently: "
            ) .. edit_model .. _(
                "). Changes are drafts until you tap Save."
            )),
            info_menu_item(_("About prompt suffix"), _(
                "Short extra instructions appended to every AI prompt (generate and regen). Leave empty to use built-in defaults only."
            )),
            info_menu_item(_("About generate prompt"), _(
                "The main template used when creating a new Wiki Card from a highlight. A custom template replaces the built-in profile for this note type; leave empty to use the default."
            )),
            info_menu_item(_("About regen prompt"), _(
                "Template for Regenerate broader context in the card preview. Stored separately from the generate prompt."
            )),
            {
                text = _("Note type: ") .. note_type_line,
                dim  = true,
                callback = function()
                    show_settings_help(_(
                        "Prompts are edited for your Wiki Card note type from Card defaults → Wiki Card.\n\nTo use a different note type, change it there — custom prompts migrate automatically when possible."
                    ) .. "\n\n" .. _("Current: ") .. edit_model)
                end,
            },
            {
                text = _("View default generate prompt"),
                dim  = true,
                callback = function()
                    open_prompt_preview(_("Default generate prompt"), function()
                        return PromptBuilder.preview_generate_builtin(cfg, draft, edit_model)
                    end)
                end,
            },
            {
                text = _("View default regen prompt"),
                dim  = true,
                callback = function()
                    open_prompt_preview(_("Default regen prompt"), function()
                        return PromptBuilder.preview_regen_builtin(cfg, draft, edit_model)
                    end)
                end,
            },
            {
                text = _("Modify prompt suffix…") .. " " .. suffix_button_label(suffix),
                callback = edit_suffix,
            },
            {
                text = _("Modify generate prompt…")
                    .. " " .. custom_prompt_status(draft.custom_prompts, edit_model),
                callback = function()
                    edit_prompt_field(
                        _("Custom generate prompt for ") .. edit_model,
                        edit_model,
                        _("Leave empty to use default profile"),
                        true)
                end,
            },
            {
                text = _("Modify regen prompt…")
                    .. " " .. custom_prompt_status(draft.custom_prompts, regen_key),
                callback = function()
                    edit_prompt_field(
                        _("Custom regen prompt for ") .. edit_model,
                        regen_key,
                        _("Leave empty to use default regen profile"),
                        true)
                end,
            },
            {
                text = _("Reset generate prompt"),
                callback = function()
                    if draft.custom_prompts then
                        draft.custom_prompts[edit_model] = nil
                    end
                    reopen_prompts()
                end,
            },
            {
                text = _("Reset regen prompt"),
                callback = function()
                    if draft.custom_prompts then
                        draft.custom_prompts[regen_key] = nil
                    end
                    reopen_prompts()
                end,
            },
            {
                text = _("Preview effective generate prompt"),
                callback = function()
                    open_prompt_preview(_("Effective generate prompt"), function()
                        return PromptBuilder.preview_generate(cfg, draft, edit_model)
                    end)
                end,
            },
            {
                text = _("Preview effective regen prompt"),
                callback = function()
                    open_prompt_preview(_("Effective regen prompt"), function()
                        return PromptBuilder.preview_regen(cfg, draft, edit_model)
                    end)
                end,
            },
            {
                text = _("View README"),
                callback = function()
                    close_menu_then(menu_instance, function()
                        local ok, ReadmeViewer = pcall(require, "readme_viewer")
                        if ok and ReadmeViewer.show_or_notify then
                            ReadmeViewer.show_or_notify("prompts", {
                                on_close = show_prompts,
                            })
                        else
                            show_prompts()
                        end
                    end)
                end,
            },
            {
                text = _("Restore defaults"),
                callback = function()
                    draft.prompt_suffix = PROMPTS_DEFAULTS.prompt_suffix
                    draft.custom_prompts = {}
                    reopen_prompts()
                end,
            },
            {
                text = _("Save"),
                callback = save_and_close,
            },
            {
                text = _("Close without saving"),
                callback = close_without_saving,
            },
            {
                text = _("← Back"),
                callback = function()
                    if prompts_drafts_equal(draft, saved_snapshot) then
                        close_menu_then(menu_instance, function()
                            prompts_draft = nil
                            show_ai_providers()
                        end)
                    else
                        close_without_saving()
                    end
                end,
            },
        }

        menu_instance = open_settings_menu(_("Prompts & suffix"), item_table, function()
            if not prompts_drafts_equal(draft, saved_snapshot) then
                close_without_saving()
            else
                discard_and_close()
            end
        end)
    end

    -- ── Deck routing (Wiki & Vocabulary) ───────────────────────────────

    local function resolved_deck_for(card)
        local base = AnkiSync.resolve_base_deck(cfg, card)
        return AnkiSync.resolve_deck_name(cfg, card, base)
    end

    local function routing_preview_lines()
        local book = current_book_title()
        local wiki_card = {
            book_title = book,
            model      = CardDefaults.wiki_model({ anki = cfg }),
        }
        local vocab_card = {
            book_title = book,
            model      = CardDefaults.vocabulary_model({ anki = cfg }),
        }
        local lines = {}
        if book == "" then
            table.insert(lines, _("No book open — preview uses defaults only"))
        else
            table.insert(lines, _("Book: ") .. book)
        end
        table.insert(lines, _("Wiki → ") .. (resolved_deck_for(wiki_card) or ""))
        table.insert(lines, _("Vocab → ") .. (resolved_deck_for(vocab_card) or ""))
        return lines
    end

    local function routing_help_book()
        local book = current_book_title()
        if book == "" then
            return _(
                "No book is open. Open a book to preview subdeck routing. Book overrides match each card's book_title field exactly."
            )
        end
        return _(
            "This title comes from the open book's metadata. Book overrides must match this string exactly. It is also used when Append book title to deck name is ON.\n\nCurrent title: "
        ) .. book
    end

    local function routing_help_for_card(card, defaults_label)
        local resolved = resolved_deck_for(card) or ""
        local subdeck_on = cfg.subdeck_by_book ~= false
        local step3 = subdeck_on
            and _("If Append book title is ON, adds ::Book Title to the parent deck segment.")
            or _("Append book title is OFF — no subdeck suffix is added.")
        return defaults_label .. _(" deck resolution:") .. "\n"
            .. _("1. Default deck (Card defaults → ") .. defaults_label .. ")\n"
            .. _("2. Book override for this title, if set\n")
            .. "3. " .. step3 .. "\n\n"
            .. _("Current result: ") .. resolved
    end

    map_book_to_deck = function(book, parent_fn)
        book = (book or ""):match("^%s*(.-)%s*$") or ""
        if book == "" then
            parent_fn()
            return
        end
        local existing = (cfg.per_book_decks and cfg.per_book_decks[book])
            or CardDefaults.wiki_deck({ anki = cfg })
            or CardDefaults.vocabulary_deck({ anki = cfg })
            or ""
        local sample_card = { book_title = book }
        DeckPicker.show(cfg, sample_card, function(chosen)
            cfg.per_book_decks = cfg.per_book_decks or {}
            cfg.per_book_decks[book] = chosen
            save()
            UIManager:show(Notification:new {
                text    = book .. _(" → ") .. chosen,
                timeout = 3,
            })
            parent_fn()
        end, {
            title        = _("Deck for cards from this book"),
            current_deck = existing,
            parent_fn    = parent_fn,
        })
    end

    show_book_overrides = function()
        local parent_fn = show_where_cards_go
        local menu_instance

        local function reopen()
            show_book_overrides()
        end

        local item_table = {}
        local books = {}
        if type(cfg.per_book_decks) == "table" then
            for book, deck in pairs(cfg.per_book_decks) do
                if book and book ~= "" then
                    books[#books + 1] = { book = book, deck = deck or "" }
                end
            end
        end
        table.sort(books, function(a, b) return a.book < b.book end)

        local cur_book = current_book_title()
        if cur_book ~= "" then
            item_table[#item_table + 1] = {
                text = _("Add override for «") .. cur_book .. "»…",
                callback = function()
                    UIManager:close(menu_instance)
                    map_book_to_deck(cur_book, show_book_overrides)
                end,
            }
        end

        for _i, entry in ipairs(books) do
            local book = entry.book
            local deck = entry.deck
            item_table[#item_table + 1] = {
                text = book .. " → " .. (deck ~= "" and deck or _("(not set)")),
                callback = function()
                    UIManager:close(menu_instance)
                    local action_dlg
                    action_dlg = ButtonDialog:new {
                        title   = book,
                        buttons = {
                            {{ text = _("Change deck…"),
                               callback = function()
                                   UIManager:close(action_dlg)
                                   map_book_to_deck(book, show_book_overrides)
                               end }},
                            {{ text = _("Remove override"),
                               callback = function()
                                   UIManager:close(action_dlg)
                                   UIManager:show(ConfirmBox:new {
                                       text = _("Remove deck override for this book?"),
                                       ok_callback = function()
                                           if cfg.per_book_decks then
                                               cfg.per_book_decks[book] = nil
                                           end
                                           save()
                                           reopen()
                                       end,
                                       cancel_callback = function() reopen() end,
                                   })
                               end }},
                            {{ text = _("Back"),
                               callback = function()
                                   UIManager:close(action_dlg)
                                   reopen()
                               end }},
                        },
                    }
                    UIManager:show(action_dlg)
                end,
            }
        end

        if #books == 0 and cur_book == "" then
            item_table[#item_table + 1] = {
                text = _("No book overrides saved"),
                callback = function() reopen() end,
            }
        end

        item_table[#item_table + 1] = {
            text = _("Add by book title…"),
            callback = function()
                UIManager:close(menu_instance)
                edit_field("Book title", "_map_book_title", "Book title", show_book_overrides)
            end,
        }

        item_table[#item_table + 1] = {
            text = _("← Back"),
            callback = function()
                Nav.after_close(function()
                    if menu_instance then UIManager:close(menu_instance) end
                end, parent_fn)
            end,
        }

        menu_instance = Nav.wrap_menu(Menu:new(Nav.apply_compact_menu {
            title    = _("Book overrides"),
            subtitle = _("Replaces Wiki/Vocabulary default for matching book titles"),
            item_table = item_table,
        }), function()
            Nav.after_close(function()
                if menu_instance then UIManager:close(menu_instance) end
            end, parent_fn)
        end)
        Nav.show(menu_instance)
    end

    show_favorite_decks = function()
        local menu_instance
        cfg.favorite_decks = cfg.favorite_decks or {}
        local item_table = {}

        for _i, deck in ipairs(cfg.favorite_decks) do
            local deck_name = deck
            item_table[#item_table + 1] = {
                text = "★ " .. deck_name,
                callback = function()
                    UIManager:close(menu_instance)
                    UIManager:show(ConfirmBox:new {
                        text = _("Remove from favorites?") .. "\n" .. deck_name,
                        ok_callback = function()
                            for i, v in ipairs(cfg.favorite_decks) do
                                if v == deck_name then
                                    table.remove(cfg.favorite_decks, i)
                                    break
                                end
                            end
                            save()
                            show_favorite_decks()
                        end,
                        cancel_callback = function() show_favorite_decks() end,
                    })
                end,
            }
        end

        if #cfg.favorite_decks == 0 then
            item_table[#item_table + 1] = {
                text = _("No favorite decks"),
                callback = function() show_favorite_decks() end,
            }
        end

        item_table[#item_table + 1] = {
            text = _("Add favorite deck…"),
            callback = function()
                UIManager:close(menu_instance)
                DeckPicker.show(cfg, nil, function(chosen)
                    local found = false
                    for _j, v in ipairs(cfg.favorite_decks) do
                        if v == chosen then found = true; break end
                    end
                    if not found then
                        cfg.favorite_decks[#cfg.favorite_decks + 1] = chosen
                        save()
                    end
                    show_favorite_decks()
                end, {
                    title     = _("Add favorite deck"),
                    parent_fn = show_favorite_decks,
                })
            end,
        }

        item_table[#item_table + 1] = {
            text = _("← Back"),
            callback = function()
                Nav.after_close(function()
                    if menu_instance then UIManager:close(menu_instance) end
                end, show_deck_picker_shortcuts)
            end,
        }

        menu_instance = Nav.wrap_menu(Menu:new(Nav.apply_compact_menu {
            title    = _("Favorite decks"),
            subtitle = _("At top of deck picker; does not change automatic routing"),
            item_table = item_table,
        }), function()
            Nav.after_close(function()
                if menu_instance then UIManager:close(menu_instance) end
            end, show_deck_picker_shortcuts)
        end)
        Nav.show(menu_instance)
    end

    show_deck_picker_shortcuts = function()
        local menu_instance
        local fav_count = 0
        if type(cfg.favorite_decks) == "table" then
            fav_count = #cfg.favorite_decks
        end
        local recent_str = _("(none)")
        if type(cfg.recent_decks) == "table" and #cfg.recent_decks > 0 then
            recent_str = table.concat(cfg.recent_decks, ", ")
            if #recent_str > 55 then
                recent_str = recent_str:sub(1, 52) .. "…"
            end
        end

        local item_table = {
            info_menu_item(_("About deck picker shortcuts"), _(
                "Favorite decks and recent decks appear at the top when you manually choose a deck at send time.\n\nThey do not change automatic routing, one-tap send, or Where cards go settings."
            )),
            info_menu_item(_("Recent: ") .. recent_str, _(
                "The last 5 decks you picked manually appear first in the deck picker. They are saved automatically when you send from the card viewer and cannot be edited here."
            )),
            {
                text = _("Favorite decks…") .. " (" .. tostring(fav_count) .. ")",
                callback = function()
                    close_menu_then(menu_instance, show_favorite_decks)
                end,
            },
            {
                text = _("← Back"),
                callback = function() close_menu_then(menu_instance, show_defaults) end,
            },
        }

        menu_instance = open_settings_menu(_("Deck picker shortcuts"), item_table, show_defaults)
    end

    show_where_cards_go = function()
        local menu_instance
        local subdeck_on = cfg.subdeck_by_book ~= false
        local book = current_book_title()
        local wiki_card = {
            book_title = book,
            model      = CardDefaults.wiki_model({ anki = cfg }),
        }
        local vocab_card = {
            book_title = book,
            model      = CardDefaults.vocabulary_model({ anki = cfg }),
        }
        local preview = routing_preview_lines()

        local item_table = {
            info_menu_item(preview[1], routing_help_book()),
            info_menu_item(preview[2], routing_help_for_card(wiki_card, _("Wiki Card"))),
            info_menu_item(preview[3], routing_help_for_card(vocab_card, _("Vocabulary Card"))),
            info_menu_item(_("Wiki & Vocabulary only"), _(
                "Memorization cards use Card defaults → Memorization Card. These routing rules do not apply to them."
            )),
            {
                text = toggle_label(subdeck_on, _("Append book title to deck name")),
                callback = function()
                    cfg.subdeck_by_book = not subdeck_on
                    save()
                    Nav.after_close(function()
                        if menu_instance then UIManager:close(menu_instance) end
                    end, show_where_cards_go)
                end,
            },
            {
                text = _("Book overrides…"),
                callback = function()
                    close_menu_then(menu_instance, show_book_overrides)
                end,
            },
            {
                text = _("← Back"),
                callback = function() close_menu_then(menu_instance, show_defaults) end,
            },
        }

        menu_instance = open_settings_menu(_("Where cards go"), item_table, show_defaults)
    end

    -- hook per-book deck save via transform on _map_book_title - use edit_field wrapper
    local orig_edit_field = edit_field
    edit_field = function(title, key, hint, parent_fn, transform)
        if key == "_map_book_title" then
            local edit_dlg
            edit_dlg = InputDialog:new {
                title = title, input = "", input_hint = hint,
                buttons = {{
                    { text = _("Cancel"), callback = function()
                        UIManager:close(edit_dlg); parent_fn()
                    end },
                    { text = _("Next"), callback = function()
                        local book = edit_dlg:getInputText() or ""
                        UIManager:close(edit_dlg)
                        if book == "" then parent_fn(); return end
                        map_book_to_deck(book, parent_fn)
                    end },
                }},
            }
            UIManager:show(edit_dlg)
            edit_dlg:onShowKeyboard()
            return
        end
        orig_edit_field(title, key, hint, parent_fn, transform)
    end

    -- ── Submenu: AI Providers (continued) ──────────────────────────────

    show_api_keys = function()
        local sub_dlg
        local API_KEY_FIELDS = {
            { key = "dashscope_api_key",  label = "DashScope" },
            { key = "gemini_api_key",     label = "Gemini" },
            { key = "openai_api_key",     label = "OpenAI" },
            { key = "openrouter_api_key", label = "OpenRouter" },
        }

        local buttons = {}
        for _i, akf in ipairs(API_KEY_FIELDS) do
            local aref = akf
            table.insert(buttons, {{
                text     = aref.label .. ": " .. mask_key(cfg[aref.key] or ""),
                callback = function()
                    UIManager:close(sub_dlg)
                    edit_key(aref.label .. " API Key", aref.key, show_api_keys)
                end,
            }})
        end

        table.insert(buttons, {{
            text     = _("Back"),
            callback = function() UIManager:close(sub_dlg); show_ai_providers() end,
        }})

        sub_dlg = ButtonDialog:new {
            title   = _("API Keys"),
            buttons = buttons,
        }
        UIManager:show(sub_dlg)
    end

    -- ── Submenu: Memorization ────────────────────────────────────────────

    local MEMORIZATION_DEFAULTS = {
        memorize_context_lines             = 3,
        memorize_context_cumulative        = false,
        memorize_max_words                 = 7,
        memorize_include_full_recitation   = true,
        memorize_force_verse_lines         = false,
        memorize_show_split_preview        = false,
        memorize_replace_duplicates        = false,
        memorize_merge_batch               = false,
        memorize_auto_save_on_fail         = false,
    }

    local memorization_draft = nil

    local function memorization_snapshot_from_cfg()
        return {
            memorize_context_lines = tonumber(cfg.memorize_context_lines)
                or MEMORIZATION_DEFAULTS.memorize_context_lines,
            memorize_context_cumulative = cfg.memorize_context_cumulative == true,
            memorize_max_words = tonumber(cfg.memorize_max_words)
                or MEMORIZATION_DEFAULTS.memorize_max_words,
            memorize_include_full_recitation = cfg.memorize_include_full_recitation ~= false,
            memorize_force_verse_lines = cfg.memorize_force_verse_lines == true,
            memorize_show_split_preview = cfg.memorize_show_split_preview == true,
            memorize_replace_duplicates = cfg.memorize_replace_duplicates == true,
            memorize_merge_batch = cfg.memorize_merge_batch == true,
            memorize_auto_save_on_fail = cfg.memorize_auto_save_on_fail == true,
        }
    end

    local function memorization_drafts_equal(a, b)
        if not a or not b then return false end
        return a.memorize_context_lines == b.memorize_context_lines
            and a.memorize_context_cumulative == b.memorize_context_cumulative
            and a.memorize_max_words == b.memorize_max_words
            and a.memorize_include_full_recitation == b.memorize_include_full_recitation
            and a.memorize_force_verse_lines == b.memorize_force_verse_lines
            and a.memorize_show_split_preview == b.memorize_show_split_preview
            and a.memorize_replace_duplicates == b.memorize_replace_duplicates
            and a.memorize_merge_batch == b.memorize_merge_batch
            and a.memorize_auto_save_on_fail == b.memorize_auto_save_on_fail
    end

    local function apply_memorization_draft(draft)
        cfg.memorize_context_lines = draft.memorize_context_lines
        cfg.memorize_context_cumulative = draft.memorize_context_cumulative
        cfg.memorize_max_words = draft.memorize_max_words
        cfg.memorize_include_full_recitation = draft.memorize_include_full_recitation
        cfg.memorize_force_verse_lines = draft.memorize_force_verse_lines
        cfg.memorize_show_split_preview = draft.memorize_show_split_preview
        cfg.memorize_replace_duplicates = draft.memorize_replace_duplicates
        cfg.memorize_merge_batch = draft.memorize_merge_batch
        cfg.memorize_auto_save_on_fail = draft.memorize_auto_save_on_fail
    end

    show_memorization = function()
        if not memorization_draft then
            memorization_draft = memorization_snapshot_from_cfg()
        end
        local draft = memorization_draft
        local saved_snapshot = memorization_snapshot_from_cfg()

        local ctx = draft.memorize_context_lines
        local maxw = draft.memorize_max_words
        local full_on = draft.memorize_include_full_recitation
        local cum_on = draft.memorize_context_cumulative
        local verse_on = draft.memorize_force_verse_lines
        local preview_on = draft.memorize_show_split_preview
        local replace_on = draft.memorize_replace_duplicates
        local merge_on = draft.memorize_merge_batch
        local auto_save_on = draft.memorize_auto_save_on_fail

        local sub_dlg

        local function reopen_memorization()
            Nav.after_close(function() UIManager:close(sub_dlg) end, show_memorization)
        end

        local function discard_and_close()
            memorization_draft = nil
            UIManager:close(sub_dlg)
            memorization_parent_fn()
        end

        local function close_without_saving()
            if memorization_drafts_equal(draft, saved_snapshot) then
                discard_and_close()
                return
            end
            UIManager:show(ConfirmBox:new {
                text = _("Discard memorization changes?"),
                ok_text = _("Discard"),
                ok_callback = discard_and_close,
                cancel_text = _("Keep editing"),
            })
        end

        local function save_and_close()
            apply_memorization_draft(draft)
            save()
            memorization_draft = nil
            UIManager:close(sub_dlg)
            memorization_parent_fn()
        end

        local function cycle_number(key, cur, options)
            local idx = 1
            for i, n in ipairs(options) do
                if n == cur then idx = i; break end
            end
            draft[key] = options[(idx % #options) + 1]
            reopen_memorization()
        end

        local function toggle_bool(key)
            draft[key] = not draft[key]
            reopen_memorization()
        end

        sub_dlg = ButtonDialog:new {
            title   = _("Memorization options"),
            buttons = {
                {{ text = _("Context lines: ") .. tostring(ctx),
                   callback = function()
                       cycle_number("memorize_context_lines", ctx,
                           PoetryMemorize.CONTEXT_LINE_OPTIONS)
                   end }},
                {{ text = cum_on and _("Cumulative context: ON")
                                  or _("Cumulative context: OFF"),
                   callback = function()
                       toggle_bool("memorize_context_cumulative")
                   end }},
                {{ text = _("Max words per chunk: ") .. tostring(maxw),
                   callback = function()
                       cycle_number("memorize_max_words", maxw, { 4, 5, 6, 7, 8, 9, 10, 12 })
                   end }},
                {{ text = full_on and _("Full recitation card: ON")
                                  or _("Full recitation card: OFF"),
                   callback = function()
                       toggle_bool("memorize_include_full_recitation")
                   end }},
                {{ text = verse_on and _("Force verse line split: ON")
                                   or _("Force verse line split: OFF"),
                   callback = function()
                       toggle_bool("memorize_force_verse_lines")
                   end }},
                {{ text = preview_on and _("Show step preview on send: ON")
                                    or _("Show step preview on send: OFF"),
                   callback = function()
                       toggle_bool("memorize_show_split_preview")
                   end }},
                {{ text = replace_on and _("Replace existing cards: ON")
                                    or _("Replace existing cards: OFF"),
                   callback = function()
                       toggle_bool("memorize_replace_duplicates")
                   end }},
                {{ text = merge_on and _("Merge batch highlights: ON")
                                  or _("Merge batch highlights: OFF"),
                   callback = function()
                       toggle_bool("memorize_merge_batch")
                   end }},
                {{ text = auto_save_on and _("Auto-save if send fails: ON")
                                     or _("Auto-save if send fails: OFF"),
                   callback = function()
                       toggle_bool("memorize_auto_save_on_fail")
                   end }},
                {{ text = _("Restore defaults"),
                   callback = function()
                       for k, v in pairs(MEMORIZATION_DEFAULTS) do
                           draft[k] = v
                       end
                       reopen_memorization()
                   end }},
                {{ text = _("Save"),
                   callback = save_and_close }},
                {{ text = _("Back"),
                   callback = close_without_saving }},
                {{ text = _("Close without saving"),
                   callback = close_without_saving }},
            },
        }

        function sub_dlg:onClose()
            if memorization_drafts_equal(draft, saved_snapshot) then
                discard_and_close()
                return true
            end
            UIManager:show(ConfirmBox:new {
                text = _("Discard memorization changes?"),
                ok_text = _("Discard"),
                ok_callback = discard_and_close,
                cancel_text = _("Keep editing"),
            })
            return true
        end

        UIManager:show(sub_dlg)
    end

    -- ── Submenu: Card defaults ───────────────────────────────────────────

    show_defaults_wiki = function()
        local sub_dlg
        local wiki_as = cfg.auto_send_wiki == true

        local function reopen()
            Nav.after_close(function() UIManager:close(sub_dlg) end, show_defaults_wiki)
        end

        sub_dlg = ButtonDialog:new {
            title   = _("Wiki Card defaults"),
            buttons = {
                {{ text = _("Note type: ") .. short("wiki_note_type", 22),
                   callback = function()
                       UIManager:close(sub_dlg)
                       NoteTypePicker.show(cfg, function(chosen)
                           local old_model = wiki_note_type_value()
                           sync_wiki_note_type(chosen)
                           migrate_on_wiki_model_change(old_model, chosen)
                           save()
                           show_defaults_wiki()
                       end, {
                           title         = _("Wiki Card note type"),
                           current_model = wiki_note_type_value(),
                           parent_fn     = show_defaults_wiki,
                           profile_filter = "wiki",
                           readme_id     = "wiki",
                           fallback_models = {
                               NoteTypeProfiles.DEFAULT_MODEL,
                               "Basic",
                           },
                       })
                   end }},
                {{ text = _("Default deck: ") .. short("wiki_deck", 18),
                   callback = function()
                       UIManager:close(sub_dlg)
                       DeckPicker.show(cfg, nil, function(chosen)
                           cfg.wiki_deck = chosen
                           save()
                           show_defaults_wiki()
                       end, {
                           title        = _("Wiki Card default deck"),
                           current_deck = CardDefaults.wiki_deck({ anki = cfg }),
                           parent_fn    = show_defaults_wiki,
                       })
                   end }},
                {{ text = _("Hub menu label: ") .. (function()
                       local lbl = CardDefaults.wiki_hub_label({ anki = cfg })
                       if #lbl > 22 then return lbl:sub(1, 22) .. ".." end
                       return lbl
                   end)(),
                   callback = function()
                       UIManager:close(sub_dlg)
                       edit_field("Hub menu label", "wiki_card_hub_label",
                           PluginConstants.WIKI_CARD_LABEL, show_defaults_wiki,
                           function(new_val)
                               local trimmed = (new_val or ""):match("^%s*(.-)%s*$") or ""
                               cfg.wiki_card_hub_label = trimmed ~= "" and trimmed or nil
                           end)
                   end }},
                {{ text = toggle_label(wiki_as, _("One-tap send (Wiki)")),
                   callback = function()
                       cfg.auto_send_wiki = not wiki_as
                       save()
                       reopen()
                   end }},
                {{ text = _("Back"),
                   callback = function() UIManager:close(sub_dlg); show_defaults() end }},
            },
        }
        UIManager:show(sub_dlg)
    end

    show_defaults_vocab = function()
        local sub_dlg
        local vocab_as = cfg.auto_send_vocabulary == true
        local pref_dict = (cfg.vocabulary_preferred_dictionary and cfg.vocabulary_preferred_dictionary ~= "")
            and cfg.vocabulary_preferred_dictionary or _("(auto)")

        local function reopen()
            Nav.after_close(function() UIManager:close(sub_dlg) end, show_defaults_vocab)
        end

        sub_dlg = ButtonDialog:new {
            title   = _("Vocabulary Card defaults"),
            buttons = {
                {{ text = _("Note type: ") .. short("vocabulary_model", 18),
                   callback = function()
                       UIManager:close(sub_dlg)
                       NoteTypePicker.show(cfg, function(chosen)
                           cfg.vocabulary_model = chosen
                           save()
                           show_defaults_vocab()
                       end, {
                           title         = _("Vocabulary Card note type"),
                           current_model = cfg.vocabulary_model or NoteTypeProfiles.VOCABULARY_CARD_MODEL,
                           parent_fn     = show_defaults_vocab,
                           profile_filter = "vocabulary",
                           readme_id     = "vocabulary",
                           fallback_models = {
                               NoteTypeProfiles.VOCABULARY_CARD_MODEL,
                               "Basic",
                           },
                       })
                   end }},
                {{ text = _("Default deck: ") .. short("vocabulary_deck", 18),
                   callback = function()
                       UIManager:close(sub_dlg)
                       DeckPicker.show(cfg, nil, function(chosen)
                           cfg.vocabulary_deck = chosen
                           save()
                           show_defaults_vocab()
                       end, {
                           title        = _("Vocabulary Card default deck"),
                           current_deck = CardDefaults.vocabulary_deck({ anki = cfg }),
                           parent_fn    = show_defaults_vocab,
                       })
                   end }},
                {{ text = _("Preferred dictionary: ") .. (type(pref_dict) == "string" and (
                       #pref_dict > 20 and pref_dict:sub(1, 20) .. ".." or pref_dict) or pref_dict),
                   callback = function()
                       UIManager:close(sub_dlg)
                       edit_field("Preferred dictionary", "vocabulary_preferred_dictionary",
                           _("StarDict name, or leave empty"), show_defaults_vocab)
                   end }},
                {{ text = _("Hub menu label: ") .. (function()
                       local lbl = CardDefaults.vocabulary_hub_label({ anki = cfg })
                       if #lbl > 22 then return lbl:sub(1, 22) .. ".." end
                       return lbl
                   end)(),
                   callback = function()
                       UIManager:close(sub_dlg)
                       edit_field("Hub menu label", "vocabulary_card_hub_label",
                           PluginConstants.VOCABULARY_CARD_LABEL, show_defaults_vocab,
                           function(new_val)
                               local trimmed = (new_val or ""):match("^%s*(.-)%s*$") or ""
                               cfg.vocabulary_card_hub_label = trimmed ~= "" and trimmed or nil
                           end)
                   end }},
                {{ text = toggle_label(vocab_as, _("One-tap send (Vocabulary)")),
                   callback = function()
                       cfg.auto_send_vocabulary = not vocab_as
                       save()
                       reopen()
                   end }},
                {{ text = _("Back"),
                   callback = function() UIManager:close(sub_dlg); show_defaults() end }},
            },
        }
        UIManager:show(sub_dlg)
    end

    show_defaults_mem = function()
        local sub_dlg
        local mem_as = cfg.auto_send_memorization == true
        local quick_btn = cfg.memorize_quick_highlight_button == true
        local skip_hub = cfg.auto_send_skip_hub_submenu == true
            or cfg.memorize_skip_hub_submenu == true

        local function reopen()
            Nav.after_close(function() UIManager:close(sub_dlg) end, show_defaults_mem)
        end

        sub_dlg = ButtonDialog:new {
            title   = _("Memorization Card defaults"),
            buttons = {
                {{ text = _("Note type: ") .. short("memorize_model", 18),
                   callback = function()
                       UIManager:close(sub_dlg)
                       NoteTypePicker.show(cfg, function(chosen)
                           cfg.memorize_model = chosen
                           save()
                           show_defaults_mem()
                       end, {
                           title         = _("Memorization note type"),
                           current_model = cfg.memorize_model or NoteTypeProfiles.MEMORIZATION_MODEL,
                           parent_fn     = show_defaults_mem,
                           profile_filter = "memorization",
                           readme_id     = "memorization",
                           fallback_models = {
                               NoteTypeProfiles.MEMORIZATION_MODEL,
                           },
                       })
                   end }},
                {{ text = _("Parent deck: ") .. short("memorize_parent_deck", 18),
                   callback = function()
                       UIManager:close(sub_dlg)
                       DeckPicker.show(cfg, nil, function(chosen)
                           cfg.memorize_parent_deck = chosen
                           save()
                           show_defaults_mem()
                       end, {
                           title        = _("Memorization Card parent deck"),
                           current_deck = CardDefaults.memorization_parent_deck({ anki = cfg }),
                           parent_fn    = show_defaults_mem,
                       })
                   end }},
                {{ text = toggle_label(mem_as, _("One-tap send (Memorization)")),
                   callback = function()
                       cfg.auto_send_memorization = not mem_as
                       save()
                       reopen()
                   end }},
                {{ text = toggle_label(quick_btn, _("Quick highlight button")),
                   callback = function()
                       cfg.memorize_quick_highlight_button = not quick_btn
                       save()
                       reopen()
                   end }},
                {{ text = toggle_label(skip_hub, _("Skip hub submenu when auto-send")),
                   callback = function()
                       local new_val = not skip_hub
                       cfg.auto_send_skip_hub_submenu = new_val
                       cfg.memorize_skip_hub_submenu = new_val
                       save()
                       reopen()
                   end }},
                {{ text = _("Back"),
                   callback = function() UIManager:close(sub_dlg); show_defaults() end }},
            },
        }
        UIManager:show(sub_dlg)
    end

    show_defaults = function()
        local sub_dlg
        sub_dlg = ButtonDialog:new {
            title   = _("Card defaults"),
            buttons = {
                {{ text = _("Wiki Card…"),
                   callback = function()
                       UIManager:close(sub_dlg)
                       show_defaults_wiki()
                   end }},
                {{ text = _("Vocabulary Card…"),
                   callback = function()
                       UIManager:close(sub_dlg)
                       show_defaults_vocab()
                   end }},
                {{ text = _("Memorization Card…"),
                   callback = function()
                       UIManager:close(sub_dlg)
                       show_defaults_mem()
                   end }},
                {{ text = _("Where cards go…"),
                   callback = function()
                       UIManager:close(sub_dlg)
                       show_where_cards_go()
                   end }},
                {{ text = _("Deck picker shortcuts…"),
                   callback = function()
                       UIManager:close(sub_dlg)
                       show_deck_picker_shortcuts()
                   end }},
                {{ text = _("Back"),
                   callback = function() UIManager:close(sub_dlg); show_main() end }},
            },
        }
        UIManager:show(sub_dlg)
    end

    -- ── Submenu: Anki connection & Tags ──────────────────────────────────

    show_anki_connection = function()
        local sub_dlg
        local sync_after_on = cfg.sync_after_send ~= false

        sub_dlg = ButtonDialog:new {
            title   = _("Anki connection"),
            buttons = {
                {{ text = _("AnkiConnect URL: ") .. short("url", 28),
                   callback = function()
                       UIManager:close(sub_dlg)
                       edit_field("AnkiConnect URL", "url",
                           "http://192.168.1.100:8765", show_anki_connection)
                   end }},
                {{ text = toggle_label(sync_after_on, _("Sync to AnkiWeb after send")),
                   callback = function()
                       cfg.sync_after_send = not sync_after_on
                       save()
                       UIManager:close(sub_dlg)
                       show_anki_connection()
                   end }},
                {{ text = _("Test Connection"),
                   callback = function()
                       local url = cfg.url
                       if not url or url == "" then
                           UIManager:show(Notification:new {
                               text = _("Set the AnkiConnect URL first"), timeout = 3,
                           })
                           return
                       end
                       local conn_ok, conn_err = AnkiSync.test_connection(url)
                       UIManager:show(Notification:new {
                           text = conn_ok and _("Connection OK")
                                     or (conn_err or _(
                                         "Cannot reach Anki. Check URL and that Anki is running.")),
                           timeout = conn_ok and 3 or 5,
                       })
                   end }},
                {{ text = _("Back"),
                   callback = function() UIManager:close(sub_dlg); show_main() end }},
            },
        }
        UIManager:show(sub_dlg)
    end

    show_tags = function()
        local menu_instance
        local tags_on = cfg.tags_enabled ~= false
        local tag_list_str = short("tags")

        local item_table = {
            info_menu_item(_("About tags"), tags_on
                and _(
                    "Tags on new cards is ON. The tag list below is applied to every card sent via AnkiConnect.\n\nEdit as comma-separated names. Default is KOReader if the list is empty."
                )
                or _(
                    "Tags on new cards is OFF. No tags are sent to Anki, even if a tag list is configured.\n\nTurn ON to apply the tag list on send."
                )),
            {
                text = toggle_label(tags_on, _("Tags on new cards")),
                callback = function()
                    cfg.tags_enabled = not tags_on
                    save()
                    Nav.after_close(function()
                        if menu_instance then UIManager:close(menu_instance) end
                    end, show_tags)
                end,
            },
            {
                text = _("Tag list: ") .. tag_list_str,
                callback = function()
                    close_menu_then(menu_instance, function()
                        edit_field("Tags (comma-sep)", "tags", "KOReader",
                            show_tags, function(new_val)
                                local tag_list = {}
                                for t in new_val:gmatch("[^,]+") do
                                    local trimmed = t:match("^%s*(.-)%s*$")
                                    if trimmed ~= "" then
                                        tag_list[#tag_list + 1] = trimmed
                                    end
                                end
                                cfg.tags = #tag_list > 0 and tag_list or { "KOReader" }
                            end)
                    end)
                end,
            },
            {
                text = _("← Back"),
                callback = function() close_menu_then(menu_instance, show_main) end,
            },
        }

        menu_instance = open_settings_menu(_("Tags"), item_table, show_main)
    end

    -- ── Submenu: Sync ────────────────────────────────────────────────────
    show_sync = function()
        local sub_dlg
        local auto_label = cfg.auto_send_wifi
            and CHECK_ON .. _("Send pending when WiFi (every 20 min): ON")
            or  _("Send pending when WiFi (every 20 min): OFF")

        local sync_name
        if cfg.sync_server then
            sync_name = cfg.sync_server.name or cfg.sync_server.address or "Cloud"
        end

        sub_dlg = ButtonDialog:new {
            title   = _("Sync"),
            buttons = {
                {{ text = auto_label,
                   callback = function()
                       cfg.auto_send_wifi = not cfg.auto_send_wifi
                       save()
                       UIManager:close(sub_dlg)
                       show_sync()
                   end }},
                {{ text = sync_name and (_("Cloud Sync: ") .. sync_name)
                                     or _("Cloud Sync: (not configured)"),
                   callback = function()
                       Nav.after_close(function() UIManager:close(sub_dlg) end, function()
                           CardSync.show_cloud_sync_dialog(cfg, function(new_cfg)
                               cfg = new_cfg
                               save()
                           end, { parent_fn = show_sync })
                       end)
                   end }},
                {{ text = _("Back"),
                   callback = function() UIManager:close(sub_dlg); show_main() end }},
            },
        }
        UIManager:show(sub_dlg)
    end

    -- ── Main settings screen ─────────────────────────────────────────────

    show_main = function()
        local cur_provider = cfg.text_provider or "dashscope"
        local menu_instance

        local function close_settings()
            Nav.after_close(function()
                if menu_instance then UIManager:close(menu_instance) end
            end, function()
                if settings_parent_fn then settings_parent_fn() end
            end)
        end

        local item_table = {
            info_menu_item(_("About Settings"), _(
                "Card defaults: note types, decks, one-tap send, and deck routing.\nAnki connection: AnkiConnect URL and sync after send.\nTags: tags applied when cards are sent.\nMemorization options: how text is split (not deck routing).\nAI Settings: Wiki Card (AI) generation.\nSync: background send when WiFi is on and cloud backup.\n\nGray rows in any submenu — tap for help."
            )),
            {
                text = _("View settings guide"),
                dim  = true,
                callback = function()
                    close_menu_then(menu_instance, function()
                        local ok, ReadmeViewer = pcall(require, "readme_viewer")
                        if ok and ReadmeViewer.show_or_notify then
                            ReadmeViewer.show_or_notify("settings", {
                                on_close = show_main,
                            })
                        else
                            show_main()
                        end
                    end)
                end,
            },
            {
                text = _("Card defaults…"),
                callback = function()
                    close_menu_then(menu_instance, show_defaults)
                end,
            },
            {
                text = _("Anki connection…"),
                callback = function()
                    close_menu_then(menu_instance, show_anki_connection)
                end,
            },
            {
                text = _("Tags…"),
                callback = function()
                    close_menu_then(menu_instance, show_tags)
                end,
            },
            {
                text = _("Memorization options…"),
                callback = function()
                    memorization_parent_fn = show_main
                    close_menu_then(menu_instance, show_memorization)
                end,
            },
            {
                text = _("AI Settings") .. "  (" .. cur_provider .. ")",
                callback = function()
                    close_menu_then(menu_instance, show_ai_providers)
                end,
            },
            {
                text = _("Sync…"),
                callback = function()
                    close_menu_then(menu_instance, show_sync)
                end,
            },
            {
                text = settings_parent_fn and _("← Back") or _("Close"),
                callback = close_settings,
            },
        }

        local on_close = settings_parent_fn and settings_parent_fn or function() end
        menu_instance = open_settings_menu(_("Settings"), item_table, on_close)
    end

    show_main()
end

return SettingsViewer
