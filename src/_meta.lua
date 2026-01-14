local _ = require("gettext")
return {
    name = "bubblezoom",
    fullname = _("Bubble Zoom"),
    description = _([[Magnify speech bubbles in comics/manga.]]),
    author = "https://github.com/anezih",
    version = "1.1.0",
    homepage = "https://github.com/anezih/bubblezoom.koplugin",
    module_depends = {},
    document_types = {"cbz", "cbr", "cbt"},
    disabled = false,
}