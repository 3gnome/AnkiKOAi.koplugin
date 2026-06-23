-- AI flashcard generator with dynamic Anki note type fields.

local https  = require("ssl.https")
local socket = require("socket")
local ltn12  = require("ltn12")
local json   = require("json")
local _      = require("gettext")

local TIMEOUT = 20
https.TIMEOUT = TIMEOUT

-- Transient failures worth retrying: rate limits (429), and upstream/server
-- overload or gateway errors. Providers like Gemini return 503 "UNAVAILABLE"
-- during demand spikes; these usually clear within a few seconds.
local MAX_LLM_ATTEMPTS = 3
local RETRYABLE_HTTP = {
    ["429"] = true, ["500"] = true, ["502"] = true,
    ["503"] = true, ["504"] = true, ["529"] = true,
}

local CardFields         = require("card_fields")
local NoteTypePicker     = require("note_type_picker")
local NoteTypeProfiles   = require("note_type_profiles")
local PromptBuilder      = require("prompt_builder")
local UiBusy             = require("ui_busy")
local WikiSources        = require("wiki_sources")

local CardGenerator = {}

local GEMINI_BASE_URL =
    "https://generativelanguage.googleapis.com/v1beta/models/"

local function call_llm_once(config, prompt)
    local provider = config.text_provider or "dashscope"
    local response_body = {}

    if provider == "gemini" then
        local api_key = config.gemini_api_key
        if not api_key or api_key == "" then
            return nil, "Gemini API key not configured"
        end
        local model = config.gemini_text_model or "gemini-2.5-flash"
        local url = GEMINI_BASE_URL .. model .. ":generateContent?key=" .. api_key
        local body = json.encode({
            contents = {{ parts = {{ text = prompt }} }},
        })
        https.TIMEOUT = TIMEOUT
        local ok_http, code = https.request {
            url     = url,
            method  = "POST",
            headers = {
                ["Content-Type"]  = "application/json",
                ["Content-Length"] = tostring(#body),
            },
            source = ltn12.source.string(body),
            sink   = ltn12.sink.table(response_body),
        }
        if tostring(code) ~= "200" then
            return nil, "HTTP " .. tostring(code) .. ": " .. table.concat(response_body):sub(1, 300)
        end
        local ok, data = pcall(json.decode, table.concat(response_body))
        if not ok or not data then return nil, "JSON decode error" end
        if data.candidates and data.candidates[1]
           and data.candidates[1].content and data.candidates[1].content.parts then
            for _i, part in ipairs(data.candidates[1].content.parts) do
                if part.text then return part.text end
            end
        end
        return nil, "No text in Gemini response"
    else
        local api_key, endpoint, model
        if provider == "openai" then
            api_key  = config.openai_api_key or ""
            endpoint = "https://api.openai.com/v1/chat/completions"
            model    = config.openai_model or "gpt-4o-mini"
        elseif provider == "openrouter" then
            api_key  = config.openrouter_api_key or ""
            endpoint = "https://openrouter.ai/api/v1/chat/completions"
            model    = config.openrouter_model or "anthropic/claude-3-haiku"
        else
            api_key  = config.dashscope_api_key or config.api_key or ""
            endpoint = config.provider or ""
            model    = config.llm_model or "qwen-plus"
        end
        if api_key == "" then return nil, "API key not configured" end
        if endpoint == "" then
            endpoint = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions"
        end
        local body = json.encode({
            model    = model,
            messages = {{ role = "user", content = prompt }},
        })
        https.TIMEOUT = TIMEOUT
        local ok_http, code = https.request {
            url     = endpoint,
            method  = "POST",
            headers = {
                ["Content-Type"]  = "application/json",
                ["Authorization"] = "Bearer " .. api_key,
                ["Content-Length"] = tostring(#body),
            },
            source = ltn12.source.string(body),
            sink   = ltn12.sink.table(response_body),
        }
        if tostring(code) ~= "200" then
            return nil, "HTTP " .. tostring(code) .. ": " .. table.concat(response_body):sub(1, 300)
        end
        local ok, decoded = pcall(json.decode, table.concat(response_body))
        if ok and decoded and decoded.choices and decoded.choices[1]
           and decoded.choices[1].message then
            return decoded.choices[1].message.content
        end
        return nil, "Unexpected API response format"
    end
end

local function is_retryable_error(err)
    if type(err) ~= "string" then return false end
    local code = err:match("^HTTP (%d+)")
    if code and RETRYABLE_HTTP[code] then return true end
    -- Network-level failures and provider overload messages surfaced as text.
    local lowered = err:lower()
    if lowered:find("timeout") or lowered:find("closed")
       or lowered:find("connection") or lowered:find("temporarily")
       or lowered:find("unavailable") or lowered:find("overloaded")
       or lowered:find("high demand") then
        return true
    end
    return false
end

-- Retry transient provider failures with exponential backoff (1s, 2s).
local function call_llm(config, prompt)
    local last_err
    for attempt = 1, MAX_LLM_ATTEMPTS do
        local text, err = call_llm_once(config, prompt)
        if text then return text end
        last_err = err
        if attempt >= MAX_LLM_ATTEMPTS or not is_retryable_error(err) then
            return nil, err
        end
        UiBusy.pulse(_("Provider busy — retrying…"))
        socket.sleep(2 ^ (attempt - 1))
    end
    return nil, last_err
end

local function escape_for_prompt(s)
    if not s then return "" end
    return s:gsub('"', '\\"')
end

local function parse_response(raw)
    if not raw then return nil, "empty response" end
    local s = raw:gsub("```json%s*", ""):gsub("```%s*", "")
    local block = s:match("(%b{})")
    if not block then return nil, "No JSON object found in response" end
    local ok, data = pcall(json.decode, block)
    if not ok then return nil, "JSON parse failed: " .. tostring(data) end
    if type(data) ~= "table" then return nil, "Decoded value is not a table" end
    return data
end

local function wiki_block(sources)
    local block = WikiSources.format_for_prompt(sources)
    if block ~= "" then return block .. "\n\n" end
    return ""
end

local function field_names_for_model(config, model_name)
    local names = NoteTypePicker.fetch_field_names(config, model_name)
    if names and #names > 0 then return names end
    if NoteTypeProfiles.is_information_card(model_name) then
        return NoteTypeProfiles.INFORMATION_FIELDS
    end
    if NoteTypeProfiles.is_basic(model_name) then
        return { "Front", "Back" }
    end
    return { "Front", "Back" }
end

function CardGenerator.generate(config, phrase, context, title, author, model_name)
    local eff = CardFields.effective_config(config)
    model_name = NoteTypeProfiles.normalize_model_name(
        model_name or CardFields.default_wiki_model(config))
    eff.model = model_name
    local field_names = field_names_for_model(eff, model_name)
    local fetch_opts = { title = title, author = author }
    UiBusy.pulse(_("Fetching reference sources…"))
    local sources = WikiSources.fetch(eff, phrase, fetch_opts)
    local has_wiki = WikiSources.has_content(sources)

    local prompt = PromptBuilder.build_generate(eff, model_name, field_names, {
        language  = eff.target_language or "English",
        title     = escape_for_prompt(title or "Unknown"),
        author    = escape_for_prompt(author or "Unknown"),
        phrase    = escape_for_prompt(phrase or ""),
        context   = escape_for_prompt(context or ""),
        wiki_block = wiki_block(sources),
        has_wiki  = has_wiki,
    })

    UiBusy.pulse(_("Generating article…"))
    local raw_text, err = call_llm(eff, prompt)
    if not raw_text then return nil, err end
    local llm_data, parse_err = parse_response(raw_text)
    if not llm_data then return nil, parse_err end

    local card = {
        phrase  = phrase,
        model   = model_name,
        _context = context,
    }
    CardFields.apply_llm_fields(card, field_names, llm_data)

    card._wiki_sources = sources
    if NoteTypeProfiles.is_wiki_card(model_name) and WikiSources.is_enabled(eff) then
        WikiSources.apply_links_to_card(card, sources, field_names)
    end

    return CardFields.normalize(card, config)
end

function CardGenerator.generate_text(config, phrase, card)
    card = CardFields.normalize(card or {}, config)
    local eff = CardFields.effective_config(config)
    local model_name = card.model or CardFields.default_wiki_model(config)
    local sources = card._wiki_sources
    if not WikiSources.has_content(sources) then
        sources = WikiSources.fetch(eff, phrase, {
            title  = card.book_title,
            author = card.book_author,
        })
        card._wiki_sources = sources
    end
    local has_wiki = WikiSources.has_content(sources)

    local prompt = PromptBuilder.build_text_regen(eff, model_name, {
        title      = escape_for_prompt(card.book_title or "Unknown"),
        author     = escape_for_prompt(card.book_author or "Unknown"),
        phrase     = escape_for_prompt(phrase or ""),
        context    = escape_for_prompt(card._context or ""),
        definition = escape_for_prompt(card.definition or ""),
        wiki_block = wiki_block(sources),
        has_wiki   = has_wiki,
    })

    local raw_text, err = call_llm(eff, prompt)
    if not raw_text then return nil, err end
    local data, parse_err = parse_response(raw_text)
    if not data then return nil, parse_err or "Unexpected API response" end

    local regen_key = data.Text and "Text" or data.text and "text"
    for k, v in pairs(data) do
        if type(v) == "string" and v ~= "" then
            if card.anki_fields then card.anki_fields[k] = v end
            if k:lower() == "text" then card.text = v end
            regen_key = k
        end
    end
    if regen_key then
        if NoteTypeProfiles.is_wiki_card(model_name) and WikiSources.is_enabled(eff) then
            WikiSources.apply_links_to_card(card, sources, field_names_for_model(eff, model_name))
        end
        CardFields.sync_flat_from_anki(card)
        return card.text or (card.anki_fields and card.anki_fields[regen_key]) or ""
    end
    return nil, "Unexpected API response"
end

function CardGenerator.generate_ipa(config, phrase)
    local lang = config.target_language or "English"
    local prompt = 'Return ONLY pronunciation notation for the '
                   .. lang .. ' phrase: "' .. (phrase or "")
                   .. '". Reply with just the notation or "Unclear" if unknown.'
    local raw_text, err = call_llm(config, prompt)
    if not raw_text then return nil, err end
    return raw_text:match("^%s*(.-)%s*$")
end

function CardGenerator.generate_quick_lookup(config, phrase)
    local lang = config.target_language or "English"
    local p = escape_for_prompt(phrase or "")
    local prompt = 'Quick lookup for "' .. p .. '". Language: ' .. lang .. '.\n'
                .. 'Return valid JSON: {"ipa": "<background if confident else empty>", '
                .. '"definition": "<one sentence or Unclear from context>"}\n'
                .. PromptBuilder.accuracy_block(config, false)
    local raw_text, err = call_llm(config, prompt)
    if not raw_text then return nil, err end
    local result, parse_err = parse_response(raw_text)
    if result and result.definition then
        result.ipa = result.ipa or ""
        return result
    end
    return nil, parse_err or "Unexpected API response"
end

return CardGenerator
