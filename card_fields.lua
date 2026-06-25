-- Normalize card field storage: flat legacy keys + dynamic anki_fields table.

local NoteTypeProfiles = require("note_type_profiles")
local CardStorage      = require("card_storage")
local _                = require("gettext")

local CardFields = {}

local function merged_anki_settings(config)
    local cfg = {}
    if config and type(config.anki) == "table" then
        for k, v in pairs(config.anki) do cfg[k] = v end
    end
    local saved = CardStorage.load_anki_settings()
    if saved then
        for k, v in pairs(saved) do cfg[k] = v end
    end
    return cfg
end

local function raw_wiki_note_type(ac)
    ac = ac or {}
    return ac.wiki_note_type or ac.note_type or ac.model
end

function CardFields.default_wiki_model(config)
    local ac = merged_anki_settings(config)
    local name = NoteTypeProfiles.normalize_model_name(
        raw_wiki_note_type(ac) or NoteTypeProfiles.DEFAULT_MODEL)
    if NoteTypeProfiles.is_wiki_compatible(name) then
        return name
    end
    return NoteTypeProfiles.DEFAULT_MODEL
end

function CardFields.default_vocabulary_model(config)
    local ac = merged_anki_settings(config)
    local name = ac.vocabulary_model or NoteTypeProfiles.VOCABULARY_CARD_MODEL
    if NoteTypeProfiles.is_vocabulary_compatible(name) then
        return name
    end
    return NoteTypeProfiles.VOCABULARY_CARD_MODEL
end

function CardFields.default_memorization_model(config)
    local ac = merged_anki_settings(config)
    local name = ac.memorize_model
    if (not name or name == "") and ac.memorize and type(ac.memorize) == "table" then
        name = ac.memorize.model
    end
    name = name or NoteTypeProfiles.MEMORIZATION_MODEL
    if NoteTypeProfiles.is_memorization_compatible(name) then
        return name
    end
    return NoteTypeProfiles.MEMORIZATION_MODEL
end

-- Fix legacy settings where vocabulary/memorization types were saved as wiki default.
-- Mutates settings in place. Returns optional user-facing notice (newline-separated).
function CardFields.migrate_anki_settings(settings)
    if type(settings) ~= "table" then return settings, nil end

    local notices = {}
    local legacy = raw_wiki_note_type(settings)

    if legacy and legacy ~= "" then
        legacy = NoteTypeProfiles.normalize_model_name(legacy)
        if NoteTypeProfiles.is_vocabulary_card(legacy) then
            if not settings.vocabulary_model or settings.vocabulary_model == "" then
                settings.vocabulary_model = legacy
            end
            legacy = NoteTypeProfiles.DEFAULT_MODEL
            table.insert(notices, _(
                "Vocabulary Card was set as the wiki default; reset to Wiki Card."))
        elseif NoteTypeProfiles.is_memorization(legacy) then
            if not settings.memorize_model or settings.memorize_model == "" then
                settings.memorize_model = legacy
            end
            settings.memorize = settings.memorize or {}
            if type(settings.memorize) == "table"
               and (not settings.memorize.model or settings.memorize.model == "") then
                settings.memorize.model = legacy
            end
            legacy = NoteTypeProfiles.DEFAULT_MODEL
            table.insert(notices, _(
                "Memorization was set as the wiki default; reset to Wiki Card."))
        end
    end

    local wiki = NoteTypeProfiles.normalize_model_name(
        settings.wiki_note_type or legacy or NoteTypeProfiles.DEFAULT_MODEL)
    if not NoteTypeProfiles.is_wiki_compatible(wiki) then
        wiki = NoteTypeProfiles.DEFAULT_MODEL
        table.insert(notices, _("Invalid wiki note type; using Wiki Card."))
    end
    settings.wiki_note_type = wiki
    settings.model = wiki

    local vocab = settings.vocabulary_model or NoteTypeProfiles.VOCABULARY_CARD_MODEL
    if not NoteTypeProfiles.is_vocabulary_compatible(vocab) then
        settings.vocabulary_model = NoteTypeProfiles.VOCABULARY_CARD_MODEL
        table.insert(notices, _("Invalid vocabulary note type; using Vocabulary Card."))
    end

    local mem = settings.memorize_model
    if (not mem or mem == "") and settings.memorize and type(settings.memorize) == "table" then
        mem = settings.memorize.model
    end
    if mem and mem ~= "" and not NoteTypeProfiles.is_memorization_compatible(mem) then
        settings.memorize_model = NoteTypeProfiles.MEMORIZATION_MODEL
        settings.memorize = settings.memorize or {}
        settings.memorize.model = NoteTypeProfiles.MEMORIZATION_MODEL
        table.insert(notices, _("Invalid memorization note type; using Memorization."))
    end

    -- send_on_save (removed) → per-type auto-send toggles
    if settings.send_on_save == true then
        if settings.auto_send_wiki ~= true then
            settings.auto_send_wiki = true
        end
        if settings.auto_send_vocabulary ~= true then
            settings.auto_send_vocabulary = true
        end
        if settings.auto_send_memorization ~= true then
            settings.auto_send_memorization = true
        end
        settings.send_on_save = nil
        table.insert(notices, _(
            "“Send after generate” is now per card type under Card defaults."))
    end

    -- Legacy memorization auto-send key
    if settings.memorize_auto_send == true and settings.auto_send_memorization ~= true then
        settings.auto_send_memorization = true
    end
    settings.memorize_auto_send = nil

    -- Legacy skip-hub → unified toggle when unset
    if settings.auto_send_skip_hub_submenu == nil
       and settings.memorize_skip_hub_submenu == true then
        settings.auto_send_skip_hub_submenu = true
    end

    -- Legacy shared deck → per-type defaults
    local legacy_deck = (settings.deck and settings.deck ~= "") and settings.deck or nil
    if legacy_deck then
        if not settings.wiki_deck or settings.wiki_deck == "" then
            settings.wiki_deck = legacy_deck
        end
        if not settings.vocabulary_deck or settings.vocabulary_deck == "" then
            settings.vocabulary_deck = legacy_deck
        end
    end

    if #notices == 0 then return settings, nil end
    return settings, table.concat(notices, "\n")
end

function CardFields.merged_anki_settings(config)
    return merged_anki_settings(config)
end

-- Top-level config (API keys, providers) overlaid with saved anki settings.
function CardFields.effective_config(config)
    local eff = {}
    if config then
        for k, v in pairs(config) do
            if k ~= "anki" then eff[k] = v end
        end
    end
    -- Top-level `model` is the LLM id (e.g. qwen-plus); Anki note type overwrites `model` below.
    if eff.model and eff.model ~= "" then
        eff.llm_model = eff.model
    end
    local anki = merged_anki_settings(config)
    for k, v in pairs(anki) do eff[k] = v end
    return eff
end

-- Citation string from open book metadata (preferred for Source field).
function CardFields.format_book_source(title, author)
    title  = (title  or ""):match("^%s*(.-)%s*$") or ""
    author = (author or ""):match("^%s*(.-)%s*$") or ""
    if title ~= "" and author ~= "" then
        return title .. " — " .. author
    elseif title ~= "" then
        return title
    elseif author ~= "" then
        return author
    end
    return ""
end

function CardFields.set_source(card, source)
    if not card or not source or source == "" then return end
    card.source = source
    card.anki_fields = card.anki_fields or {}
    card.anki_fields.Source = source
end

-- Source = book citation when reading; optional fallback (e.g. dictionary URL).
function CardFields.apply_reading_source(card, title, author, fallback, location)
    if not card then return end
    local book = CardFields.format_book_source(title, author)
    if location and location ~= "" then
        if book ~= "" then
            book = book .. " (" .. location .. ")"
        else
            book = location
        end
    end
    if book ~= "" then
        CardFields.set_source(card, book)
        return
    end
    if type(fallback) == "string" and fallback ~= "" then
        CardFields.set_source(card, fallback)
    end
end

-- Sync legacy flat keys from anki_fields (Information card layout).
function CardFields.sync_flat_from_anki(card)
    if not card or type(card.anki_fields) ~= "table" then return end
    local f = card.anki_fields
    card.phrase     = f.Phrase     or f.phrase     or card.phrase     or ""
    card.ipa        = f.IPA        or f.ipa        or card.ipa        or ""
    card.definition = f.Definition or f.definition or card.definition or ""
    card.synonyms   = f.Synonyms   or f.synonyms   or card.synonyms   or ""
    card.text       = f.Text       or f.text       or f.Context      or f.context or card.text or ""
    card.context    = f.Context    or f.context    or card.context   or card.text or ""
    card.links      = f.Links      or f.links      or card.links      or ""
    card.source     = f.Source     or f.source     or card.source     or ""
end

-- Build anki_fields from legacy flat card.
function CardFields.sync_anki_from_flat(card)
    if not card then return end
    card.anki_fields = card.anki_fields or {}
    local f = card.anki_fields
    if card.phrase     and card.phrase     ~= "" then f.Phrase     = card.phrase     end
    if card.ipa        and card.ipa        ~= "" then f.IPA        = card.ipa        end
    if card.definition and card.definition ~= "" then f.Definition = card.definition end
    if card.synonyms   and card.synonyms   ~= "" then f.Synonyms   = card.synonyms   end
    if card.text       and card.text       ~= "" then f.Text       = card.text       end
    if card.context    and card.context    ~= "" then f.Context    = card.context    end
    if card.links      and card.links      ~= "" then f.Links      = card.links      end
    if card.source     and card.source     ~= "" then f.Source     = card.source     end
end

function CardFields.normalize(card, config)
    if type(card) ~= "table" then return card end
    card.model = NoteTypeProfiles.normalize_model_name(
        card.model or card.target_model or CardFields.default_wiki_model(config))

    if type(card.anki_fields) == "table" and next(card.anki_fields) then
        CardFields.sync_flat_from_anki(card)
    else
        CardFields.sync_anki_from_flat(card)
    end

    if card.phrase == "" then
        card.phrase = card.anki_fields.Phrase or card.anki_fields.Front
                      or card.anki_fields.front or ""
    end
    return card
end

-- Merge LLM JSON (any key casing) into anki_fields for known Anki field names.
function CardFields.apply_llm_fields(card, field_names, llm_data)
    card.anki_fields = card.anki_fields or {}
    local lower_map = {}
    for k, v in pairs(llm_data or {}) do
        lower_map[k:lower()] = v
    end
    for _, fname in ipairs(field_names or {}) do
        if fname:lower() ~= "source" then
            local val = llm_data[fname]
            if val == nil then val = lower_map[fname:lower()] end
            if val ~= nil then card.anki_fields[fname] = tostring(val) end
        end
    end
    CardFields.sync_flat_from_anki(card)
    return card
end

-- Map an Anki field name to a piece of dictionary data by common conventions.
-- Returns (value, role) or nil if the field name isn't recognized.
local function dictionary_value_for_field(fname, data)
    local n = (fname or ""):lower():gsub("%s+", "")
    if n == "phrase" or n == "word" or n == "term" or n == "vocabulary"
       or n == "vocab" or n == "headword" or n == "expression"
       or n == "front" or n == "question" or n == "prompt" then
        return data.phrase, "term"
    end
    if n == "definition" or n == "meaning" or n == "def" or n == "gloss"
       or n == "explanation" or n == "back" or n == "answer" or n == "response"
       or n == "notes" or n == "note" or n == "extra" then
        return data.definition, "definition"
    end
    if n == "context" or n == "example" or n == "examples" or n == "sentence"
       or n == "passage" or n == "usage" or n == "quote" or n == "excerpt" then
        return data.context, "context"
    end
    if n == "ipa" or n == "pronunciation" or n == "reading" or n == "phonetic" then
        return data.ipa, "ipa"
    end
    if n == "source" or n == "reference" or n == "book" or n == "citation"
       or n == "origin" then
        return data.source, "source"
    end
    return nil
end

-- Build the Anki field payload for a dictionary (no-AI) card, mapping the
-- looked-up word/definition/passage/source onto whatever fields the chosen
-- note type actually has. Falls back so content is never silently dropped.
function CardFields.dictionary_fields_for_send(card, field_names)
    card = card or {}
    local af = card.anki_fields or {}
    local data = {
        phrase     = card.phrase     or af.Phrase     or "",
        definition = card.definition or af.Definition or "",
        context    = card.context    or card.text or af.Context or "",
        source     = card.source     or af.Source     or "",
        ipa        = card.ipa        or af.IPA        or "",
    }

    field_names = field_names or {}
    if #field_names == 0 then
        return {
            Phrase     = data.phrase,
            Definition = data.definition,
            Context    = data.context,
            Source     = data.source,
        }
    end

    local out = {}
    local term_field, def_field, context_matched
    for _, fname in ipairs(field_names) do
        local v, role = dictionary_value_for_field(fname, data)
        out[fname] = v or ""
        if role == "term"       and not term_field then term_field = fname end
        if role == "definition" and not def_field  then def_field  = fname end
        if role == "context"    and v and v ~= ""  then context_matched = true end
    end

    -- Fallbacks for note types that don't use recognizable field names.
    if not term_field and data.phrase ~= "" then
        term_field = field_names[1]
        out[term_field] = data.phrase
    end
    if not def_field and data.definition ~= "" then
        for _, fname in ipairs(field_names) do
            if fname ~= term_field then def_field = fname break end
        end
        def_field = def_field or term_field or field_names[1]
        local existing = out[def_field] or ""
        out[def_field] = (existing ~= "" and (existing .. "\n\n") or "") .. data.definition
    end
    -- Keep the book passage even when the note type has no context field.
    if not context_matched and data.context ~= "" and def_field then
        out[def_field] = (out[def_field] ~= "" and (out[def_field] .. "\n\n") or "")
                         .. data.context
    end

    return out
end

function CardFields.fields_for_send(card, field_names)
    local out = {}
    local src = card.anki_fields or {}
    for _, fname in ipairs(field_names or {}) do
        out[fname] = src[fname] or ""
    end
    -- Legacy fallback
    if not next(out) then
        out = {
            Phrase     = card.phrase     or "",
            IPA        = card.ipa        or "",
            Definition = card.definition or "",
            Synonyms   = card.synonyms   or "",
            Text       = card.text       or "",
            Context    = card.context    or card.text or "",
            Links      = card.links      or "",
            Source     = card.source     or "",
        }
    end
    return out
end

function CardFields.editable_field_list(card)
    card = CardFields.normalize(card, {})
    local skip = { Source = true, source = true }
    local list = {}
    if type(card.anki_fields) == "table" then
        for fname, val in pairs(card.anki_fields) do
            if not skip[fname] then
                table.insert(list, { key = fname, label = fname, anki = true })
            end
        end
        table.sort(list, function(a, b) return a.label < b.label end)
    end
    if #list == 0 then
        return {
            { key = "phrase",     label = "Phrase" },
            { key = "definition", label = "Definition" },
            { key = "synonyms",   label = "Synonyms" },
            { key = "text",       label = "Broader Context" },
        }
    end
    return list
end

function CardFields.use_rich_viewer(card, config)
    card = CardFields.normalize(card, config)
    if NoteTypeProfiles.is_vocabulary_card(card.model) then
        local names = {}
        for k in pairs(card.anki_fields or {}) do table.insert(names, k) end
        if #names == 0 then return true end
        return NoteTypeProfiles.vocabulary_field_set(names)
    end
    if not NoteTypeProfiles.is_wiki_card(card.model) then return false end
    local names = {}
    for k in pairs(card.anki_fields or {}) do table.insert(names, k) end
    if #names == 0 then return true end
    return NoteTypeProfiles.information_field_set(names)
end

function CardFields.is_dictionary_card(card, config)
    card = CardFields.normalize(card, config)
    return NoteTypeProfiles.is_vocabulary_card(card.model)
        or card.dictionary_only == true
end

return CardFields
