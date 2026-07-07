-- Discover books with highlights (ReadHistory + DocSettings) and load annotation lists.

local HighlightBooks = {}

local function basename(path)
    return (path or ""):gsub("^.*[/\\]", "")
end

function HighlightBooks.annotation_is_highlight(ann)
    return ann and ann.drawer and ann.text and ann.text ~= ""
end

function HighlightBooks.count_highlights(annotations)
    local n = 0
    for _, ann in ipairs(annotations or {}) do
        if HighlightBooks.annotation_is_highlight(ann) then
            n = n + 1
        end
    end
    return n
end

function HighlightBooks.read_sidecar_annotations(doc_path)
    if not doc_path or doc_path == "" then
        return {}
    end
    local DocSettings = require("docsettings")
    local ok, doc_settings = pcall(DocSettings.open, DocSettings, doc_path)
    if not ok or not doc_settings then
        return {}
    end
    return doc_settings:readSetting("annotations") or {}
end

function HighlightBooks.title_for_path(doc_path, fallback)
    fallback = fallback or basename(doc_path)
    local DocSettings = require("docsettings")
    local ok, doc_settings = pcall(DocSettings.open, DocSettings, doc_path)
    if ok and doc_settings then
        local props = doc_settings:readSetting("doc_props")
        if props and props.title and props.title ~= "" then
            return props.title
        end
    end
    return fallback
end

local function file_exists(path)
    local lfs = _G.lfs
    if not lfs then
        local ok, mod = pcall(require, "libs/libkoreader-lfs")
        if ok then
            lfs = mod
        end
    end
    return path and lfs and lfs.attributes(path, "mode") == "file"
end

function HighlightBooks.discover_books_with_highlights(current_doc_path, ui)
    local ReadHistory = require("readhistory")
    ReadHistory:reload(true)

    local seen = {}
    local books = {}

    local function highlight_count_for_path(path, is_current)
        if is_current and ui then
            return #HighlightBooks.load_highlights_for_book(path, ui)
        end
        return HighlightBooks.count_highlights(
            HighlightBooks.read_sidecar_annotations(path))
    end

    local function add_book(path, title_hint, is_current)
        if not path or seen[path] then
            return
        end
        if not is_current and not file_exists(path) then
            return
        end
        local count = highlight_count_for_path(path, is_current)
        if count == 0 then
            return
        end
        seen[path] = true
        books[#books + 1] = {
            path = path,
            title = HighlightBooks.title_for_path(path, title_hint or basename(path)),
            count = count,
            is_current = is_current == true,
        }
    end

    for _, entry in ipairs(ReadHistory.hist or {}) do
        if entry.select_enabled ~= false and entry.file then
            add_book(entry.file, entry.text, entry.file == current_doc_path)
        end
    end

    if current_doc_path and not seen[current_doc_path] then
        add_book(current_doc_path, basename(current_doc_path), true)
    end

    for i, book in ipairs(books) do
        book.is_current = (book.path == current_doc_path)
    end

    table.sort(books, function(a, b)
        if a.is_current ~= b.is_current then
            return a.is_current
        end
        return a.title:lower() < b.title:lower()
    end)

    return books
end

function HighlightBooks.build_highlights_from_annotations(annotations, with_indices)
    local highlights = {}
    for idx, ann in ipairs(annotations or {}) do
        if HighlightBooks.annotation_is_highlight(ann) then
            highlights[#highlights + 1] = {
                ann = ann,
                ann_index = with_indices and idx or nil,
                text = ann.text,
                chapter = ann.chapter,
            }
        end
    end
    return highlights
end

function HighlightBooks.load_highlights_for_book(doc_path, ui)
    local current_path = ui and ui.document and ui.document.file
    if doc_path and current_path and doc_path == current_path then
        local live = (ui.annotation and ui.annotation.annotations) or {}
        return HighlightBooks.build_highlights_from_annotations(live, true)
    end
    local stored = HighlightBooks.read_sidecar_annotations(doc_path)
    return HighlightBooks.build_highlights_from_annotations(stored, false)
end

function HighlightBooks.make_book_ctx(doc_path, ui)
    doc_path = doc_path or (ui and ui.document and ui.document.file)
    if not doc_path then
        return nil
    end
    local current_path = ui and ui.document and ui.document.file
    local highlights = HighlightBooks.load_highlights_for_book(doc_path, ui)
    return {
        path = doc_path,
        title = HighlightBooks.title_for_path(doc_path, basename(doc_path)),
        is_current = (doc_path == current_path),
        count = #highlights,
    }
end

function HighlightBooks.read_book_metadata(doc_path)
    local title = HighlightBooks.title_for_path(doc_path, basename(doc_path))
    local author = "Unknown Author"
    local DocSettings = require("docsettings")
    local ok, doc_settings = pcall(DocSettings.open, DocSettings, doc_path)
    if ok and doc_settings then
        local props = doc_settings:readSetting("doc_props")
        if props then
            if props.title and props.title ~= "" then
                title = props.title
            end
            if props.authors then
                if type(props.authors) == "table" then
                    author = table.concat(props.authors, ", ")
                elseif props.authors ~= "" then
                    author = props.authors
                end
            end
        end
    end
    return { title = title, author = author }
end

function HighlightBooks.refresh_book_ctx_count(book_ctx, ui)
    if not book_ctx or not book_ctx.path then
        return book_ctx
    end
    book_ctx.count = #HighlightBooks.load_highlights_for_book(book_ctx.path, ui)
    book_ctx.is_current = (book_ctx.path == (ui and ui.document and ui.document.file))
    return book_ctx
end

return HighlightBooks
