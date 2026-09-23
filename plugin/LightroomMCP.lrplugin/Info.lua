return {
    LrSdkVersion = 8.0,
    LrSdkMinimumVersion = 8.0,

    LrToolkitIdentifier = 'com.lightroom.mcp',
    LrPluginName = "Lightroom MCP AI",

    LrPluginInfoUrl = "https://github.com/par4987/lightroom-mcp",

    VERSION = { major=3, minor=2, revision=1, build=0 },

    LrPluginInfoProvider = 'PluginInfoProvider.lua',
    LrInitPlugin = 'PluginInit.lua',
    -- LrForceInitPlugin forces eager load on Lr launch, but ONLY if the
    -- plugin also exposes at least one menu item — see LrLibraryMenuItems
    -- below. Adobe's own remote_control_socket sample uses this pattern.
    LrForceInitPlugin = true,

    LrLibraryMenuItems = {
        {
            title = "Lightroom MCP — Show Status",
            file = "MenuShowStatus.lua",
        },
    },
}
