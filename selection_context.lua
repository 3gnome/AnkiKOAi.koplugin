local Device = require("device")
local Screen = Device.screen

local function selection_to_text(sel)
  if type(sel) == "string" then return sel end
  if type(sel) ~= "table" then return tostring(sel) end

  -- Some backends give { text="...", ... }
  if sel.text then return sel.text end

  local out = {}

  local function collect(t)
    for _, v in ipairs(t) do
      if type(v) == "string" then
        table.insert(out, v)
      elseif type(v) == "table" then
        -- common field names you’ll see
        if v.text then table.insert(out, v.text) end
        if v.t    then table.insert(out, v.t)    end
        if v.s    then table.insert(out, v.s)    end
        if v.str  then table.insert(out, v.str)  end
        if v.value then table.insert(out, v.value) end
        -- nested containers
        if v.spans    then collect(v.spans)    end
        if v.segments then collect(v.segments) end
        if v.lines    then collect(v.lines)    end
      end
    end
  end

  collect(sel)
  return table.concat(out, "")
end

local function get_page_text(document)
  local ok, result = pcall(function()
    return selection_to_text(document:getTextFromPositions(
      {x = 0, y = 0},
      {x = Screen:getWidth(), y = Screen:getHeight()},
      true))
  end)
  if ok and result then return result end
  return ""
end

local function get_selection_in_context(document, selection, window)
    window = window or 10
    local page_text = get_page_text(document)
    if not page_text or not selection or selection == "" then
        return ""
    end

    -- Escape Lua pattern chars in selection
    local function escape_lua_pattern(s)
        return (s:gsub("([%%%^%$%(%)%[%]%.%*%+%-%?])", "%%%1"))
    end

    local safe = escape_lua_pattern(selection)

    -- Find the exact selection (first occurrence)
    local s_pos, e_pos = page_text:find(safe)
    if not s_pos then
        -- Fallback if not found
        return '"' .. selection .. '"'
    end

    local before_text = page_text:sub(1, s_pos - 1)
    local after_text  = page_text:sub(e_pos + 1)

    -- Collect up to N tokens from the end of before_text
    local before_tokens = {}
    for tok in before_text:gmatch("%S+") do
        before_tokens[#before_tokens + 1] = tok
    end
    local before_start = math.max(1, #before_tokens - window + 1)
    local before = table.concat(before_tokens, " ", before_start, #before_tokens)

    -- Collect up to N tokens from the start of after_text
    local after_tokens, count = {}, 0
    for tok in after_text:gmatch("%S+") do
        after_tokens[#after_tokens + 1] = tok
        count = count + 1
        if count >= window then break end
    end
    local after = table.concat(after_tokens, " ")

    -- Build output with no extra spaces if before/after are empty
    local left  = (before ~= "" and (before .. "") or "")
    local right = (after  ~= "" and ("" .. after)  or "")

    return left .. ' {{{ ' .. selection .. ' }}} ' .. right
end

local function escape_lua_pattern(s)
    return (s:gsub("([%%%^%$%(%)%[%]%.%*%+%-%?])", "%%%1"))
end

local function mark_selection(text, selection)
    local s, e = text:find(escape_lua_pattern(selection))
    if not s then return text end
    return text:sub(1, s - 1) .. "{{{ " .. selection .. " }}}" .. text:sub(e + 1)
end

-- A token ends a sentence if it finishes with . ! ? … (allowing trailing
-- quotes/brackets), so we can align passage boundaries to whole sentences.
local function ends_sentence(token)
    return token:match("[%.%!%?…][\"'%)%]»”]*$") ~= nil
end

-- Best-effort capture of the full paragraph containing the selection.
-- 1) If the page text exposes blank-line paragraph breaks, return that block.
-- 2) Otherwise, return a wide window aligned to whole sentences (so the passage
--    reads as complete sentences rather than being cut at a fixed word count).
-- Bounded to the visible page; a paragraph continuing past the page edge is
-- captured only up to what is on screen.
local function get_paragraph_in_context(document, selection, max_words)
    max_words = max_words or 90
    local raw = get_page_text(document)
    if not raw or not selection or selection == "" then
        return ""
    end
    raw = raw:gsub("\r\n", "\n"):gsub("\r", "\n")

    -- 1) Blank-line separated paragraphs: a strong, reliable signal when present.
    if raw:find("\n%s*\n") then
        local s_pos, e_pos = raw:find(escape_lua_pattern(selection))
        if s_pos then
            local start_p, search = 1, 1
            while true do
                local bs, be = raw:find("\n%s*\n", search)
                if not bs or bs >= s_pos then break end
                start_p = be + 1
                search  = be + 1
            end
            local end_p = #raw
            local bs2 = raw:find("\n%s*\n", e_pos)
            if bs2 then end_p = bs2 - 1 end
            local para = raw:sub(start_p, end_p):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
            if #para >= #selection + 16 then
                return mark_selection(para, selection)
            end
        end
    end

    -- 2) Sentence-aligned window on whitespace-collapsed text.
    local text = raw:gsub("%s+", " ")
    local s_pos, e_pos = text:find(escape_lua_pattern(selection))
    if not s_pos then
        return '"' .. selection .. '"'
    end

    local before_tokens = {}
    for tok in text:sub(1, s_pos - 1):gmatch("%S+") do
        before_tokens[#before_tokens + 1] = tok
    end
    local bstart = math.max(1, #before_tokens - max_words + 1)
    -- Start at the beginning of a sentence: skip past the first sentence end
    -- found inside the window so we don't open mid-sentence.
    for k = bstart, #before_tokens - 1 do
        if ends_sentence(before_tokens[k]) then bstart = k + 1 break end
    end
    local left = table.concat(before_tokens, " ", bstart, #before_tokens)

    local after_tokens = {}
    for tok in text:sub(e_pos + 1):gmatch("%S+") do
        after_tokens[#after_tokens + 1] = tok
    end
    local aend = math.min(#after_tokens, max_words)
    -- End on a completed sentence: prefer the last sentence end inside the
    -- window; if none, extend a little to finish the current sentence.
    local trimmed
    for k = aend, 1, -1 do
        if ends_sentence(after_tokens[k]) then trimmed = k break end
    end
    if trimmed then
        aend = trimmed
    else
        for k = aend + 1, math.min(#after_tokens, max_words + 40) do
            if ends_sentence(after_tokens[k]) then aend = k break end
        end
    end
    local right = table.concat(after_tokens, " ", 1, aend)

    return (left ~= "" and (left .. " ") or "")
        .. "{{{ " .. selection .. " }}}"
        .. (right ~= "" and (" " .. right) or "")
end

local M = {
    window    = get_selection_in_context,
    paragraph = get_paragraph_in_context,
}

-- Backward-compatible: existing callers invoke the module as a function
-- (window mode). New callers can use M.paragraph(...).
return setmetatable(M, {
    __call = function(_, document, selection, window)
        return get_selection_in_context(document, selection, window)
    end,
})