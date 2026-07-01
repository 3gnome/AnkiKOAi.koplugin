-- Reconcile pending cards with Anki: log to Recently sent, delete from queue, highlight policy.

local _               = require("gettext")
local CardStorage     = require("card_storage")
local CardFields      = require("card_fields")
local HighlightStatus = require("highlight_status")
local NoteTypeProfiles = require("note_type_profiles")

local CardReconcile = {}

local function effective_model(config, card)
    return NoteTypeProfiles.normalize_model_name(
        (card and card.target_model and card.target_model ~= "") and card.target_model
        or (card and card.model and card.model ~= "") and card.model
        or CardFields.default_wiki_model({ anki = config }))
end

local function card_kind_for(card, anki_config)
    if CardStorage.is_memorization(card) then
        return "memorization"
    end
    if CardFields.is_dictionary_card(card, { anki = anki_config }) then
        return "vocabulary"
    end
    return "wiki"
end

function CardReconcile.send_status_label(status)
    if status == "sent" then return _("Sent")
    elseif status == "duplicate" or status == "already_in_anki" then return _("Already in Anki")
    elseif status == "verified" then return _("Verified in Anki")
    elseif status == "checked" then return _("Found in Anki")
    end
    return status or ""
end

function CardReconcile.finish(item, anki_config, ui, opts)
    opts = opts or {}
    local card = item and item.card
    if not card then return false end

    local deck = opts.deck or card.target_deck or ""
    local model = opts.model or effective_model(anki_config, card)
    local status = opts.status or "sent"
    local pos0, pos1 = card.highlight_pos0, card.highlight_pos1

    CardStorage.record_recent_sent({
        phrase      = card.phrase or "",
        book_title  = card.book_title or "",
        card_kind   = card_kind_for(card, anki_config),
        deck        = deck,
        model       = model,
        status      = status,
        sent_at     = os.time(),
        highlight_pos0 = pos0,
        highlight_pos1 = pos1,
    })

    CardStorage.delete_matching_card(card)

    if ui and pos0 then
        local kind = card_kind_for(card, anki_config)
        if kind == "wiki" then
            HighlightStatus.mark_sent(ui, pos0, pos1)
        else
            HighlightStatus.remove_highlight(ui, pos0, pos1)
        end
    end

    return true
end

return CardReconcile
