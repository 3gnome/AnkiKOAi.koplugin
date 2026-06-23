-- Page/chapter hints for Source citations while reading.

local ReadingLocation = {}

function ReadingLocation.describe(ui)
    if not ui then return "" end

    local parts = {}

    pcall(function()
        if ui.getCurrentPage then
            local page = ui:getCurrentPage()
            if page and tonumber(page) then
                table.insert(parts, "p. " .. tostring(page))
            end
        end
    end)

    pcall(function()
        if ui.getBookLocation then
            local loc = ui:getBookLocation()
            if type(loc) == "string" and loc ~= "" then
                table.insert(parts, loc)
            end
        end
    end)

    return table.concat(parts, ", ")
end

function ReadingLocation.append_to_source(base, ui)
    base = (base or ""):match("^%s*(.-)%s*$") or ""
    local loc = ReadingLocation.describe(ui)
    if base == "" then return loc end
    if loc == "" then return base end
    return base .. " (" .. loc .. ")"
end

return ReadingLocation
