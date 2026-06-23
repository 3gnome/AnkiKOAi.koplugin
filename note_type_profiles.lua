-- Note type profiles, default prompts, and field-name hints.

local NoteTypeProfiles = {}

NoteTypeProfiles.DEFAULT_MODEL = "Wiki Card"

-- Dictionary-only vocabulary cards (no AI).
NoteTypeProfiles.VOCABULARY_CARD_MODEL = "Vocabulary Card"

-- Verbatim memorization (LPCG-style line cards).
NoteTypeProfiles.MEMORIZATION_MODEL = "Memorization"
NoteTypeProfiles.POETRY_MODEL = NoteTypeProfiles.MEMORIZATION_MODEL

local function norm(s)
    return (s or ""):lower():match("^%s*(.-)%s*$") or ""
end

function NoteTypeProfiles.normalize_model_name(name)
    if not name or name == "" then return NoteTypeProfiles.DEFAULT_MODEL end
    return name
end

function NoteTypeProfiles.is_wiki_card(model)
    return norm(model) == norm(NoteTypeProfiles.DEFAULT_MODEL)
end

-- Backward-compatible alias.
NoteTypeProfiles.is_information_card = NoteTypeProfiles.is_wiki_card

function NoteTypeProfiles.is_vocabulary_card(model)
    return norm(model) == norm(NoteTypeProfiles.VOCABULARY_CARD_MODEL)
end

function NoteTypeProfiles.is_memorization(model)
    local n = norm(model)
    return n == norm(NoteTypeProfiles.MEMORIZATION_MODEL)
        or n == norm(NoteTypeProfiles.POETRY_MODEL)
end

function NoteTypeProfiles.is_basic(model)
    return norm(model) == "basic"
end

-- Wiki Card (AI) flows: exclude dictionary-only and memorization note types.
function NoteTypeProfiles.is_wiki_compatible(model)
    if not model or model == "" then return false end
    if NoteTypeProfiles.is_vocabulary_card(model) then return false end
    if NoteTypeProfiles.is_memorization(model) then return false end
    return true
end

-- Vocabulary (dictionary, no-AI) cards can target any note type except the
-- memorization type (which has its own LPCG-specific field layout). The
-- dictionary data is mapped onto the chosen type's fields by name heuristics.
function NoteTypeProfiles.is_vocabulary_compatible(model)
    if not model or model == "" then return false end
    if NoteTypeProfiles.is_memorization(model) then return false end
    return true
end

function NoteTypeProfiles.is_memorization_compatible(model)
    return NoteTypeProfiles.is_memorization(model)
end

function NoteTypeProfiles.profile_type(model)
    if NoteTypeProfiles.is_wiki_card(model) then return "information" end
    if NoteTypeProfiles.is_vocabulary_card(model) then return "vocabulary" end
    if NoteTypeProfiles.is_basic(model) then return "basic" end
    return "generic"
end

-- Standard Wiki Card field names (Anki note type).
NoteTypeProfiles.INFORMATION_FIELDS = {
    "Phrase", "Text", "Links", "Source", "Definition", "IPA", "Synonyms",
}
NoteTypeProfiles.WIKI_CARD_FIELDS = NoteTypeProfiles.INFORMATION_FIELDS

NoteTypeProfiles.VOCABULARY_CARD_FIELDS = {
    "Phrase", "Definition", "Context", "Source",
}

NoteTypeProfiles.MEMORIZATION_FIELDS = {
    "Title", "Context", "Target", "FullText", "Source", "LineIndex", "FullRecite",
}

function NoteTypeProfiles.information_field_set(field_names)
    if type(field_names) ~= "table" then return false end
    local need = {}
    for _, f in ipairs(NoteTypeProfiles.INFORMATION_FIELDS) do need[f] = true end
    local count = 0
    for _, f in ipairs(field_names) do
        if need[f] then count = count + 1 end
    end
    return count >= 4
end

function NoteTypeProfiles.vocabulary_field_set(field_names)
    if type(field_names) ~= "table" then return false end
    local need = {}
    for _, f in ipairs(NoteTypeProfiles.VOCABULARY_CARD_FIELDS) do need[f] = true end
    local count = 0
    for _, f in ipairs(field_names) do
        if need[f] then count = count + 1 end
    end
    return count >= 3
end

-- Guess how to fill an Anki field from its name (generic note types).
function NoteTypeProfiles.field_hint(field_name)
    local n = norm(field_name)
    if n == "front" or n == "question" or n == "prompt" then
        return "a clear question about the highlight, grounded in the passage"
    end
    if n == "back" or n == "answer" or n == "response" then
        return "a concise answer the reader should recall"
    end
    if n == "phrase" or n == "word" or n == "term" then
        return "the highlighted term exactly (shown alone on the card front)"
    end
    if n == "definition" or n == "meaning" then
        return "optional one-sentence lede; leave empty if the Text opening is enough"
    end
    if n == "ipa" or n == "pronunciation" then
        return "leave empty unless pronunciation is clearly relevant"
    end
    if n == "synonyms" or n == "related" then
        return "leave empty — related topics go in Links (added by the plugin)"
    end
    if n == "text" or n == "article" or n == "notes" or n == "extra" then
        return "Wikipedia-style article (150–250 words): meaning in this passage, then broader encyclopedic context; plain text paragraphs"
    end
    if n == "links" or n == "urls" or n == "relatedlinks" then
        return "leave empty — real Wikipedia URLs are added by the plugin"
    end
    if n == "context" then
        return "same as Text — encyclopedic article with passage context"
    end
    if n == "source" or n == "reference" then
        return "leave empty — filled by the plugin when possible"
    end
    return "appropriate content for field '" .. (field_name or "") .. "'"
end

function NoteTypeProfiles.build_json_schema(field_names)
    local lines = {}
    for _, fname in ipairs(field_names) do
        local hint = NoteTypeProfiles.field_hint(fname)
        table.insert(lines, string.format(
            '  "%s": "<%s>"', fname:gsub('"', '\\"'), hint))
    end
    return "{\n" .. table.concat(lines, ",\n") .. "\n}"
end

-- Bundled prompt bodies (without accuracy/wiki blocks).
NoteTypeProfiles.INFORMATION_PROMPT = [[You are writing the back of a Wiki Card for a term the reader highlighted while reading.

Book: "{title}" by {author}
Highlighted term: "{phrase}"
Language for your reply: {language}
Surrounding passage: "...{context}..."

{wiki_block}If the highlight is a multi-word phrase, treat the whole phrase as the unit of meaning.

Goal: a concise Wikipedia-style encyclopedia article the reader studies on the back of the card. The card front shows only the term.

Task:
1. Explain what "{phrase}" means in THIS passage, then in general.
2. Add encyclopedic background: subject area, history, connections to the book's themes.
3. Write in neutral, readable prose (short paragraphs). No bullet lists of URLs.

Field rules:
- "Phrase": the highlighted term in canonical form (matches the front).
- "Text": the full article (150–250 words). Plain text; separate paragraphs with a blank line.
- "Definition": optional one-sentence opening; leave empty if Text already opens well.
- "Links", "Source", "IPA", "Synonyms": leave empty — the plugin fills Links and Source.

{custom_suffix}
{accuracy_rules}

Return valid JSON only:
{json_schema}]]

NoteTypeProfiles.BASIC_PROMPT = [[Build a Basic flashcard from a book highlight.

Book: "{title}" by {author}
Highlight: "{phrase}"
Language: {language}
Passage: "...{context}..."

{wiki_block}Create a question on "Front" that tests understanding of the highlight in context.
Create a concise "Back" with the answer.

{custom_suffix}
{accuracy_rules}

Return valid JSON only:
{json_schema}]]

NoteTypeProfiles.GENERIC_PROMPT = [[Build an Anki flashcard for note type "{model_name}".

Book: "{title}" by {author}
Highlight: "{phrase}"
Language: {language}
Passage: "...{context}..."

{wiki_block}Fill each field below for this note type. Use the exact JSON keys shown.

{custom_suffix}
{accuracy_rules}

Return valid JSON only:
{json_schema}]]

NoteTypeProfiles.TEXT_REGEN_INFORMATION = [[Regenerate the "Text" field (Wikipedia-style article) for a Wiki Card.

Book: "{title}" by {author}
Term: "{phrase}"
Language: {language}
Passage: "...{context}..."
Current definition/lede: "{definition}"

{wiki_block}Write a fresh encyclopedia-style article (150–250 words): meaning in the passage, then broader context. Plain text paragraphs.

{custom_suffix}
{accuracy_rules}

Return valid JSON only: { "Text": "<article; 150–250 words>" }]]

return NoteTypeProfiles
