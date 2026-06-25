-- Build LLM prompts from note type profiles, custom overrides, and wiki sources.

local NoteTypeProfiles = require("note_type_profiles")
local WikiSources      = require("wiki_sources")

local PromptBuilder = {}

local ACCURACY_BASE = [[
Accuracy rules (mandatory):
- State only facts you are confident are correct. If uncertain, write "Unclear from context" for that field.
- Do not invent citations, quotes, dates, people, URLs, or sources.
- Prefer what the passage supports; add general knowledge only when widely accepted.]]

local ACCURACY_WIKI = [[
Accuracy rules (mandatory):
- Reference excerpts below are from Wikimedia. Treat them as primary factual sources.
- Synthesize but do not contradict excerpts or invent facts beyond excerpts and the passage.
- If an excerpt is a poor match, say so in the most relevant field.]]

local ACCURACY_STRICT = [[
Strict mode (mandatory):
- If not confident about ANY field, use exactly "Unclear from context" for that field.
- Never guess to seem informative. Shorter truthful content beats longer invented content.]]

function PromptBuilder.accuracy_block(config, has_wiki)
    local parts = { has_wiki and ACCURACY_WIKI or ACCURACY_BASE }
    if config and config.strict_accuracy then
        table.insert(parts, ACCURACY_STRICT)
    end
    return table.concat(parts, "\n")
end

function PromptBuilder.custom_suffix(config)
    local sfx = config and config.prompt_suffix
    if sfx and sfx ~= "" then
        return "Additional instructions from the reader:\n" .. sfx .. "\n"
    end
    return ""
end

function PromptBuilder.regen_key(model_name)
    model_name = NoteTypeProfiles.normalize_model_name(model_name)
    return model_name .. "::__regen_text__"
end

function PromptBuilder.migrate_model_prompt(custom_prompts, from_model, to_model)
    if type(custom_prompts) ~= "table" then return end
    from_model = NoteTypeProfiles.normalize_model_name(from_model or "")
    to_model = NoteTypeProfiles.normalize_model_name(to_model or "")
    if from_model == "" or to_model == "" or from_model == to_model then return end

    local function copy_if_missing(from_key, to_key)
        local txt = custom_prompts[from_key]
        if txt and txt ~= "" and (not custom_prompts[to_key] or custom_prompts[to_key] == "") then
            custom_prompts[to_key] = txt
        end
    end

    copy_if_missing(from_model, to_model)
    copy_if_missing(PromptBuilder.regen_key(from_model), PromptBuilder.regen_key(to_model))
end

function PromptBuilder.copy_custom_prompts(src)
    local out = {}
    if type(src) == "table" then
        for k, v in pairs(src) do
            if type(v) == "string" and v ~= "" then out[k] = v end
        end
    end
    return out
end

function PromptBuilder.custom_template(config, model_name)
    local prompts = config and config.custom_prompts
    if type(prompts) == "table" and prompts[model_name] and prompts[model_name] ~= "" then
        return prompts[model_name]
    end
    return nil
end

function PromptBuilder.base_template(model_name)
    local ptype = NoteTypeProfiles.profile_type(model_name)
    if ptype == "information" then
        return NoteTypeProfiles.INFORMATION_PROMPT
    elseif ptype == "basic" then
        return NoteTypeProfiles.BASIC_PROMPT
    end
    return NoteTypeProfiles.GENERIC_PROMPT
end

function PromptBuilder.build_generate(config, model_name, field_names, vars)
    model_name = NoteTypeProfiles.normalize_model_name(model_name)
    field_names = field_names or NoteTypeProfiles.INFORMATION_FIELDS

    local template = PromptBuilder.custom_template(config, model_name)
                     or PromptBuilder.base_template(model_name)

    vars.model_name   = model_name
    vars.json_schema  = NoteTypeProfiles.build_json_schema(field_names)
    vars.custom_suffix = PromptBuilder.custom_suffix(config)
    vars.accuracy_rules = PromptBuilder.accuracy_block(config, vars.has_wiki)

    local prompt = template
    for key, val in pairs(vars) do
        prompt = prompt:gsub("{" .. key .. "}", function() return val or "" end)
    end
    return prompt
end

function PromptBuilder.build_text_regen(config, model_name, vars)
    model_name = NoteTypeProfiles.normalize_model_name(model_name)
    local template = PromptBuilder.custom_template(config, model_name .. "::__regen_text__")
    if not template then
        if NoteTypeProfiles.is_information_card(model_name) then
            template = NoteTypeProfiles.TEXT_REGEN_INFORMATION
        else
            template = [[Regenerate the broadest context/notes field for note type "{model_name}".
Book: "{title}" by {author}
Term: "{phrase}"
Passage: "...{context}..."
Current fields context: "{definition}"

{wiki_block}{custom_suffix}
{accuracy_rules}

Return valid JSON with the single field you regenerated using its exact Anki field name.]]
        end
    end
    vars.model_name = model_name
    vars.custom_suffix = PromptBuilder.custom_suffix(config)
    vars.accuracy_rules = PromptBuilder.accuracy_block(config, vars.has_wiki)
    local prompt = template
    for key, val in pairs(vars) do
        prompt = prompt:gsub("{" .. key .. "}", function() return val or "" end)
    end
    return prompt
end

function PromptBuilder.sample_preview_vars(config)
    return {
        language   = (config and config.target_language) or "English",
        title      = "Example Book",
        author     = "Example Author",
        phrase     = "serendipity",
        highlight  = "a moment of serendipity",
        context    = "a moment of serendipity",
        definition = "a moment of serendipity",
        wiki_block = "",
        has_wiki   = false,
    }
end

function PromptBuilder.preview_field_names(model_name)
    model_name = NoteTypeProfiles.normalize_model_name(model_name)
    local ptype = NoteTypeProfiles.profile_type(model_name)
    if ptype == "information" then
        return NoteTypeProfiles.INFORMATION_FIELDS
    elseif ptype == "vocabulary" then
        return NoteTypeProfiles.VOCABULARY_CARD_FIELDS
    elseif ptype == "basic" then
        return { "Front", "Back" }
    end
    return { "Front", "Back" }
end

function PromptBuilder.preview_config(cfg, draft)
    return {
        prompt_suffix     = draft.prompt_suffix,
        custom_prompts    = draft.custom_prompts,
        target_language   = cfg.target_language,
        strict_accuracy   = cfg.strict_accuracy,
        use_wiki_sources  = cfg.use_wiki_sources,
    }
end

function PromptBuilder.preview_generate(cfg, draft, model_name)
    local preview_cfg = PromptBuilder.preview_config(cfg, draft)
    model_name = NoteTypeProfiles.normalize_model_name(model_name)
    return PromptBuilder.build_generate(
        preview_cfg, model_name,
        PromptBuilder.preview_field_names(model_name),
        PromptBuilder.sample_preview_vars(preview_cfg))
end

function PromptBuilder.preview_regen(cfg, draft, model_name)
    local preview_cfg = PromptBuilder.preview_config(cfg, draft)
    model_name = NoteTypeProfiles.normalize_model_name(model_name)
    return PromptBuilder.build_text_regen(
        preview_cfg, model_name,
        PromptBuilder.sample_preview_vars(preview_cfg))
end

return PromptBuilder
