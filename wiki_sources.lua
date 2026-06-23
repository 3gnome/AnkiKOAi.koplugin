-- Fetch reference excerpts from Wikimedia projects (Wikipedia, Wiktionary).
-- Used to ground AI card generation in real encyclopedic / dictionary text.

local https  = require("ssl.https")
local ltn12  = require("ltn12")
local json   = require("json")
local socket = require("socket")
local _      = require("gettext")

local TIMEOUT = 8
-- Overall wall-clock budget for one WikiSources.fetch (a single card can fan
-- out into ~10 serial HTTPS requests). Bounds the worst-case UI freeze.
local TOTAL_BUDGET = 25
https.TIMEOUT = TIMEOUT

local WikiSources = {}

-- Absolute socket.gettime() cutoff for the in-progress fetch (nil = no limit).
local g_deadline = nil

local function time_left()
    return g_deadline == nil or socket.gettime() < g_deadline
end

local LANG_CODES = {
    english    = "en", spanish = "es", french = "fr", german = "de",
    italian    = "it", portuguese = "pt", chinese = "zh", japanese = "ja",
    korean     = "ko", russian = "ru", arabic = "ar", dutch = "nl",
    swedish    = "sv", turkish = "tr", polish = "pl",
}

local function wiki_lang(config)
    local lang = (config and config.target_language or "English"):lower()
    return LANG_CODES[lang] or "en"
end

function WikiSources.is_enabled(config)
    return config and config.use_wiki_sources ~= false
end

local function trim(s)
    if not s then return "" end
    return s:match("^%s*(.-)%s*$") or ""
end

-- Percent-encode for URL paths (spaces → underscores for wiki titles).
local function encode_title(title)
    local encoded = title:gsub(" ", "_")
    encoded = encoded:gsub("([^%w%-%.~_])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return encoded
end

local function https_get(url)
    local timeout = TIMEOUT
    if g_deadline then
        local remaining = g_deadline - socket.gettime()
        if remaining <= 0 then return nil end
        if remaining < timeout then timeout = remaining end
    end
    local body = {}
    https.TIMEOUT = timeout
    local ok, code = https.request {
        url  = url,
        sink = ltn12.sink.table(body),
    }
    if not ok or tonumber(code) ~= 200 then return nil end
    return table.concat(body)
end

local function parse_summary_json(raw)
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= "table" then return nil end
    if data.type == "disambiguation" then return nil end
    local extract = trim(data.extract)
    if extract == "" then return nil end
    local page_url
    if data.content_urls and data.content_urls.desktop then
        page_url = data.content_urls.desktop.page
    end
    return {
        title   = data.title or "",
        extract = extract,
        url     = page_url or "",
    }
end

-- Wikipedia REST summary for a title, or nil.
local function fetch_summary(site, lang, title)
    local enc = encode_title(title)
    local url = "https://" .. lang .. "." .. site
              .. ".org/api/rest_v1/page/summary/" .. enc
    local raw = https_get(url)
    if not raw then return nil end
    return parse_summary_json(raw)
end

-- Wikipedia opensearch → first article title + summary.
local function wikipedia_search_on(wiki_lang_code, query)
    local q = query:gsub(" ", "+"):gsub("([^%w%-%.~_%+])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    local url = "https://" .. wiki_lang_code .. ".wikipedia.org/w/api.php"
              .. "?action=opensearch&search=" .. q
              .. "&limit=3&namespace=0&format=json"
    local raw = https_get(url)
    if not raw then return nil end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= "table" or type(data[2]) ~= "table" then return nil end
    for _, t in ipairs(data[2]) do
        local hit = fetch_summary("wikipedia", wiki_lang_code, t)
        if hit then return hit end
    end
    return nil
end

local function wikipedia_search(lang, query)
    return wikipedia_search_on(lang, query)
end

local function fetch_wikidata(lang, phrase)
    local q = trim(phrase):gsub(" ", "+"):gsub("([^%w%-%.~_%+])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    local url = "https://www.wikidata.org/w/api.php?action=wbsearchentities&search="
              .. q .. "&language=" .. lang .. "&limit=1&format=json"
    local raw = https_get(url)
    if not raw then return nil end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data.search) ~= "table" or not data.search[1] then return nil end
    local hit = data.search[1]
    local desc = trim(hit.description or "")
    if desc == "" then return nil end
    local entity_url = "https://www.wikidata.org/wiki/" .. (hit.id or "")
    return {
        title   = hit.label or phrase,
        extract = desc,
        url     = entity_url,
    }
end

local function normalize_title(s)
    return (s or ""):lower():gsub("[%s_%-]+", "")
end

local function title_matches_query(title, query)
    local t = normalize_title(title)
    local q = normalize_title(query)
    if t == "" or q == "" then return false end
    if t == q then return true end
    -- Allow plural/s singular: antipathies vs antipathy
    if #q >= 4 and (t:find(q, 1, true) or q:find(t, 1, true)) then
        return math.abs(#t - #q) <= 2
    end
    return false
end

local function wiki_page_url(lang, title)
    return "https://" .. lang .. ".wikipedia.org/wiki/" .. encode_title(title)
end

local SKIP_LINK_PREFIXES = {
    "List of ", "Lists of ", "Index of ", "Outline of ",
    "Wikipedia:", "Help:", "Category:", "File:", "Template:", "Portal:",
    "Draft:", "Special:", "Talk:",
}

local function link_title_ok(title)
    title = trim(title)
    if title == "" or #title < 3 then return false end
    for _, prefix in ipairs(SKIP_LINK_PREFIXES) do
        if title:sub(1, #prefix) == prefix then return false end
    end
    if title:match("^%d%d%d%d$") then return false end
    return true
end

-- Outbound Wikipedia links from a matched article (for "explore further").
local function fetch_wikipedia_links(lang, title, limit)
    limit = limit or 20
    title = trim(title)
    if title == "" then return {} end
    local url = "https://" .. lang .. ".wikipedia.org/w/api.php"
        .. "?action=query&format=json&prop=links&plnamespace=0&pllimit="
        .. tostring(limit) .. "&titles=" .. encode_title(title)
    local raw = https_get(url)
    if not raw then return {} end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= "table" or type(data.query) ~= "table" then return {} end
    local pages = data.query.pages
    if type(pages) ~= "table" then return {} end
    local links = {}
    local seen = {}
    for _pid, page in pairs(pages) do
        if type(page.links) == "table" then
            for _, item in ipairs(page.links) do
                local t = item and item.title
                if t and link_title_ok(t) and not seen[t] then
                    seen[t] = true
                    table.insert(links, {
                        title = t,
                        url   = wiki_page_url(lang, t),
                    })
                end
            end
        end
    end
    table.sort(links, function(a, b) return a.title < b.title end)
    return links
end

local function query_is_long(query)
    query = trim(query)
    return #query > 48 or query:find("\n") ~= nil
end

local function fetch_wikipedia(lang, phrase)
    local query = trim(phrase)
    if query == "" then return nil end
    local hit = fetch_summary("wikipedia", lang, query)
    if hit and title_matches_query(hit.title, query) then return hit end
    hit = wikipedia_search(lang, query)
    if hit then
        if title_matches_query(hit.title, query) then return hit end
        -- Long/multi-line highlights: trust opensearch's top article match.
        if query_is_long(query) then return hit end
    end
    return nil
end

local function add_unique_query(list, seen, q)
    q = trim(q)
    if q == "" or #q < 3 then return end
    local key = q:lower()
    if seen[key] then return end
    seen[key] = true
    table.insert(list, q)
end

-- Search phrases for long highlights, book titles, and authors.
local function search_queries(phrase, opts)
    opts = opts or {}
    local queries, seen = {}, {}
    add_unique_query(queries, seen, phrase)
    local first_line = phrase:match("^([^\n]+)") or phrase
    add_unique_query(queries, seen, first_line:sub(1, 120))
    local words = {}
    for w in first_line:gmatch("[%w']+") do
        table.insert(words, w)
        if #words >= 8 then break end
    end
    if #words >= 3 then
        add_unique_query(queries, seen, table.concat(words, " "))
    end
    if #words >= 2 then
        add_unique_query(queries, seen, table.concat({ words[1], words[2], words[3] }, " "))
    end
    if opts.title and opts.title ~= "" then
        add_unique_query(queries, seen, opts.title)
    end
    if opts.author and opts.author ~= "" then
        add_unique_query(queries, seen, opts.author)
        local lead = opts.author:match("^([^,]+)")
        if lead then add_unique_query(queries, seen, lead) end
    end
    while #queries > 5 do
        table.remove(queries)
    end
    return queries
end

local function merge_related_links(dest, lang, title, limit)
    dest = dest or {}
    limit = limit or 24
    local seen = {}
    for _, item in ipairs(dest) do
        if item.url then seen[item.url] = true end
    end
    for _, link in ipairs(fetch_wikipedia_links(lang, title, limit)) do
        if not seen[link.url] then
            seen[link.url] = true
            table.insert(dest, link)
        end
    end
    return dest
end

local function fetch_wiktionary(lang, term)
    local query = trim(term)
    if query == "" then return nil end
    local hit = fetch_summary("wiktionary", lang, query)
    if hit then return hit end
    -- Wiktionary search via opensearch.
    local q = query:gsub(" ", "+"):gsub("([^%w%-%.~_%+])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    local url = "https://" .. lang .. ".wiktionary.org/w/api.php"
              .. "?action=opensearch&search=" .. q
              .. "&limit=2&format=json"
    local raw = https_get(url)
    if not raw then return nil end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= "table" or type(data[2]) ~= "table" then
        return nil
    end
    for _, t in ipairs(data[2]) do
        local wt = fetch_summary("wiktionary", lang, t)
        if wt then return wt end
    end
    return nil
end

-- Core fetch logic; runs under the g_deadline budget set by WikiSources.fetch.
local function do_fetch(config, phrase, opts)
    local lang = wiki_lang(config)
    local result = { explore_pages = {}, related_links = {} }
    local seen_page_urls = {}
    local UiBusy = require("ui_busy")

    local function remember_page(page)
        if not page or not page.url or page.url == "" then return end
        if seen_page_urls[page.url] then return end
        seen_page_urls[page.url] = true
        table.insert(result.explore_pages, {
            title = page.title or "Wikipedia",
            url   = page.url,
        })
    end

    -- Prefer dictionary sources for single-word highlights.
    local wt = fetch_wiktionary(lang, phrase)
    if not wt and time_left() and phrase:find("%s") then
        wt = fetch_wiktionary(lang, phrase:match("^(%S+)"))
    end
    if wt then result.wiktionary = wt end

    local queries = search_queries(phrase, opts)
    for qi, query in ipairs(queries) do
        if not time_left() then break end
        UiBusy.pulse(_("Looking up Wikipedia…") .. " (" .. qi .. "/" .. #queries .. ")")
        local wp = fetch_wikipedia(lang, query)
        if wp then
            if not result.wikipedia then
                result.wikipedia = wp
            end
            remember_page(wp)
            if time_left() then
                result.related_links = merge_related_links(result.related_links, lang, wp.title, 20)
            end
        end
    end

    if lang == "en" and not result.wikipedia and time_left() then
        for _, query in ipairs(search_queries(phrase, opts)) do
            if not time_left() then break end
            local simple = fetch_summary("wikipedia", "simple", query)
            if not simple and time_left() then
                simple = wikipedia_search_on("simple", query)
            end
            if simple and (title_matches_query(simple.title, query) or query_is_long(query)) then
                result.simple_wikipedia = simple
                remember_page(simple)
                break
            end
        end
    end

    if time_left() then
        local wq = fetch_summary("wikiquote", lang, phrase)
        if not wq and lang == "en" and time_left() then
            wq = fetch_summary("wikiquote", "en", phrase:match("^(%S+)") or phrase)
        end
        if wq and (title_matches_query(wq.title, phrase) or query_is_long(phrase)) then
            result.wikiquote = wq
            remember_page(wq)
        end
    end

    if time_left() then
        local wd = fetch_wikidata(lang, phrase)
        if wd and (title_matches_query(wd.title, phrase) or query_is_long(phrase)) then
            result.wikidata = wd
            remember_page(wd)
        end
    end

    return result
end

-- Fetch Wikipedia + Wiktionary excerpts for a highlight.
-- opts may include title and author (book metadata) for better discovery on long highlights.
function WikiSources.fetch(config, phrase, opts)
    if not WikiSources.is_enabled(config) then return {} end
    opts = opts or {}
    local budget = tonumber(config and config.wiki_time_budget) or TOTAL_BUDGET
    g_deadline = socket.gettime() + budget
    -- pcall so the deadline is always cleared, even if a request errors.
    local ok, result = pcall(do_fetch, config, phrase, opts)
    g_deadline = nil
    if ok and type(result) == "table" then return result end
    return {}
end

function WikiSources.has_content(sources)
    if not sources then return false end
    return sources.wikipedia or sources.simple_wikipedia or sources.wiktionary
        or sources.wikiquote or sources.wikidata
        or (sources.explore_pages and #sources.explore_pages > 0)
end

-- Trim excerpt for prompt size (e-ink / token limits).
local function clip(s, max_len)
    s = trim(s)
    if #s <= max_len then return s end
    return s:sub(1, max_len - 3) .. "..."
end

-- Format fetched excerpts for injection into an LLM prompt.
function WikiSources.format_for_prompt(sources)
    if not WikiSources.has_content(sources) then return "" end
    local parts = {
        "Reference excerpts from Wikimedia (use as primary factual sources; synthesize but do not contradict them):",
    }
    if sources.wikipedia then
        table.insert(parts, '[Wikipedia: "' .. (sources.wikipedia.title or "") .. '"]')
        table.insert(parts, clip(sources.wikipedia.extract, 900))
        if sources.wikipedia.url ~= "" then table.insert(parts, "URL: " .. sources.wikipedia.url) end
        if sources.related_links and #sources.related_links > 0 then
            table.insert(parts, "Related Wikipedia articles (for context only; URLs are added by the plugin):")
            for i = 1, math.min(8, #sources.related_links) do
                local link = sources.related_links[i]
                table.insert(parts, "  - " .. (link.title or "") .. " — " .. (link.url or ""))
            end
        end
    end
    if sources.simple_wikipedia then
        table.insert(parts, '[Simple English Wikipedia: "' .. (sources.simple_wikipedia.title or "") .. '"]')
        table.insert(parts, clip(sources.simple_wikipedia.extract, 600))
    end
    if sources.wiktionary then
        table.insert(parts, '[Wiktionary: "' .. (sources.wiktionary.title or "") .. '"]')
        table.insert(parts, clip(sources.wiktionary.extract, 600))
        if sources.wiktionary.url ~= "" then table.insert(parts, "URL: " .. sources.wiktionary.url) end
    end
    if sources.wikidata then
        table.insert(parts, '[Wikidata: "' .. (sources.wikidata.title or "") .. '"]')
        table.insert(parts, clip(sources.wikidata.extract, 400))
        if sources.wikidata.url ~= "" then table.insert(parts, "URL: " .. sources.wikidata.url) end
    end
    if sources.wikiquote then
        table.insert(parts, '[Wikiquote: "' .. (sources.wikiquote.title or "") .. '"]')
        table.insert(parts, clip(sources.wikiquote.extract, 400))
    end
    return table.concat(parts, "\n")
end

function WikiSources.primary_url(sources)
    if sources and sources.wikipedia and sources.wikipedia.url ~= "" then
        return sources.wikipedia.url
    end
    if sources and sources.simple_wikipedia and sources.simple_wikipedia.url ~= "" then
        return sources.simple_wikipedia.url
    end
    if sources and sources.wikidata and sources.wikidata.url ~= "" then
        return sources.wikidata.url
    end
    if sources and sources.wiktionary and sources.wiktionary.url ~= "" then
        return sources.wiktionary.url
    end
    return nil
end

local function collect_link_items(sources, limit)
    limit = limit or 10
    local items = {}
    local seen_url = {}
    local function add(item)
        if not item or not item.url or item.url == "" or seen_url[item.url] then return end
        seen_url[item.url] = true
        table.insert(items, item)
    end
    local source_list = {
        sources and sources.wikipedia,
        sources and sources.simple_wikipedia,
        sources and sources.wiktionary,
        sources and sources.wikidata,
        sources and sources.wikiquote,
    }
    for _, src in ipairs(source_list) do
        if src and src.url and src.url ~= "" then
            add({
                title   = src.title or "Wikipedia",
                url     = src.url,
                primary = (src == sources.wikipedia),
            })
        end
    end
    for _, page in ipairs((sources and sources.explore_pages) or {}) do
        if #items >= limit then break end
        add(page)
    end
    for _, link in ipairs((sources and sources.related_links) or {}) do
        if #items >= limit then break end
        add(link)
    end
    return items
end

-- HTML list of real Wikipedia URLs for the Anki Links field.
function WikiSources.format_links_html(sources, limit)
    local items = collect_link_items(sources, limit)
    if #items == 0 then return "" end
    local lines = {}
    for _, item in ipairs(items) do
        local label = item.title or item.url
        label = label:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        local url = item.url:gsub('"', "&quot;")
        table.insert(lines, string.format(
            '<a href="%s">%s</a>', url, label))
    end
    return table.concat(lines, "<br>\n")
end

-- Plain-text links for in-app preview.
function WikiSources.format_links_plain(sources, limit)
    local items = collect_link_items(sources, limit)
    if #items == 0 then return "" end
    local lines = {}
    for _, item in ipairs(items) do
        table.insert(lines, (item.title or "Link") .. " — " .. item.url)
    end
    return table.concat(lines, "\n")
end

-- Fill Links on a card when the Anki note type has that field; else append to Text.
function WikiSources.apply_links_to_card(card, sources, field_names)
    if not card then return end
    sources = sources or {}
    local html = WikiSources.format_links_html(sources)
    if html == "" then return end
    card.anki_fields = card.anki_fields or {}
    local has_links_field = false
    for _, fname in ipairs(field_names or {}) do
        if fname:lower() == "links" then
            has_links_field = true
            break
        end
    end
    if has_links_field then
        card.anki_fields.Links = html
        card.links = html
    else
        local plain = WikiSources.format_links_plain(sources)
        local article = card.anki_fields.Text or card.text or ""
        if plain ~= "" and not article:find("Explore further:", 1, true) then
            local block = "\n\nExplore further:\n" .. plain
            card.anki_fields.Text = article .. block
            card.text = card.anki_fields.Text
        end
    end
end

return WikiSources
