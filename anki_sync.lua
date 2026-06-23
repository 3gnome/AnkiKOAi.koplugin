-- AnkiConnect HTTP client.

local http  = require("socket.http")
local ltn12 = require("ltn12")
local json  = require("json")
local _      = require("gettext")

local CardFields       = require("card_fields")
local NoteTypeProfiles = require("note_type_profiles")
local WikiSources      = require("wiki_sources")

local TIMEOUT = 5
local SYNC_TIMEOUT = 120
local AnkiSync = {}

function AnkiSync.default_model()
    return NoteTypeProfiles.DEFAULT_MODEL
end

-- Base deck before subdeck expansion (respects per-book mapping).
function AnkiSync.resolve_base_deck(config, card)
    config = config or {}
    local base = (config.deck and config.deck ~= "") and config.deck or "English::Koreader"
    if card and card.book_title and card.book_title ~= ""
       and type(config.per_book_decks) == "table" then
        local mapped = config.per_book_decks[card.book_title]
        if mapped and mapped ~= "" then base = mapped end
    end
    return base
end

function AnkiSync.resolve_deck_name(config, card, base_deck)
    config = config or {}
    local base = (base_deck and base_deck ~= "") and base_deck
                 or AnkiSync.resolve_base_deck(config, card)

    if config.subdeck_by_book == false then return base end

    local title = card and card.book_title and card.book_title ~= "" and card.book_title
    if not title then return base end
    local safe = title:gsub(":", " -"):match("^%s*(.-)%s*$")
    if safe == "" then return base end
    local parent = base:match("^([^:]+)") or base
    return parent .. "::" .. safe
end

local function post(url, action, params, timeout_sec)
    local body     = json.encode({ action = action, version = 6, params = params or {} })
    local response = {}
    http.TIMEOUT = timeout_sec or TIMEOUT
    local ok, code = http.request {
        url     = url,
        method  = "POST",
        headers = {
            ["Content-Type"]   = "application/json",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink   = ltn12.sink.table(response),
    }
    if not ok or tostring(code) ~= "200" then
        local reason = tostring(code)
        if reason == "timeout" or reason:find("unreachable") or reason:find("refused") then
            return nil, "Cannot reach Anki. Check URL in Settings."
        end
        return nil, "HTTP error: " .. reason
    end
    local ok2, result = pcall(json.decode, table.concat(response))
    if not ok2 then return nil, "JSON decode error" end
    return result
end

function AnkiSync.test_connection(url)
    local result, err = post(url, "requestPermission", {})
    if not result then return nil, err end
    if type(result.error) == "string" then return nil, result.error end
    if result.result == nil then
        return nil, "Permission denied or unexpected response"
    end
    return true
end

function AnkiSync.get_deck_names(url)
    local result, err = post(url, "deckNames", {})
    if not result then return nil, err end
    if type(result.error) == "string" then return nil, result.error end
    if type(result.result) ~= "table" then return nil, "Unexpected deckNames response" end
    return result.result
end

function AnkiSync.get_model_names(url)
    local result, err = post(url, "modelNames", {})
    if not result then return nil, err end
    if type(result.error) == "string" then return nil, result.error end
    if type(result.result) ~= "table" then return nil, "Unexpected modelNames response" end
    return result.result
end

function AnkiSync.get_model_field_names(url, model_name)
    local result, err = post(url, "modelFieldNames", { modelName = model_name })
    if not result then return nil, err end
    if type(result.error) == "string" then return nil, result.error end
    if type(result.result) ~= "table" then return nil, "Unexpected modelFieldNames response" end
    return result.result
end

function AnkiSync.count_notes_in_deck(url, deck_name)
    if not url or url == "" or not deck_name or deck_name == "" then
        return nil, "Deck name not set"
    end
    local escaped = deck_name:gsub("\\", "\\\\"):gsub('"', '\\"')
    local result, err = post(url, "findNotes", { query = 'deck:"' .. escaped .. '"' })
    if not result then return nil, err end
    if type(result.error) == "string" then return nil, result.error end
    if type(result.result) ~= "table" then return nil, "Unexpected findNotes response" end
    return #result.result
end

function AnkiSync.sync_after_send_enabled(config)
    config = config or {}
    return config.sync_after_send ~= false
end

function AnkiSync.sync_collection(url)
    if not url or url == "" then
        return nil, "Anki URL not configured"
    end
    local result, err = post(url, "sync", {}, SYNC_TIMEOUT)
    if not result then return nil, err end
    if type(result.error) == "string" then return nil, result.error end
    return true
end

-- Returns a user-visible suffix (empty if disabled, skipped, or sync OK).
function AnkiSync.sync_status_suffix(config)
    if not AnkiSync.sync_after_send_enabled(config) then
        return ""
    end
    if not config or not config.url or config.url == "" then
        return ""
    end
    local ok, err = AnkiSync.sync_collection(config.url)
    if ok then
        return _("\nSynced to AnkiWeb.")
    end
    return _("\n(Sync to AnkiWeb failed: ") .. (err or "?") .. ")"
end

function AnkiSync.ensure_deck(url, deck_name)
    if not url or url == "" or not deck_name or deck_name == "" then
        return nil, "Deck name not set"
    end
    local result, err = post(url, "createDeck", { deck = deck_name })
    if not result then return nil, err end
    if type(result.error) == "string" then
        local lower = result.error:lower()
        if lower:find("exists") then return true end
        return nil, result.error
    end
    return true
end

function AnkiSync.add_note(url, note)
    if not url or url == "" then return nil, "Anki URL not configured" end
    local result, err = post(url, "addNote", { note = note })
    if not result then return nil, err end
    if type(result.error) == "string" then return nil, result.error end
    return true
end

function AnkiSync.send_card(config, card, opts)
    if not config or not config.url or config.url == "" then
        return nil, "Anki URL not configured"
    end

    opts = opts or {}
    CardFields.normalize(card, config)

    local base_deck = (opts.deck and opts.deck ~= "") and opts.deck or config.deck
    local model = NoteTypeProfiles.normalize_model_name(
        (opts.model and opts.model ~= "") and opts.model
        or card.model or CardFields.default_wiki_model({ anki = config }))

    local field_names = require("note_type_picker").fetch_field_names(config, model)
    if not field_names or #field_names == 0 then
        if NoteTypeProfiles.is_vocabulary_card(model) then
            field_names = NoteTypeProfiles.VOCABULARY_CARD_FIELDS
        else
            field_names = NoteTypeProfiles.INFORMATION_FIELDS
        end
    end

    local deck_name = AnkiSync.resolve_deck_name(config, card, base_deck)
    local ensured, deck_err = AnkiSync.ensure_deck(config.url, deck_name)
    if not ensured then return nil, deck_err end

    if NoteTypeProfiles.is_wiki_card(model) and WikiSources.is_enabled(config) then
        local existing = (card.anki_fields and card.anki_fields.Links) or card.links or ""
        if existing == "" then
            local sources = card._wiki_sources
            if WikiSources.has_content(sources) then
                WikiSources.apply_links_to_card(card, sources, field_names)
                CardFields.sync_flat_from_anki(card)
            end
        end
    end

    local fields
    if CardFields.is_dictionary_card(card, config) then
        fields = CardFields.dictionary_fields_for_send(card, field_names)
    else
        fields = CardFields.fields_for_send(card, field_names)
    end

    local note = {
        deckName  = deck_name,
        modelName = model,
        fields    = fields,
        options   = {
            allowDuplicate = false,
            duplicateScope = "deck",
        },
        tags = (config.tags_enabled == false) and {} or (config.tags or { "KOReader" }),
    }

    local result, err = post(config.url, "addNote", { note = note })
    if not result then return nil, err end
    if type(result.error) == "string" then return nil, result.error end
    local sync_suffix = ""
    if not opts.skip_sync then
        sync_suffix = AnkiSync.sync_status_suffix(config)
    end
    return true, sync_suffix
end

return AnkiSync
