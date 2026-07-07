-- Optional peer-plugin detection (no hard dependencies).

local PluginPeers = {}

-- KOReader keys plugins by class `name` (TagBankHighlightSync), not folder name.
local TAGBANK_PLUGIN_IDS = { "TagBankHighlightSync", "tagbankhighlightsync" }

local function plugin_loader()
    local ok, PluginLoader = pcall(require, "pluginloader")
    if ok then
        return PluginLoader
    end
    return nil
end

local function tagbank_on_ui(ui)
    if not ui then
        return nil
    end
    return ui.TagBankHighlightSync or ui.tagbankhighlightsync
end

local function tagbank_from_loader(loader)
    if not loader or not loader.getPluginInstance then
        return nil
    end
    for _, id in ipairs(TAGBANK_PLUGIN_IDS) do
        if (loader.isPluginLoaded and loader:isPluginLoaded(id))
            or loader:getPluginInstance(id) then
            return loader:getPluginInstance(id)
        end
    end
    return nil
end

--- True when TagBankHighlightSync is installed and loaded.
function PluginPeers.is_tagbank_available(ui)
    local loader = plugin_loader()
    if tagbank_from_loader(loader) then
        return true
    end
    return tagbank_on_ui(ui) ~= nil
end

--- @return table|nil TagBankHighlightSync plugin instance
function PluginPeers.get_tagbank_plugin(ui)
    local inst = tagbank_from_loader(plugin_loader())
    if inst then
        return inst
    end
    return tagbank_on_ui(ui)
end

return PluginPeers
