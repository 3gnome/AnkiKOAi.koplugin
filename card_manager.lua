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
local CardDefaults   = require("card_defaults")
local CardGenerator  = require("card_generator")
local CardFields     = require("card_fields")
local CardViewer     = require("card_viewer")
local NetworkMgr     = require("ui/network/manager")
local SendFlow       = require("send_flow")
local PluginConstants = require("plugin_constants")
local Nav             = require("nav")
local SelectableMenu  = require("selectable_menu")
local HighlightInbox  = require("highlight_inbox")
local UiBusy            = require("ui_busy")
local CardReconcile     = require("card_reconcile")
local HighlightStatus   = require("highlight_status")

local InfoMessage   = require("ui/widget/infomessage")

local function show_readme_safe(readme_id)
    local ok, rv = pcall(require, "readme_viewer")
    if ok and rv and rv.show_or_notify then
        rv.show_or_notify(readme_id)
    end
end

local CardManager = {}

local send_all_in_progress = false
local BATCH_SEND_DELAY = 0.15
local batch_progress_notif = nil

function CardManager.is_send_all_in_progress()
    return send_all_in_progress
end

local function clear_batch_progress()
    if batch_progress_notif then
        UIManager:close(batch_progress_notif)
        batch_progress_notif = nil
    end
end

-- progress_ctx: { total, offset, label } — offset adds wiki/vocab count before mem phase.
local function show_batch_progress(progress_ctx, current)
    if not progress_ctx or progress_ctx.total <= 0 then return end
    if batch_progress_notif then UIManager:close(batch_progress_notif) end
    local label = progress_ctx.label or _("Sending to Anki…")
    batch_progress_notif = Notification:new {
        text    = label .. " " .. tostring(current) .. "/" .. tostring(progress_ctx.total),
        timeout = 300,
    }
    UIManager:show(batch_progress_notif)
end

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

local function send_memorization_card(anki_config, base_config, card, send_ui, done, quiet, storage_idx)
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
                local deck = (info and info.deck) or meta.deck
                    or CardDefaults.memorization_parent_deck({ anki = anki_config })
                    or ""
                CardReconcile.finish({ card = card }, anki_config, send_ui, {
                    status = "sent",
                    deck   = deck,
                })
                if not quiet then notify(err_or_msg or _("Sent!")) end
            else
                if not quiet then notify_error(err_or_msg or _("Send failed")) end
            end
            if done then done(ok, err_or_msg) end
        end)
end

local function resolve_batch_deck(anki_config, card)
    return (card.target_deck and card.target_deck ~= "")
        and card.target_deck
        or AnkiSync.resolve_base_deck(anki_config, card)
        or anki_config.last_send_deck
        or CardDefaults.deck_for_card({ anki = anki_config }, card)
end

local function resolve_send_target(anki_config, card)
    CardFields.normalize(card, anki_config)
    local base_deck = resolve_batch_deck(anki_config, card)
    if not base_deck or base_deck == "" then
        return nil, nil, nil
    end
    local deck_name = AnkiSync.resolve_deck_name(anki_config, card, base_deck)
    local model = SendFlow.effective_model(anki_config, card)
    local phrase = card.phrase or ""
    return deck_name, model, phrase
end

local function filter_unsent_wiki_vocab_picked(picked)
    local batch, skipped_mem = {}, 0
    for _i, entry in ipairs(picked or {}) do
        local card = entry.data.card
        if CardStorage.is_memorization(card) then
            skipped_mem = skipped_mem + 1
        else
            table.insert(batch, {
                card = card,
                storage_idx = entry.data.storage_idx,
            })
        end
    end
    return batch, skipped_mem
end

local function notify_check_skips(skipped_mem)
    if skipped_mem > 0 then
        notify(_("Memorization cards: long-press a row → Send to Anki."))
    end
end

local function format_check_message(found, not_found)
    local parts = {}
    if found > 0 then
        table.insert(parts, tostring(found) .. _(" found in Anki"))
    end
    if not_found > 0 then
        table.insert(parts, tostring(not_found) .. _(" not found"))
    end
    if #parts == 0 then return _("No pending cards to check.") end
    local msg = table.concat(parts, ", ")
    if found > 0 then
        msg = msg .. " — " .. _("see Recently sent")
    end
    return msg
end

local function run_check_items(anki_config, items, opts, on_complete)
    local found, not_found = 0, 0
    local pos = 1
    local socket = require("socket")

    local function check_next()
        if pos > #items then
            if not opts.background then
                notify(format_check_message(found, not_found))
            end
            if on_complete then on_complete(found, not_found) end
            if opts.on_done then opts.on_done(found, not_found) end
            return
        end
        local item = items[pos]
        pos = pos + 1
        local card = item.card
        local deck_name, model, phrase = resolve_send_target(anki_config, card)
        if not deck_name or deck_name == "" or phrase == "" then
            not_found = not_found + 1
        else
            local exists = AnkiSync.note_exists_in_deck(
                anki_config.url, deck_name, model, phrase, "Phrase")
            if exists then
                CardReconcile.finish(item, anki_config, opts.ui, {
                    status = "checked",
                    deck   = deck_name,
                    model  = model,
                })
                found = found + 1
            else
                not_found = not_found + 1
            end
        end
        if pos <= #items then
            socket.sleep(BATCH_SEND_DELAY)
        end
        check_next()
    end

    if #items == 0 then
        if not opts.background then notify(_("No pending cards to check.")) end
        if on_complete then on_complete(0, 0) end
        if opts.on_done then opts.on_done(0, 0) end
    else
        check_next()
    end
end

-- Read-only Anki lookup for unsent wiki/vocab rows (no addNote).
function CardManager.check_items_against_anki(base_config, items, opts)
    opts = opts or {}
    local anki_config = effective_config(base_config)
    if not is_anki_ready(anki_config) then
        notify_error(_("Anki URL not set. Use AnkiKOAi → Settings."))
        if opts.on_done then opts.on_done(0, 0) end
        return
    end
    if not items or #items == 0 then
        notify(_("No pending cards to check."))
        if opts.on_done then opts.on_done(0, 0) end
        return
    end

    local function start_check()
        run_check_items(anki_config, items, opts)
    end

    if opts.background then
        start_check()
    else
        UiBusy.run(_("Checking Anki…"), start_check)
    end
end

local function format_batch_message(sent, failed, reconciled, sync_suffix)
    local parts = {}
    if sent > 0 then
        table.insert(parts, tostring(sent) .. _(" sent"))
    end
    if reconciled > 0 then
        table.insert(parts, tostring(reconciled) .. _(" already in Anki"))
    end
    if failed > 0 then
        table.insert(parts, tostring(failed) .. _(" failed"))
    end
    if #parts == 0 then return _("No pending cards to send.") end
    local msg = table.concat(parts, ", ")
    if reconciled > 0 then
        msg = msg .. " — " .. _("see Recently sent")
    end
    if sent > 0 and sync_suffix and sync_suffix ~= "" then
        msg = msg .. sync_suffix
    end
    return msg
end

-- Wiki/vocab batch: items are { card, storage_idx }.
local function send_wiki_vocab_items(anki_config, ui, items, on_complete, progress_ctx)
    local sent, failed, reconciled = 0, 0, 0
    local last_deck, last_model
    local pos = 1

    local function send_next()
        if pos > #items then
            if on_complete then
                on_complete(sent, failed, reconciled, last_deck, last_model)
            end
            return
        end
        if progress_ctx then
            show_batch_progress(progress_ctx, progress_ctx.offset + pos)
        end
        local item = items[pos]
        pos = pos + 1
        local card = item.card
        local deck = resolve_batch_deck(anki_config, card)
        if not deck or deck == "" then
            failed = failed + 1
            UIManager:scheduleIn(BATCH_SEND_DELAY, send_next)
            return
        end
        local model = SendFlow.effective_model(anki_config, card)
        local status, deck_name, model_name = AnkiSync.send_card_with_status(
            anki_config, card, { deck = deck, model = model, skip_sync = true })
        local mark_deck = deck_name or deck
        local mark_model = model_name or model
        if status == "sent" then
            CardReconcile.finish(item, anki_config, ui, {
                status = "sent",
                deck   = mark_deck,
                model  = mark_model,
            })
            sent = sent + 1
            last_deck = mark_deck
            last_model = mark_model
        elseif status == "duplicate" or status == "verified" then
            local reconcile_status = (status == "duplicate") and "already_in_anki" or "verified"
            CardReconcile.finish(item, anki_config, ui, {
                status = reconcile_status,
                deck   = mark_deck,
                model  = mark_model,
            })
            reconciled = reconciled + 1
            last_deck = mark_deck
            last_model = mark_model
        else
            failed = failed + 1
        end
        UIManager:scheduleIn(BATCH_SEND_DELAY, send_next)
    end

    if #items == 0 then
        if on_complete then on_complete(0, 0, 0, nil, nil) end
    else
        send_next()
    end
end

local function finish_batch_send(anki_config, opts, sent, failed, reconciled, last_deck, last_model)
    clear_batch_progress()
    send_all_in_progress = false
    if last_deck then
        SendFlow.remember_send(anki_config, last_deck, last_model or anki_config.model)
    end
    local sync_suffix = (sent > 0) and AnkiSync.sync_status_suffix(anki_config) or ""
    local msg = format_batch_message(sent, failed, reconciled, sync_suffix)
    if not opts.background or sent > 0 or reconciled > 0 then
        notify(msg)
    end
    if opts.on_done then opts.on_done(sent, failed, reconciled) end
end

-- Send selected wiki/vocab items (shared batch path).
function CardManager.send_batch_items(base_config, ui, items, opts)
    opts = opts or {}
    if send_all_in_progress then return end
    local anki_config = effective_config(base_config)
    if not is_anki_ready(anki_config) then
        if not opts.background then
            notify_error(_("Anki URL not set. Use AnkiKOAi → Settings."))
        end
        if opts.on_done then opts.on_done(0, 0, 0) end
        return
    end
    if not items or #items == 0 then
        if not opts.background then notify(_("No unsent cards to send.")) end
        if opts.on_done then opts.on_done(0, 0, 0) end
        return
    end
    send_all_in_progress = true
    local progress_ctx = (not opts.background) and {
        total  = #items,
        offset = 0,
        label  = _("Sending to Anki…"),
    } or nil
    send_wiki_vocab_items(anki_config, ui, items, function(s, f, r, ld, lm)
        finish_batch_send(anki_config, opts, s, f, r, ld, lm)
    end, progress_ctx)
end

function CardManager.send_all_unsent(base_config, ui, opts)
    opts = opts or {}
    if send_all_in_progress then
        -- Overlapping batch (e.g. background tick while send still running).
        -- Do not call on_done — avoids false backoff in auto_send_tick.
        return
    end
    local anki_config = effective_config(base_config)
    if not is_anki_ready(anki_config) then
        if not opts.background then
            notify_error(_("Anki URL not set. Use AnkiKOAi → Settings."))
        end
        if opts.on_done then opts.on_done(0, 0, 0) end
        return
    end

    local fresh = CardStorage.load_cards()
    local pending_mem, pending_sync = {}, {}
    for idx, card in ipairs(fresh) do
        if not card.sent_to_anki then
            local item = { card = card, storage_idx = idx }
            if CardStorage.is_memorization(card) then
                table.insert(pending_mem, item)
            else
                table.insert(pending_sync, item)
            end
        end
    end

    if #pending_mem == 0 and #pending_sync == 0 then
        if not opts.background then notify(_("No pending cards to send.")) end
        if opts.on_done then opts.on_done(0, 0, 0) end
        return
    end

    -- Background auto-send: one quick reachability check instead of timing out
    -- per card (which freezes e-ink readers when Anki is off).
    if opts.background then
        local reachable = AnkiSync.test_connection(anki_config.url)
        if not reachable then
            if opts.on_done then opts.on_done(0, 0, 0) end
            return
        end
    end

    send_all_in_progress = true
    local sent, failed, reconciled = 0, 0, 0
    local batch_last_deck, batch_last_model
    local total_batch = #pending_sync + #pending_mem
    local progress_ctx = (not opts.background) and {
        total  = total_batch,
        offset = 0,
        label  = _("Sending to Anki…"),
    } or nil

    local function run_memorization_at(index)
        if index > #pending_mem then
            finish_batch_send(anki_config, opts, sent, failed, reconciled,
                batch_last_deck, batch_last_model)
            return
        end
        if progress_ctx then
            progress_ctx.offset = #pending_sync
            show_batch_progress(progress_ctx, progress_ctx.offset + index)
        end
        local item = pending_mem[index]
        send_memorization_card(anki_config, base_config, item.card, ui,
            function(ok)
                if ok then sent = sent + 1 else failed = failed + 1 end
                run_memorization_at(index + 1)
            end, true, item.storage_idx)
    end

    local function after_wiki_vocab(s, f, r, last_deck, last_model)
        sent = sent + s
        failed = failed + f
        reconciled = reconciled + r
        if last_deck then
            batch_last_deck = last_deck
            batch_last_model = last_model
        end
        if #pending_mem > 0 then
            run_memorization_at(1)
        else
            finish_batch_send(anki_config, opts, sent, failed, reconciled,
                batch_last_deck, batch_last_model)
        end
    end

    send_wiki_vocab_items(anki_config, ui, pending_sync, after_wiki_vocab, progress_ctx)
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
        if not card.sent_to_anki then
            local title = (card.book_title and card.book_title ~= "")
                          and card.book_title or _("Unknown book")
            if not book_stats[title] then
                book_stats[title] = 0
                table.insert(book_order, title)
            end
            book_stats[title] = book_stats[title] + 1
        end
    end

    local pending_all = CardStorage.count_pending()

    local stat_items = {}
    if #book_order == 0 then
        table.insert(stat_items, { text = _("(no pending cards)") })
    end
    for _i, title in ipairs(book_order) do
        local n = book_stats[title]
        local line = title .. "  —  " .. tostring(n)
            .. (n == 1 and _(" pending card") or _(" pending cards"))
        table.insert(stat_items, { text = line })
    end
    table.insert(stat_items, {
        text           = _("See Recently sent for confirmed sends."),
        select_enabled = false,
    })

    local title_str = _("Stats — ")
        .. tostring(pending_all)
        .. (pending_all == 1 and _(" pending card") or _(" pending cards"))

    Nav.show_menu {
        title      = title_str,
        items      = stat_items,
        back_label = _("← Back"),
        on_back    = on_back,
    }
end

local function show_recent_sent(on_back)
    local entries = CardStorage.load_recent_sent()
    local items = {}
    if #entries == 0 then
        table.insert(items, {
            text           = _("(nothing sent recently)"),
            select_enabled = false,
        })
    end
    for _i, e in ipairs(entries) do
        local phrase = SelectableMenu.truncate(e.phrase or "", 24)
        local book = SelectableMenu.truncate(e.book_title or "", 16)
        local deck = SelectableMenu.truncate(e.deck or "", 12)
        local status = CardReconcile.send_status_label(e.status)
        local date = os.date("%Y-%m-%d", e.sent_at or os.time())
        local line = phrase .. " · " .. book .. " · " .. deck
            .. " · " .. status .. " · " .. date
        table.insert(items, {
            text = line,
            callback = function()
                UIManager:show(InfoMessage:new {
                    text = (e.phrase or "") .. "\n\n"
                        .. _("Book: ") .. (e.book_title or "") .. "\n"
                        .. _("Deck: ") .. (e.deck or "") .. "\n"
                        .. _("Note type: ") .. (e.model or "") .. "\n"
                        .. _("Status: ") .. status .. "\n\n"
                        .. _("Open Anki on your PC to study this card."),
                    timeout = 10,
                })
            end,
        })
    end
    table.insert(items, {
        text = _("Clear recent list"),
        callback = function()
            UIManager:show(ConfirmBox:new {
                text = _("Clear all Recently sent entries? This cannot be undone."),
                ok_text = _("Clear"),
                ok_callback = function()
                    CardStorage.clear_recent_sent()
                    show_recent_sent(on_back)
                end,
            })
        end,
    })

    Nav.show_menu {
        title      = _("Recently sent (") .. tostring(#entries) .. ")",
        items      = items,
        back_label = _("← Back"),
        on_back    = on_back,
    }
end

local function group_cards_by_book(all_cards)
    local groups = {}
    local index = {}
    for storage_idx, card in ipairs(all_cards) do
        if not card.sent_to_anki then
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
        local saved_count = CardStorage.count_pending()
        local unsent_count = saved_count
        local send_label = _("Send All Unsent to Anki")
        if unsent_count > 0 then
            send_label = send_label .. " (" .. tostring(unsent_count) .. ")"
        end
        local recent_count = #CardStorage.load_recent_sent()
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
                text = _("Recently sent") .. " (" .. tostring(recent_count) .. ")",
                bold = true,
                callback = function()
                    open_child(function() show_recent_sent(reopen_manage) end)
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

    local function my_cards_title(pending)
        pending = pending or CardStorage.count_pending()
        if pending > 0 then
            return _("My Cards (") .. tostring(pending) .. _(" pending)")
        end
        return _("My Cards")
    end

    local function update_root_title()
        local menu = menu_ref[1]
        if not menu then return end
        local title = my_cards_title()
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
                    text           = _("(no pending cards)"),
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
            Nav.replace_menu_items(menu, item_table, my_cards_title())
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
        local pending_check_items = {}
        for _i, item in ipairs(group.cards) do
            local card = item.card
            if not CardStorage.is_memorization(card) then
                table.insert(pending_check_items, {
                    card = card,
                    storage_idx = item.storage_idx,
                })
            end
        end
        for _i, item in ipairs(group.cards) do
            local card = item.card
            local phrase = card.phrase or ""
            if CardStorage.is_memorization(card) then
                phrase = phrase .. "  [" .. _("memorization") .. "]"
            end
            if #phrase > 50 then phrase = phrase:sub(1, 50) .. "…" end
            table.insert(entries, {
                key   = book_title .. "\0" .. tostring(item.storage_idx),
                label = phrase .. "  (" .. (card.date or "") .. ")",
                data  = item,
            })
        end

        local items = {}
        local list_state = { entries = entries, selected = selected, opts = nil }
        local leading_items = {}
        if #pending_check_items > 0 then
            table.insert(leading_items, {
                text = _("Check pending against Anki") .. " (" .. tostring(#pending_check_items) .. ")",
                bold = true,
                callback = function()
                    UIManager:show(ConfirmBox:new {
                        text = _("Check all pending cards in this book against Anki? Matches by Phrase in the target deck only. Does not create notes. Found cards are removed from the queue and logged to Recently sent."),
                        ok_text = _("Check Anki"),
                        ok_callback = function()
                            CardManager.check_items_against_anki(base_config, pending_check_items, {
                                ui = ui,
                                on_done = function()
                                    refresh_book_submenu(book_title)
                                end,
                            })
                        end,
                    })
                end,
            })
        end
        local list_opts = {
            entries    = entries,
            selected   = selected,
            leading_items = leading_items,
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
            on_send_selected = function(picked)
                local batch, skipped_mem = filter_unsent_wiki_vocab_picked(picked)
                if #batch == 0 then
                    notify_check_skips(skipped_mem)
                    if skipped_mem == 0 then
                        notify(_("No pending cards to send."))
                    end
                    return
                end
                if skipped_mem > 0 then
                    notify(_("Skipping memorization rows."))
                end
                CardManager.send_batch_items(base_config, ui, batch, {
                    on_done = function()
                        refresh_book_submenu(book_title)
                    end,
                })
            end,
            on_check_anki_selected = function(picked)
                local batch, skipped_mem = filter_unsent_wiki_vocab_picked(picked)
                if #batch == 0 then
                    notify_check_skips(skipped_mem)
                    if skipped_mem == 0 then
                        notify(_("No pending cards to check."))
                    end
                    return
                end
                if skipped_mem > 0 then
                    notify(_("Skipping memorization rows."))
                end
                CardManager.check_items_against_anki(base_config, batch, {
                    ui = ui,
                    on_done = function()
                        refresh_book_submenu(book_title)
                    end,
                })
            end,
            check_anki_selected_confirm = _("Check selected pending cards against Anki? Matches by Phrase in the target deck only. Does not create notes. Found cards are removed from the queue and logged to Recently sent."),
            on_remove_from_queue_selected = function(picked)
                local removed = 0
                for _i, entry in ipairs(picked) do
                    local card = entry.data.card
                    if CardStorage.delete_matching_card(card) then
                        removed = removed + 1
                        if ui and card.highlight_pos0 then
                            if CardStorage.is_memorization(card)
                                or CardFields.is_dictionary_card(card, { anki = anki_config }) then
                                HighlightStatus.remove_highlight(
                                    ui, card.highlight_pos0, card.highlight_pos1)
                            end
                        end
                    end
                end
                notify(tostring(removed) .. _(" card(s) removed from queue"))
            end,
            remove_from_queue_confirm = _("Remove selected cards from the pending queue? This does not change Anki."),
            after_remove_from_queue = function() refresh_book_submenu(book_title) end,
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
    local pending_count = CardStorage.count_pending()
    local recent_count = #CardStorage.load_recent_sent()
    local item_table = {}

    if pending_count > 0 then
        table.insert(item_table, {
            text     = _("Send pending to Anki") .. " (" .. tostring(pending_count) .. ")",
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

    table.insert(item_table, {
        text = _("Recently sent") .. " (" .. tostring(recent_count) .. ")",
        bold = true,
        callback = function()
            guard.busy = true
            Nav.after_close(function()
                if menu_ref[1] then UIManager:close(menu_ref[1]) end
            end, function()
                guard.busy = false
                show_recent_sent(function()
                    CardManager.show(base_config, nil, ui, opts)
                end)
            end)
        end,
    })

    if #groups == 0 then
        table.insert(item_table, {
            text           = _("(no pending cards)"),
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

    local title = my_cards_title(pending_count)
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
