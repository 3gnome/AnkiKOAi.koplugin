-- Menu navigation — aligned with KOReader Menu stack (sub_item_table, onClose).

local Device    = require("device")
local Menu      = require("ui/widget/menu")
local Size      = require("ui/size")
local UIManager = require("ui/uimanager")
local _         = require("gettext")

local Nav = {}

-- Width/height for compact menus and framed dialogs (accounts for borders + screen margin).
function Nav.compact_menu_size()
    local Screen = Device.screen
    local border = Size.border.window
    local margin = Screen:scaleBySize(28)
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local w = math.min(screen_w, screen_h) - margin * 2 - border * 2
    w = math.min(w, Screen:scaleBySize(540))
    w = math.max(w, Screen:scaleBySize(200))
    local h = math.floor(screen_h * 0.72)
    h = math.min(h, screen_h - margin * 2 - border * 2)
    h = math.max(h, Screen:scaleBySize(160))
    return w, h
end

function Nav.apply_compact_menu(menu_table)
    local w, h = Nav.compact_menu_size()
    menu_table.width = menu_table.width or w
    menu_table.height = menu_table.height or h
    return menu_table
end

function Nav.center_on_screen(widget)
    if not widget or not widget.dimen then return widget end
    local Screen = Device.screen
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local margin = Screen:scaleBySize(12)
    local w = widget.dimen.w or 0
    local h = widget.dimen.h or 0
    if w > 0 and w + margin * 2 <= screen_w then
        local x = math.floor((screen_w - w) / 2)
        x = math.max(margin, x)
        if x + w > screen_w - margin then
            x = math.max(margin, screen_w - margin - w)
        end
        widget.dimen.x = x
    end
    if h > 0 and h + margin * 2 <= screen_h then
        local y = math.floor((screen_h - h) / 2)
        y = math.max(margin, y)
        if y + h > screen_h - margin then
            y = math.max(margin, screen_h - margin - h)
        end
        widget.dimen.y = y
    end
    return widget
end

function Nav.show(widget)
    UIManager:show(widget)
    -- Re-center after layout so borders/title bars fit inside the screen.
    UIManager:scheduleIn(0, function()
        if widget and widget.dimen then
            Nav.center_on_screen(widget)
        end
    end)
    return widget
end

-- Run open_fn after close_fn so widgets never stack in the window manager.
function Nav.after_close(close_fn, open_fn)
    if close_fn then close_fn() end
    if open_fn then
        UIManager:scheduleIn(0.05, open_fn)
    end
end

-- Menu fires close_callback on every item tap; route real closes through onClose only.
function Nav.wrap_menu(menu, on_close)
    local closing = false

    function menu:onMenuSelect(item)
        if item.sub_item_table ~= nil then
            return Menu.onMenuSelect(self, item)
        end
        if item.select_enabled == false then return true end
        if item.select_enabled_func and not item.select_enabled_func() then return true end
        self:onMenuChoice(item)
        return true
    end

    function menu:onCloseAllMenus()
        if closing then return true end
        closing = true
        UIManager:close(self)
        if on_close then on_close() end
        return true
    end

    function menu:onClose()
        if self.item_table_stack and #self.item_table_stack > 0 then
            return Menu.onClose(self)
        end
        return self:onCloseAllMenus()
    end

    return menu
end

function Nav.back_item(on_back, menu_ref, label)
    return {
        text     = label or _("← Back"),
        bold     = true,
        callback = function()
            local menu = menu_ref and menu_ref[1]
            if menu and menu.onCloseAllMenus then
                menu:onCloseAllMenus()
            elseif on_back then
                on_back()
            end
        end,
    }
end

function Nav.prepend_back(item_table, on_back, menu_ref, label)
    table.insert(item_table, 1, Nav.back_item(on_back, menu_ref, label))
end

-- Replace menu rows without closing the widget (keeps stack / parent menus).
function Nav.replace_menu_items(menu, new_items, title)
    if not menu or not menu.item_table then return end
    local t = menu.item_table
    for i = #t, 1, -1 do
        t[i] = nil
    end
    for i, row in ipairs(new_items) do
        t[i] = row
    end
    if title then
        menu.title = title
        if menu.title_bar then
            menu.title_bar:setTitle(title, true)
        end
    end
    menu.page = 1
    menu:updateItems(1, false)
end

-- Child screen opened from a parent menu: Back row and X both return to parent.
function Nav.show_menu(opts)
    opts = opts or {}
    local menu_ref = {}
    local guard = { busy = false }

    local function close()
        if menu_ref[1] then
            UIManager:close(menu_ref[1])
            menu_ref[1] = nil
        end
    end

    local function go_back()
        if guard.busy or not opts.on_back then return end
        guard.busy = true
        Nav.after_close(close, function()
            guard.busy = false
            opts.on_back()
        end)
    end

    local items = opts.items or {}
    if opts.on_back then
        Nav.prepend_back(items, go_back, menu_ref, opts.back_label)
    end

    menu_ref[1] = Nav.wrap_menu(Menu:new(Nav.apply_compact_menu {
        title      = opts.title,
        item_table = items,
        onMenuHold = opts.onMenuHold,
    }), function()
        if guard.busy then return end
        go_back()
    end)

    Nav.show(menu_ref[1])
    return menu_ref[1], { close = close, go_back = go_back, ref = menu_ref, guard = guard }
end

return Nav
