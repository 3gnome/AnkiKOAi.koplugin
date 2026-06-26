-- Look up a word using KOReader's installed StarDict dictionaries (no AI).

local Menu     = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local _        = require("gettext")

local Nav = require("nav")

local DictionaryLookup = {}

local MAX_DEFINITION = 4000
local PREVIEW_LEN    = 72

local function strip_html(html, keep_newlines)
    if not html or html == "" then return "" end
    local text = html
    if keep_newlines then
        text = text:gsub("<%s*[bB][rR]%s*/?>", "\n")
        -- Closing block-level tags become line breaks so paragraphs, list items
        -- and headings separate instead of running together.
        text = text:gsub("</%s*[pP]%s*>", "\n")
        text = text:gsub("</%s*[dD][iI][vV]%s*>", "\n")
        text = text:gsub("</%s*[lL][iI]%s*>", "\n")
        text = text:gsub("</%s*[tT][rR]%s*>", "\n")
        text = text:gsub("</%s*[hH][1-6]%s*>", "\n")
        text = text:gsub("</%s*[dD][dDtT]%s*>", "\n")
    else
        text = text:gsub("<br%s*/?>", " ")
    end
    -- Replace any remaining tag with a space (never an empty string) so inline
    -- elements like <b>Adverb</b>In… don't glue into "AdverbIn".
    text = text:gsub("<[^>]+>", " ")
    text = text:gsub("&nbsp;", " ")
    text = text:gsub("&amp;", "&")
    text = text:gsub("&lt;", "<")
    text = text:gsub("&gt;", ">")
    text = text:gsub("&quot;", '"')
    text = text:gsub("&#(%d+);", function(n)
        local num = tonumber(n)
        if num and num >= 32 and num <= 126 then
            return string.char(num)
        end
        return " "
    end)
    if keep_newlines then
        text = text:gsub("[ \t]+", " ")
        text = text:gsub("\n[ \t]+", "\n")
        text = text:gsub("[ \t]+\n", "\n")
        text = text:gsub("\n\n\n+", "\n\n")
        text = text:match("^%s*(.-)%s*$") or ""
    else
        text = text:gsub("[ \t\r\n]+", " "):match("^%s*(.-)%s*$") or ""
    end
    if #text > MAX_DEFINITION then
        text = text:sub(1, MAX_DEFINITION) .. "..."
    end
    return text
end

local function preview_text(definition)
    local s = (definition or ""):gsub("\n", " "):match("^%s*(.-)%s*$") or ""
    if #s > PREVIEW_LEN then
        return s:sub(1, PREVIEW_LEN) .. "..."
    end
    return s
end

local function reader_settings()
    if rawget(_G, "G_reader_settings") and G_reader_settings then
        return G_reader_settings
    end
    local ok, ls = pcall(require, "luasettings")
    if ok and ls and ls.open then
        local ok2, settings = pcall(function() return ls:open("reader.lua") end)
        if ok2 then return settings end
    end
    return nil
end

local function fuzzy_search_enabled(dict_module)
    if dict_module.disable_fuzzy_search ~= nil then
        return not dict_module.disable_fuzzy_search
    end
    if dict_module.disable_fuzzy_search_fm ~= nil then
        return not dict_module.disable_fuzzy_search_fm
    end
    local settings = reader_settings()
    if settings and settings.nilOrFalse then
        return settings:nilOrFalse("disable_fuzzy_search")
    end
    return false
end

local function same_word(a, b)
    a = (a or ""):lower()
    b = (b or ""):lower()
    return a == b
end

local function normalize_entry(raw, fallback_word)
    if not raw or raw.no_result then return nil end
    local definition = strip_html(raw.definition or "", true)
    if definition == "" then return nil end
    return {
        word       = raw.word or fallback_word,
        definition = definition,
        dict       = raw.dict or "",
        preview    = preview_text(definition),
    }
end

local function run_lookup(ui, word)
    word = (word or ""):match("^%s*(.-)%s*$") or ""
    if word == "" then
        return nil, _("No word to look up")
    end
    if not ui or not ui.dictionary or not ui.dictionary.startSdcv then
        return nil, _("Dictionary not available in KOReader")
    end

    local dict = ui.dictionary
    local dict_names = dict.enabled_dict_names or dict.preferred_dictionaries
    local fuzzy = fuzzy_search_enabled(dict)
    local results = dict:startSdcv(word, dict_names, fuzzy)

    if not results or #results == 0 then
        return nil, _("No dictionary results")
    end
    if results.lookup_cancelled then
        return nil, _("Dictionary lookup interrupted")
    end

    local entries = {}
    local seen = {}
    for _i, raw in ipairs(results) do
        local entry = normalize_entry(raw, word)
        if entry then
            local key = (entry.dict or "") .. "|" .. (entry.word or "")
                .. "|" .. entry.definition
            if not seen[key] then
                seen[key] = true
                table.insert(entries, entry)
            end
        end
    end

    if #entries == 0 then
        return nil, _("No dictionary entry found for this word")
    end
    return entries
end

function DictionaryLookup.lookup_all(ui, word)
    return run_lookup(ui, word)
end

function DictionaryLookup.lookup(ui, word)
    local entries, err = run_lookup(ui, word)
    if not entries then return nil, err end
    return entries[1]
end

-- Reuse the definition already shown in KOReader's DictQuickLookup popup.
-- Returns nil when preferred_dictionary is set but not among popup results
-- (caller should run a fresh StarDict lookup with the same settings).
function DictionaryLookup.lookup_from_popup(popup, opts)
    opts = opts or {}
    if not popup then return nil end

    local word = popup.displayword or popup.lookupword or popup.word
    word = (word or ""):match("^%s*(.-)%s*$") or ""
    if word == "" then return nil end

    local preferred = opts.preferred_dictionary
    local results = popup.results
    if type(results) ~= "table" or #results == 0 then
        if popup.definition and popup.definition ~= "" then
            local def = strip_html(tostring(popup.definition), true)
            if def ~= "" then
                return {
                    word       = word,
                    definition = def,
                    dict       = popup.dictionary or "",
                    preview    = preview_text(def),
                }
            end
        end
        return nil
    end

    local function entry_at(index)
        return normalize_entry(results[index], word)
    end

    if preferred and preferred ~= "" then
        for i = 1, #results do
            if results[i].dict == preferred then
                return entry_at(i)
            end
        end
        return nil
    end

    local idx = tonumber(popup.dict_index) or 1
    if idx < 1 or idx > #results then idx = 1 end
    return entry_at(idx)
end

function DictionaryLookup.show_picker(entries, lookup_word, on_select, opts)
    opts = opts or {}
    lookup_word = lookup_word or ""
    local menu_ref = {}
    local guard = { busy = false }
    local items = {}

    local function finish_cancel()
        if guard.busy then return end
        if opts.on_cancel then
            opts.on_cancel()
        elseif opts.parent_fn then
            opts.parent_fn()
        end
    end

    if opts.parent_fn then
        Nav.prepend_back(items, nil, menu_ref, _("← Back"))
    end

    table.insert(items, {
        text           = _("Tap a dictionary entry to use its definition:"),
        select_enabled = false,
    })

    for _i, entry in ipairs(entries or {}) do
        local dict_label = (entry.dict and entry.dict ~= "") and entry.dict or _("Dictionary")
        local title = dict_label
        if entry.word and not same_word(entry.word, lookup_word) then
            title = title .. " · " .. entry.word
        end

        local function choose()
            guard.busy = true
            if menu_ref[1] then UIManager:close(menu_ref[1]) end
            menu_ref[1] = nil
            guard.busy = false
            if on_select then on_select(entry) end
        end

        table.insert(items, {
            text     = title,
            bold     = true,
            callback = choose,
        })
        if entry.preview and entry.preview ~= "" then
            table.insert(items, {
                text     = entry.preview,
                dim      = true,
                callback = choose,
            })
        end
    end

    menu_ref[1] = Nav.wrap_menu(Menu:new(Nav.apply_compact_menu {
        title      = _("Choose definition"),
        item_table = items,
    }), finish_cancel)
    Nav.show(menu_ref[1])
end

-- Look up word; if multiple dictionary hits, let the user pick one.
-- opts.preferred_dictionary — prefer entries from this StarDict name
-- opts.auto_pick — when true, use preferred/first entry without showing the menu
function DictionaryLookup.pick(ui, word, on_select, opts)
    opts = opts or {}
    local entries, err = run_lookup(ui, word)
    if not entries then
        return nil, err
    end

    local preferred = opts.preferred_dictionary
    if preferred and preferred ~= "" then
        local filtered = {}
        for _i, entry in ipairs(entries) do
            if entry.dict == preferred then
                table.insert(filtered, entry)
            end
        end
        if #filtered > 0 then
            entries = filtered
        end
    end

    if #entries == 1 and not opts.always_pick and not opts.auto_pick then
        if on_select then on_select(entries[1]) end
        return entries[1]
    end

    if opts.auto_pick and #entries > 0 then
        local no_preferred = not preferred or preferred == ""
        if not (no_preferred and #entries > 1) then
            if on_select then on_select(entries[1]) end
            return entries[1]
        end
    end

    DictionaryLookup.show_picker(entries, word, on_select, opts)
    return true
end

return DictionaryLookup
