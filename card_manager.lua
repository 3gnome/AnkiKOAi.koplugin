-- Card Manager: card list (with filter) + separate management submenu.

local ButtonDialog   = require("ui/widget/buttondialog")
local ConfirmBox     = require("ui/widget/confirmbox")
local Menu           = require("ui/widget/menu")
local Notification   = require("ui/widget/notification")
local UIManager      = require("ui/uimanager")
local _              = require("gettext")

local Event          = require("ui/event")
local CardStorage    = require("card_storage")
local AnkiSync       = require("anki_sync")
local CardGenerator  = require("card_generator")
local CardFields     = require("card_fields")
local CardViewer     = require("card_viewer")
local NetworkMgr     = require("ui/network/manager")
local SendFlow       = require("send_flow")
local PluginConstants = require("plugin_constants")
local Nav             = require("nav")
local SelectableMenu  = require("selectable_menu")
local HighlightInbox  = require("highlight_inbox")

local InfoMessage   = require("ui/widget/infomessage")

local function show_readme_safe(readme_id)
    local ok, rv = pcall(require, "readme_viewer")
    if ok and rv and rv.show_or_notify then
        rv.show_or_notify(readme_id)
    end
end

local CardManager = {}

local send_all_in_progress = false

local function notify(text)
    UIManager:show(Notification:new { text = text })
end

local function notify_error(text)
    UIManager:show(InfoMessage:new { text = text, timeout = 5 })
end

-- Handles both full CONFIGURATION (with nested .anki) and a flat Anki-only table.
local function effective_config(base)
    local cfg = {}
    local anki_base = (base and type(base.anki) == "table") and base.anki or base
    if anki_base then
        for k, v in pairs(anki_base) do cfg[k] = v end
    end
    local saved = CardStorage.load_anki_settings()
    if saved then
        for k, v in pairs(saved) do cfg[k] = v end
    end
    return cfg
end

local function is_anki_ready(anki_config)
    return anki_config.url
        and anki_config.url ~= ""
        and not anki_config.url:find("192.168.x.x", 1, true)
end

function CardManager.count_unsent()
    return CardStorage.count_unsent()
end

local function send_memorization_card(anki_config, base_config, card, send_ui, done, quiet)
    if not is_anki_ready(anki_config) then
        if not quiet then
            notify_error(_("Anki URL not set. Use AnkiKOAi → Settings."))
        end
        if done then done(false, "Anki URL not set") end
        return
    end
    local PoetryMemorize = require("poetry_memorize")
    local meta = {
        book_title  = card.book_title,
        book_author = card.book_author,
        source      = card.source,
        title       = card.phrase or "",
        deck        = (card.memorization_deck and card.memorization_deck ~= "")
                      and card.memorization_deck or nil,
    }
    PoetryMemorize.send_highlight(base_config, card.memorization_text, send_ui, meta,
        function(ok, err_or_msg, info)
            if ok then
                local deck = (info and info.deck) or meta.deck or anki_config.deck or ""
                CardStorage.mark_sent_memorization(card.memorization_text, deck)
                if not quiet then notify(err_or_msg or _("Sent!")) end
            else
                if not quiet then notify_error(err_or_msg or _("Send failed")) end
            end
            if done then done(ok, err_or_msg) end
        end)
end

function CardManager.send_all_unsent(base_config, ui, opts)
    opts = opts or {}
    if send_all_in_progress then
        if opts.on_done then opts.on_done(0, 0) end
        return
    end
    local anki_config = effective_config(base_config)
    if not is_anki_ready(anki_config) then
        if not opts.background then
            notify_error(_("Anki URL not set. Use AnkiKOAi → Settings."))
        end
        if opts.on_done then opts.on_done(0, 0) end
        return
    end

    local fresh = CardStorage.load_cards()
    local pending_mem, pending_sync = {}, {}
    for _i, card in ipairs(fresh) do
        if not card.sent_to_anki then
            if CardStorage.is_memorization(card) then
                table.insert(pending_mem, card)
            else
                table.insert(pending_sync, card)
            end
        end
    end

    if #pending_mem == 0 and #pending_sync == 0 then
        if not opts.background then notify(_("No pending cards to send.")) end
        if opts.on_done then opts.on_done(0, 0) end
        return
    end

    send_all_in_progress = true
    local sent, failed = 0, 0
    local last_deck, last_model

    for _i, card in ipairs(pending_sync) do
        local deck = (card.target_deck and card.target_deck ~= "")
            and card.target_deck
            or AnkiSync.resolve_base_deck(anki_config, card)
            or anki_config.last_send_deck
            or anki_config.deck
        if not deck or deck == "" then
            failed = failed + 1
        else
            local model = SendFlow.effective_model(anki_config, card)
            local ok = AnkiSync.send_card(anki_config, card, {
                deck      = deck,
                model     = model,
                skip_sync = true,
            })
            if ok then
                CardStorage.mark_sent(card.phrase, deck, model)
                last_deck = deck
                last_model = model
                sent = sent + 1
                if ui and card.highlight_pos0 then
                    local HighlightStatus = require("highlight_status")
                    HighlightStatus.mark_sent(ui, card.highlight_pos0, card.highlight_pos1)
                end
            else
                failed = failed + 1
            end
        end
    end

    local function finish_batch()
        send_all_in_progress = false
        if last_deck then
            SendFlow.remember_send(anki_config, last_deck, last_model or anki_config.model)
        end
        local msg
        if sent == 0 and failed == 0 then
            msg = _("No pending cards to send.")
        else
            msg = tostring(sent) .. _(" sent")
            if failed > 0 then msg = msg .. ", " .. tostring(failed) .. _(" failed") end
            if sent > 0 then
                msg = msg .. AnkiSync.sync_status_suffix(anki_config)
            end
        end
        -- In background (auto-send) mode, stay silent unless something was
        -- actually sent, so a repeatedly-unreachable Anki can't spam toasts.
        if not opts.background or sent > 0 then
            notify(msg)
        end
        if opts.on_done then opts.on_done(sent, failed) end
    end

    local function send_memorization_at(index)
        if index > #pending_mem then
            finish_batch()
            return
        end
        send_memorization_card(anki_config, base_config, pending_mem[index], ui,
            function(ok)
                if ok then sent = sent + 1 else failed = failed + 1 end
                send_memorization_at(index + 1)
            end, opts.background)
    end

    if #pending_mem > 0 then
        send_memorization_at(1)
    else
        finish_batch()
    end
end

local function send_one(anki_config, base_config, card, done, send_ui)
    if CardStorage.is_memorization(card) then
        send_memorization_card(anki_config, base_config, card, send_ui, done)
        return
    end
    if not is_anki_ready(anki_config) then
        notify_error(_("Anki URL not set. Use AnkiKOAi → Settings."))
        if done then done(false, "Anki URL not set") end
        return
    end
    SendFlow.prompt_and_send(anki_config, card, function(ok, err)
        if ok then
            notify(_("Sent!"))
        elseif not SendFlow.is_cancelled(err) then
            notify_error(_("Anki error: ") .. (err or "unknown"))
        end
        if done then done(ok, err) end
    end, { ui = send_ui })
end

local function show_stats(on_back)
    local all_cards  = CardStorage.load_cards()
    local book_order = {}
    local book_stats = {}
    for _i, card in ipairs(all_cards) do
        local title = (card.book_title and card.book_title ~= "")
                      and card.book_title or _("Unknown book")
        if not book_stats[title] then
            book_stats[title] = { total = 0, sent = 0 }
            table.insert(book_order, title)
        end
        book_stats[title].total = book_stats[title].total + 1
        if card.sent_to_anki then book_stats[title].sent = book_stats[title].sent + 1 end
    end

    local total_all, sent_all = #all_cards, 0
    for _i, card in ipairs(all_cards) do
        if card.sent_to_anki then sent_all = sent_all + 1 end
    end

    local stat_items = {}
    if #book_order == 0 then
        table.insert(stat_items, { text = _("(no cards yet)") })
    end
    for _i, title in ipairs(book_order) do
        local s      = book_stats[title]
        local unsent = s.total - s.sent
        local line   = title .. "  —  " .. tostring(s.total)
                       .. (s.total == 1 and _(" card") or _(" cards"))
                       .. "  +" .. tostring(s.sent) .. " sent"
        if unsent > 0 then
            line = line .. "  -" .. tostring(unsent) .. " unsent"
        end
        table.insert(stat_items, { text = line })
    end

    local title_str = _("Stats — ")
                      .. tostring(total_all)
                      .. (total_all == 1 and _(" card") or _(" cards"))
                      .. "  +" .. tostring(sent_all) .. " sent"
                      .. "  -" .. tostring(total_all - sent_all) .. " unsent"

    Nav.show_menu {
        title      = title_str,
        items      = stat_items,
        back_label = _("← Back"),
        on_back    = on_back,
    }
end

local function group_cards_by_book(all_cards)
    local groups = {}
    local index = {}
    for storage_idx, card in ipairs(all_cards) do
        local title = (card.book_title and card.book_title ~= "")
            and card.book_title or _("Unknown book")
        if not index[title] then
            index[title] = { title = title, cards = {} }
            table.insert(groups, index[title])
        end
        table.insert(index[title].cards, {
            card        = card,
            storage_idx = storage_idx,
        })
    end
    return groups
end

local function book_menu_label(group)
    local count = #group.cards
    local short = SelectableMenu.truncate(group.title, 36)
    return short .. "  (" .. tostring(count)
        .. (count == 1 and _(" card") or _(" cards")) .. ")"
end

local function find_book_group(book_title)
    for _i, group in ipairs(group_cards_by_book(CardStorage.load_cards())) do
        if group.title == book_title then return group end
    end
end

-- ── Management submenu ────────────────────────────────────────────────────────

function CardManager.show_manage(base_config, opts)
    opts = opts or {}
    local anki_config = effective_config(base_config)
    local manage_menu_ref = {}
    local back_label = opts.back_label or _("← Back to highlight menu")
    local guard = { busy = false }

    local function reopen_manage()
        CardManager.show_manage(base_config, opts)
    end

    local function go_back()
        if guard.busy or not opts.on_back then return end
        guard.busy = true
        Nav.after_close(function()
            if manage_menu_ref[1] then UIManager:close(manage_menu_ref[1]) end
        end, function()
            guard.busy = false
            opts.on_back()
        end)
    end

    local function open_child(open_fn)
        guard.busy = true
        Nav.after_close(function()
            if manage_menu_ref[1] then UIManager:close(manage_menu_ref[1]) end
        end, function()
            guard.busy = false
            if open_fn then open_fn() end
        end)
    end

    local function update_manage_clear_all_count()
        local menu = manage_menu_ref[1]
        if not menu or not menu.item_table then
            reopen_manage()
            return
        end
        while menu.item_table_stack and #menu.item_table_stack > 0 do
            Menu.onClose(menu)
        end
        local count = #CardStorage.load_cards()
        local label = _("Clear All Cards") .. " (" .. tostring(count) .. ")"
        for _i, item in ipairs(menu.item_table) do
            if item.manage_clear_all then
                item.text = label
                pcall(function()
                    menu:updateItems(menu.page or 1, false)
                end)
                return
            end
        end
        reopen_manage()
    end

    local function build_manage_items()
        local saved_count = #CardStorage.load_cards()
        local unsent_count = CardStorage.count_unsent()
        local send_label = _("Send All Unsent to Anki")
        if unsent_count > 0 then
            send_label = send_label .. " (" .. tostring(unsent_count) .. ")"
        end
        return {
            {
                text = send_label,
                bold = true,
                callback = function()
                    CardManager.send_all_unsent(base_config, opts.ui, {
                        on_done = function()
                            reopen_manage()
                        end,
                    })
                end,
            },
            {
                text = _("Stats by Book"),
                bold = true,
                callback = function()
                    open_child(function() show_stats(reopen_manage) end)
                end,
            },
            {
                text     = _("Highlights to Anki"),
                bold     = true,
                callback = function()
                    if not opts.ui then
                        notify_error(_("Open a book to use highlights"))
                        return
                    end
                    if not HighlightInbox.has_highlights(opts.ui) then
                        HighlightInbox.notify_empty()
                        return
                    end
                    open_child(function()
                        HighlightInbox.show(opts.ui, base_config, {
                            on_back    = reopen_manage,
                            back_label = _("← Back to Highlights and Cards"),
                        })
                    end)
                end,
            },
            {
                text           = _("Anki setup guides"),
                sub_item_table = {
                    {
                        text     = _("Wiki Card setup"),
                        callback = function() show_readme_safe("wiki") end,
                    },
                    {
                        text     = _("Vocabulary Card setup"),
                        callback = function() show_readme_safe("vocabulary") end,
                    },
                    {
                        text     = _("Memorization setup"),
                        callback = function() show_readme_safe("memorization") end,
                    },
                    {
                        text     = _("Getting started"),
                        callback = function() show_readme_safe("getting_started") end,
                    },
                    {
                        text     = _("Plugin configuration"),
                        callback = function() show_readme_safe("plugin_config") end,
                    },
                },
            },
            {
                text             = _("Clear All Cards") .. " (" .. tostring(saved_count) .. ")",
                manage_clear_all = true,
                bold             = true,
                callback = function()
                    UIManager:show(ConfirmBox:new {
                        text        = _("Delete all saved cards? This cannot be undone."),
                        ok_text     = _("Clear All"),
                        ok_callback = function()
                            UIManager:scheduleIn(0.05, function()
                                pcall(function()
                                    CardStorage.clear_all()
                                    notify(_("All cards cleared"))
                                    update_manage_clear_all_count()
                                end)
                            end)
                        end,
                    })
                end,
            },
        }
    end

    local item_table = build_manage_items()

    Nav.prepend_back(item_table, nil, manage_menu_ref, back_label)

    manage_menu_ref[1] = Nav.wrap_menu(Menu:new(Nav.apply_compact_menu {
        title      = _("Highlights and Cards"),
        item_table = item_table,
    }), function()
        if guard.busy then return end
        go_back()
    end)
    Nav.show(manage_menu_ref[1])
end

-- ── Card list grouped by book ─────────────────────────────────────────────────

function CardManager.show(base_config, _filter_book, ui, opts)
    opts = opts or {}
    local anki_config = effective_config(base_config)
    local menu_ref = {}
    local back_label = opts.back_label or _("← Back to highlight menu")
    local guard = { busy = false }
    local book_selected = {}

    local function go_back()
        if guard.busy or not opts.on_back then return end
        guard.busy = true
        Nav.after_close(function()
            if menu_ref[1] then UIManager:close(menu_ref[1]) end
        end, function()
            guard.busy = false
            opts.on_back()
        end)
    end

    local function update_root_title()
        local menu = menu_ref[1]
        if not menu then return end
        local total = #CardStorage.load_cards()
        local title = _("My Cards (") .. tostring(total)
            .. (total == 1 and _(" card") or _(" cards")) .. ")"
        menu.title = title
        if menu.title_bar then
            menu.title_bar:setTitle(title, true)
        end
    end

    local function sync_root_book_row(book_title, group)
        local menu = menu_ref[1]
        if not menu or not menu.item_table_stack or #menu.item_table_stack == 0 then
            return
        end
        local parent = menu.item_table_stack[#menu.item_table_stack]
        for idx, item in ipairs(parent) do
            if item.book_key == book_title then
                if not group or #group.cards == 0 then
                    table.remove(parent, idx)
                    update_root_title()
                else
                    item.text = book_menu_label(group)
                end
                return
            end
        end
    end

    local build_book_submenu

    local function refresh_my_cards_root()
        UIManager:scheduleIn(0.05, function()
            local menu = menu_ref[1]
            if not menu then
                CardManager.show(base_config, nil, ui, opts)
                return
            end
            if menu.item_table_stack and #menu.item_table_stack > 0 then
                menu:onClose()
            end
            local all_cards = CardStorage.load_cards()
            local groups = group_cards_by_book(all_cards)
            local item_table = {}
            if #groups == 0 then
                table.insert(item_table, {
                    text           = _("(no saved cards yet)"),
                    select_enabled = false,
                })
            end
            for _i, group in ipairs(groups) do
                table.insert(item_table, {
                    text           = book_menu_label(group),
                    book_key       = group.title,
                    sub_item_table = build_book_submenu(group),
                })
            end
            Nav.prepend_back(item_table, nil, menu_ref, back_label)
            local total = #all_cards
            local title = _("My Cards (") .. tostring(total)
                .. (total == 1 and _(" card") or _(" cards")) .. ")"
            Nav.replace_menu_items(menu, item_table, title)
        end)
    end

    local function refresh_book_submenu(book_title)
        UIManager:scheduleIn(0.05, function()
            local menu = menu_ref[1]
            if not menu then
                local reopen_opts = {}
                for k, v in pairs(opts) do reopen_opts[k] = v end
                reopen_opts.initial_book = book_title
                CardManager.show(base_config, nil, ui, reopen_opts)
                return
            end
            local group = find_book_group(book_title)
            if not group then
                sync_root_book_row(book_title, nil)
                refresh_my_cards_root()
                return
            end
            local title = book_menu_label(group)
            local rebuilt = build_book_submenu(group)
            pcall(Nav.replace_menu_items, menu, rebuilt, title)
        end)
    end

    local function open_card_viewer(card, storage_idx, return_book)
        if CardStorage.is_memorization(card) then
            local dialog
            dialog = ButtonDialog:new {
                title   = card.phrase or _("Memorization"),
                buttons = {
                    {{ text = _("Send to Anki"), callback = function()
                        UIManager:close(dialog)
                        send_memorization_card(anki_config, base_config, card, ui,
                            function(ok)
                                if ok and return_book then
                                    refresh_book_submenu(return_book)
                                end
                            end)
                    end }},
                    {{ text = _("Delete"), callback = function()
                        UIManager:close(dialog)
                        CardStorage.delete_card(storage_idx)
                        notify(_("Deleted"))
                        if return_book then refresh_book_submenu(return_book) end
                    end }},
                    {{ text = _("Close"), callback = function()
                        UIManager:close(dialog)
                    end }},
                },
            }
            UIManager:show(dialog)
            return
        end

        guard.busy = true
        if menu_ref[1] then UIManager:close(menu_ref[1]) end
        menu_ref[1] = nil
        guard.busy = false

        local viewer_ref = {}
        local card_ref = { phrase = card.phrase }

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
                on_navigate_to_source = (ui and card.highlight_pos0) and function()
                    local cur = viewer_ref[1]
                    if cur then UIManager:close(cur) end
                    local event_name = ui.paging and "GotoPage" or "GotoXPointer"
                    ui:handleEvent(Event:new(event_name, card.highlight_pos0))
                end or nil,
                on_update = function(updated_card)
                    CardStorage.update_card(card_ref.phrase, updated_card)
                    card_ref.phrase = updated_card.phrase
                end,
                on_regen_text = function()
                    if viewer_ref[1] then UIManager:close(viewer_ref[1]) end
                    local loading_t = Notification:new {
                        text    = _("Refining article…"),
                        timeout = 30,
                    }
                    UIManager:show(loading_t)
                    NetworkMgr:runWhenOnline(function()
                        UIManager:scheduleIn(0.05, function()
                            UIManager:close(loading_t)
                            local new_text, err = CardGenerator.generate_text(
                                base_config, card.phrase, card)
                            if not new_text then
                                notify_error(_("Regen failed: ") .. (err or "unknown"))
                                viewer_ref[1] = make_viewer(true)
                                return
                            end
                            card.text = new_text
                            CardFields.sync_flat_from_anki(card)
                            CardStorage.update_card(card_ref.phrase, card)
                            viewer_ref[1] = make_viewer(true)
                        end)
                    end)
                end,
                on_regen_ipa = function(new_phrase, updated_card, new_viewer)
                    NetworkMgr:runWhenOnline(function()
                        UIManager:scheduleIn(0.05, function()
                            local ipa, err = CardGenerator.generate_ipa(base_config, new_phrase)
                            if ipa then
                                updated_card.ipa = ipa
                                CardStorage.update_card(updated_card.phrase, updated_card)
                                local still_shown = false
                                for w in UIManager:topdown_widgets_iter() do
                                    if w == new_viewer then still_shown = true; break end
                                end
                                if still_shown then new_viewer:update() end
                                notify(_("IPA updated"))
                            else
                                notify_error(_("IPA regen failed: ") .. (err or "unknown"))
                            end
                        end)
                    end)
                end,
            }
            local send_cb = SendFlow.viewer_callbacks(anki_config, card, ui)
            v.can_quick_send = send_cb.can_quick_send
            v.on_send        = send_cb.on_send
            v.on_quick_send  = send_cb.on_quick_send

            function v:onClose()
                UIManager:close(self)
                UIManager:scheduleIn(0.05, function()
                    if return_book then
                        refresh_book_submenu(return_book)
                    else
                        refresh_my_cards_root()
                    end
                end)
                return true
            end

            UIManager:show(v)
            return v
        end

        viewer_ref[1] = make_viewer(false)
    end

    build_book_submenu = function(group)
        local book_title = group.title
        local selected = book_selected[book_title] or {}
        book_selected[book_title] = selected

        local entries = {}
        for _i, item in ipairs(group.cards) do
            local card = item.card
            local prefix = card.sent_to_anki and "+ " or ""
            local phrase = card.phrase or ""
            if CardStorage.is_memorization(card) then
                phrase = phrase .. "  [" .. _("memorization") .. "]"
            end
            if #phrase > 50 then phrase = phrase:sub(1, 50) .. "…" end
            table.insert(entries, {
                key   = book_title .. "\0" .. tostring(item.storage_idx),
                label = prefix .. phrase .. "  (" .. (card.date or "") .. ")",
                data  = item,
            })
        end

        local items = {}
        local list_state = { entries = entries, selected = selected, opts = nil }
        local list_opts = {
            entries    = entries,
            selected   = selected,
            default_selected = false,
            empty_text = _("(no cards for this book)"),
            rebuild    = function()
                UIManager:scheduleIn(0.05, function()
                    local menu = menu_ref[1]
                    if menu and list_state then
                        SelectableMenu.sync_in_place(menu, list_state)
                    end
                end)
            end,
            on_open    = function(entry)
                open_card_viewer(entry.data.card, entry.data.storage_idx, book_title)
            end,
            on_hold    = function(entry)
                local card = entry.data.card
                local storage_idx = entry.data.storage_idx
                local dialog
                dialog = ButtonDialog:new {
                    title   = card.phrase or "",
                    buttons = {
                        {{ text = _("Open Card"), callback = function()
                            UIManager:close(dialog)
                            open_card_viewer(card, storage_idx, book_title)
                        end }},
                        {{ text = _("Send to Anki"), callback = function()
                            UIManager:close(dialog)
                            send_one(anki_config, base_config, card, function(ok)
                                if ok then refresh_book_submenu(book_title) end
                            end, ui)
                        end }},
                        {{ text = _("Cancel"), callback = function()
                            UIManager:close(dialog)
                        end }},
                    },
                }
                UIManager:show(dialog)
            end,
            on_delete_selected = function(picked)
                local indices = {}
                for _i, entry in ipairs(picked) do
                    table.insert(indices, entry.data.storage_idx)
                end
                CardStorage.delete_indices(indices)
                notify(tostring(#indices) .. _(" card(s) deleted"))
            end,
            after_delete = function() refresh_book_submenu(book_title) end,
            on_delete_all = function()
                CardStorage.delete_where(function(card)
                    local t = (card.book_title and card.book_title ~= "")
                        and card.book_title or _("Unknown book")
                    return t == book_title
                end)
                notify(_("All cards for this book deleted"))
            end,
            after_delete_all = function()
                sync_root_book_row(book_title, nil)
                refresh_my_cards_root()
            end,
            delete_selected_label = _("Delete Selected Cards"),
            delete_selected_confirm = _("Delete selected saved card(s)?"),
            delete_all_label = _("Delete All Cards in Book"),
            delete_all_count = #entries,
            delete_all_confirm = _("Delete every saved card from this book?"),
        }
        list_state.opts = list_opts
        SelectableMenu.append_list(items, list_opts)
        return items
    end

    local all_cards = CardStorage.load_cards()
    local groups = group_cards_by_book(all_cards)
    local unsent_count = CardStorage.count_unsent()
    local item_table = {}

    if unsent_count > 0 then
        table.insert(item_table, {
            text     = _("Send pending to Anki") .. " (" .. tostring(unsent_count) .. ")",
            bold     = true,
            callback = function()
                CardManager.send_all_unsent(base_config, ui, {
                    on_done = function()
                        refresh_my_cards_root()
                    end,
                })
            end,
        })
    end

    if #groups == 0 then
        table.insert(item_table, {
            text           = _("(no saved cards yet)"),
            select_enabled = false,
        })
    end

    for _i, group in ipairs(groups) do
        table.insert(item_table, {
            text           = book_menu_label(group),
            book_key       = group.title,
            sub_item_table = build_book_submenu(group),
        })
    end

    local total = #all_cards
    local title = _("My Cards (") .. tostring(total)
        .. (total == 1 and _(" card") or _(" cards")) .. ")"
    if unsent_count > 0 then
        title = title .. ", " .. tostring(unsent_count) .. _(" unsent")
    end
    Nav.prepend_back(item_table, nil, menu_ref, back_label)

    menu_ref[1] = Nav.wrap_menu(Menu:new(Nav.apply_compact_menu {
        title      = title,
        item_table = item_table,
        onMenuHold = function(self, item)
            if item and item.hold_callback then item.hold_callback() end
        end,
    }), function()
        if guard.busy then return end
        go_back()
    end)
    Nav.show(menu_ref[1])

    if opts.initial_book then
        for _i, item in ipairs(item_table) do
            if item.book_key == opts.initial_book and item.sub_item_table then
                menu_ref[1]:onMenuSelect(item)
                break
            end
        end
    end
end

return CardManager
