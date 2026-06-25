-- Send flow: deck picker at send time; note type chosen at generation.

local ConfirmBox     = require("ui/widget/confirmbox")
local Notification   = require("ui/widget/notification")
local UIManager      = require("ui/uimanager")
local _              = require("gettext")

local AnkiSync         = require("anki_sync")
local CardDefaults     = require("card_defaults")
local CardStorage      = require("card_storage")
local DeckPicker       = require("deck_picker")
local HighlightStatus  = require("highlight_status")
local CardFields       = require("card_fields")
local NoteTypeProfiles = require("note_type_profiles")
local UiBusy           = require("ui_busy")

local SendFlow = {}

-- Sentinel for user-dismissed flows (deck picker, confirm box). Do not compare translated strings.
SendFlow.CANCELLED = "__ankikooai_cancelled__"

function SendFlow.is_cancelled(err)
    return err == SendFlow.CANCELLED or err == _("Cancelled")
end

local function touch_recent_deck(config, deck)
    config.recent_decks = config.recent_decks or {}
    local list = {}
    table.insert(list, deck)
    for _i, d in ipairs(config.recent_decks) do
        if d ~= deck and #list < 5 then table.insert(list, d) end
    end
    config.recent_decks = list
    CardStorage.save_anki_settings(config)
end

function SendFlow.effective_model(config, card)
    return NoteTypeProfiles.normalize_model_name(
        (card and card.target_model and card.target_model ~= "") and card.target_model
        or (card and card.model and card.model ~= "") and card.model
        or CardFields.default_wiki_model({ anki = config }))
end

function SendFlow.remember_send(config, deck, model)
    config.last_send_deck  = deck
    config.last_send_model = model
    CardStorage.save_anki_settings(config)
end

-- use_configured_deck: prefer card.target_deck and per-type Card defaults.
-- Default (viewer quick-send): prefer last_send_deck for repeat manual sends.
function SendFlow.resolve_deck(config, card, opts)
    opts = opts or {}
    config = config or {}
    if card and card.target_deck and card.target_deck ~= "" then
        return card.target_deck
    end
    local configured = CardDefaults.deck_for_card({ anki = config }, card)
    if opts.use_configured_deck then
        return configured
    end
    return config.last_send_deck or configured
end

function SendFlow.can_quick_send(config, card, opts)
    local deck = SendFlow.resolve_deck(config, card, opts)
    return deck and deck ~= ""
end

local function finish_send(config, card, deck, model, ui, done)
    local ok, err_or_suffix = AnkiSync.send_card(config, card, {
        deck  = deck,
        model = model,
    })
    if ok then
        if card then
            card.target_deck  = deck
            card.target_model = model
            card.sent_to_anki = true
            CardStorage.save_or_update(card)
        end
        touch_recent_deck(config, deck)
        SendFlow.remember_send(config, deck, model)
        if ui and card and card.highlight_pos0 then
            HighlightStatus.mark_sent(ui, card.highlight_pos0, card.highlight_pos1)
        end
        if err_or_suffix and err_or_suffix ~= "" then
            UIManager:show(Notification:new {
                text    = err_or_suffix:gsub("^%s+", ""),
                timeout = 4,
            })
        end
    end
    if done then done(ok, ok and nil or err_or_suffix) end
end

function SendFlow.execute_send(config, card, deck, model, ui, done, opts)
    opts = opts or {}
    config = config or {}
    model = model or SendFlow.effective_model(config, card)
    deck = deck or SendFlow.resolve_deck(config, card, opts)

    if not deck or deck == "" then
        if done then done(nil, _("No deck selected")) end
        return
    end

    local function proceed()
        UiBusy.run(_("Sending to Anki…"), function()
            finish_send(config, card, deck, model, ui, done)
        end)
    end

    if opts.skip_duplicate_check then
        proceed()
        return
    end

    local dup = CardStorage.find_sent_duplicate(
        card and card.phrase, card and card.book_title)
    if dup then
        UIManager:show(ConfirmBox:new {
            text = _("This phrase was already sent to Anki from this book. Send again?"),
            ok_text = _("Send anyway"),
            ok_callback = proceed,
            cancel_callback = function()
                if done then done(nil, SendFlow.CANCELLED) end
            end,
        })
        return
    end
    proceed()
end

function SendFlow.prompt_and_send(config, card, done, opts)
    opts = opts or {}
    config = config or {}
    if not config.url or config.url == "" then
        if done then
            done(nil, _("AnkiConnect URL not set. Use AnkiKOAi → Settings."))
        end
        return
    end
    local model = SendFlow.effective_model(config, card)
    local deck_initial = (card and card.target_deck and card.target_deck ~= "")
                       and card.target_deck
                       or config.last_send_deck
                       or AnkiSync.resolve_base_deck(config, card)

    DeckPicker.show(config, card, function(chosen_deck)
        SendFlow.execute_send(
            config, card, chosen_deck, model,
            opts.ui, done, opts)
    end, {
        current_deck = deck_initial,
        title        = _("Choose Deck"),
        on_cancel    = function()
            if done then done(nil, SendFlow.CANCELLED) end
        end,
    })
end

function SendFlow.quick_send(config, card, done, opts)
    opts = opts or {}
    local deck = SendFlow.resolve_deck(config, card, opts)
    if not SendFlow.can_quick_send(config, card, opts) then
        SendFlow.prompt_and_send(config, card, done, opts)
        return
    end
    SendFlow.execute_send(
        config, card, deck,
        SendFlow.effective_model(config, card),
        opts.ui, done, opts)
end

function SendFlow.viewer_callbacks(config, card, ui)
    config = config or {}
    return {
        can_quick_send = SendFlow.can_quick_send(config, card),
        on_send = function(done)
            SendFlow.prompt_and_send(config, card, done, { ui = ui })
        end,
        on_quick_send = function(done)
            SendFlow.quick_send(config, card, done, { ui = ui })
        end,
    }
end

return SendFlow
