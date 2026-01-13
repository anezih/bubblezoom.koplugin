local Device = require("device")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")
local SpinWidget = require("ui/widget/spinwidget")
local Widget = require("ui/widget/widget")
local bit = require("bit")
local ffi = require("ffi")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

-- GC every few cache drops.
local GC_EVERY = 5
local gc_count = 0

local BubbleZoomOverlay = Widget:extend{
    owner = nil,
    line_w = 2,
}

---Draws the magnified bubble overlay into the page buffer; used by the view module paint cycle.
---@param bb table Target blitbuffer.
---@param x number
---@param y number
function BubbleZoomOverlay:paintTo(bb, x, y)
    local owner = self.owner
    if not owner or not owner.overlay_rect or not owner.overlay_page or not owner.overlay_src_rect then
        return
    end
    local screen_rect = self.view:pageToScreenTransform(owner.overlay_page, owner.overlay_rect)
    if not screen_rect then
        return
    end
    local rx = math.floor(screen_rect.x + 0.5)
    local ry = math.floor(screen_rect.y + 0.5)
    local rw = math.floor(screen_rect.w + 0.5)
    local rh = math.floor(screen_rect.h + 0.5)
    if rw <= 0 or rh <= 0 then
        return
    end

    local view_zoom = self.view and self.view.state and self.view.state.zoom or 1.0
    local overlay_scale = owner.overlay_scale_active or owner.overlay_scale
    local zoom = view_zoom * overlay_scale
    local rotation = self.view and self.view.state and self.view.state.rotation or 0
    local gamma = self.view and self.view.state and self.view.state.gamma or 1.0
    local rect_scaled = Geom:new(owner.overlay_src_rect)
    rect_scaled:transformByScale(zoom)
    owner.document:drawPage(bb, rx, ry, rect_scaled, owner.overlay_page, zoom, rotation, gamma)

end

local BubbleZoom = InputContainer:extend{
    name = "bubblezoom",
    is_doc_only = false,
    enabled = true,
    use_tap = false,
    padding_ratio = 0.01,
    overlay_scale = 2.0,
    sauvola_window_size = 31,
    sauvola_k = 0.35,
    sauvola_r = 128.0,
    filled_cutoff = 200,
    closing_radius = 1,
    closing_margin = 6,
    max_roi = 96,
    touch_zones = nil,
    hold_consumed = false,
    overlay_rect = nil,
    overlay_src_rect = nil,
    overlay_page = nil,
    overlay_scale_active = nil,
    overlay = nil,
    sauvola_cache = nil,
    use_custom_contrast = false,
    custom_contrast = 2.0,
}

---Loads global settings; used by plugin init.
function BubbleZoom:init()
    self.enabled = G_reader_settings:readSetting("bubblezoom_enabled", true)
    self.use_tap = G_reader_settings:readSetting("bubblezoom_use_tap", false)
    self.padding_ratio = G_reader_settings:readSetting("bubblezoom_padding_ratio", 0.01)
    self.overlay_scale = G_reader_settings:readSetting("bubblezoom_overlay_scale", 2.0)
    self.sauvola_window_size = G_reader_settings:readSetting("bubblezoom_sauvola_window_size", 31)
    self.sauvola_k = G_reader_settings:readSetting("bubblezoom_sauvola_k", 0.35)
    self.sauvola_r = G_reader_settings:readSetting("bubblezoom_sauvola_r", 128.0)
    self.filled_cutoff = G_reader_settings:readSetting("bubblezoom_filled_cutoff", 200)
    self.closing_radius = G_reader_settings:readSetting("bubblezoom_closing_radius", 1)
    self.closing_margin = G_reader_settings:readSetting("bubblezoom_closing_margin", 6)
    self.max_roi = G_reader_settings:readSetting("bubblezoom_max_roi", 96)
    self.use_custom_contrast = G_reader_settings:readSetting("bubblezoom_use_custom_contrast", false)
    self.custom_contrast = G_reader_settings:readSetting("bubblezoom_custom_contrast", 2.0)
end

---Registers menu entries, overlay view, and touch zones; used by the reader-ready hook.
function BubbleZoom:onReaderReady()
    self.ui.menu:registerToMainMenu(self)
    if not self.overlay then
        self.overlay = BubbleZoomOverlay:new{ owner = self }
        self.view:registerViewModule("bubblezoom_overlay", self.overlay)
    end
    self:setupTouchZones()
end

---Clears overlay state and Sauvola cache on page change; used by the page update hook.
function BubbleZoom:onPageUpdate()
    local had_cache = self.sauvola_cache ~= nil
    self.hold_consumed = false
    self.overlay_rect = nil
    self.overlay_src_rect = nil
    self.overlay_page = nil
    self.overlay_scale_active = nil
    self.sauvola_cache = nil
    if had_cache then
        gc_count = gc_count + 1
        if gc_count >= GC_EVERY then
            UIManager:scheduleIn(0.2, function()
                collectgarbage()
                collectgarbage()
            end)
            gc_count = 0
        end
    end
end

---Populates the main menu entries for Bubble Zoom; used by menu registration.
---@param menu_items table Main menu table to append into.
function BubbleZoom:addToMainMenu(menu_items)
    menu_items.bubblezoom = {
        text = _("Bubble Zoom"),
        sorting_hint = "typeset",
        sub_item_table = {
            {
                text = _("Enable"),
                checked_func = function() return self.enabled end,
                callback = function()
                    self.enabled = not self.enabled
                    G_reader_settings:saveSetting("bubblezoom_enabled", self.enabled)
                    self:setupTouchZones()
                    return true
                end,
            },
            {
                text = _("Use tap (overrides page turns)"),
                checked_func = function() return self.use_tap end,
                help_text = _("When disabled, long-press is used to detect speech bubbles."),
                callback = function()
                    self.use_tap = not self.use_tap
                    G_reader_settings:saveSetting("bubblezoom_use_tap", self.use_tap)
                    self:setupTouchZones()
                    return true
                end,
            },
            {
                text_func = function()
                    return T(_("Overlay zoom factor: %1"), string.format("%.1f", self.overlay_scale))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local spin = SpinWidget:new{
                        title_text = _("Overlay zoom factor"),
                        info_text = _("Scale of the bubble content inside the overlay."),
                        value = self.overlay_scale,
                        default_value = 2.0,
                        value_min = 1.0,
                        value_max = 5.0,
                        value_step = 0.1,
                        value_hold_step = 0.5,
                        precision = "%.1f",
                        callback = function(widget)
                            self.overlay_scale = widget.value
                            G_reader_settings:saveSetting("bubblezoom_overlay_scale", widget.value)
                            if self.overlay_rect then
                                UIManager:setDirty(self.ui.dialog, "partial")
                            end
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    }
                    UIManager:show(spin)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
            {
                text = _("Advanced"),
                sub_item_table = {
                    {
                        text = _("Custom Contrast"),
                        sub_item_table = {
                            {
                                text = _("Use custom contrast value"),
                                checked_func = function() return self.use_custom_contrast end,
                                help_text = _("When enabled, a custom contrast value is used for bubble detection. Higher values may improve detection accuracy."),
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self.use_custom_contrast = not self.use_custom_contrast
                                    G_reader_settings:saveSetting("bubblezoom_use_custom_contrast", self.use_custom_contrast)
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            },
                            {
                                text_func = function()
                                    return T(_("Custom contrast: %1"), string.format("%.2f", self.custom_contrast))
                                end,
                                help_text = _("Contrast value used for bubble detection when enabled."),
                                keep_menu_open = true,
                                enabled_func = function() return self.use_custom_contrast end,
                                callback = function(touchmenu_instance)
                                    local spin = SpinWidget:new{
                                        title_text = _("Custom contrast"),
                                        info_text = _("Contrast value used for bubble detection."),
                                        value = self.custom_contrast,
                                        default_value = 2.0,
                                        value_min = 0.8,
                                        value_max = 10.0,
                                        value_step = 0.1,
                                        value_hold_step = 0.5,
                                        precision = "%.2f",
                                        callback = function(widget)
                                            local value = widget.value
                                            if value < 0.8 then value = 0.8 end
                                            if value > 10.0 then value = 10.0 end
                                            self.custom_contrast = value
                                            G_reader_settings:saveSetting("bubblezoom_custom_contrast", value)
                                            if touchmenu_instance then touchmenu_instance:updateItems() end
                                        end,
                                    }
                                    UIManager:show(spin)
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            },
                        },
                    },
                    {
                        text = _("Sauvola Thresholding"),
                        sub_item_table = {
                            {
                                text_func = function()
                                    return T(_("Sauvola window size: %1"), self.sauvola_window_size)
                                end,
                                help_text = _("Local window size in pixels for Sauvola thresholding. Larger values smooth more but may miss thin outlines."),
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    local spin = SpinWidget:new{
                                        title_text = _("Sauvola window size"),
                                        info_text = _("Local window size in pixels for Sauvola thresholding."),
                                        value = self.sauvola_window_size,
                                        default_value = 31,
                                        value_min = 3,
                                        value_max = 101,
                                        value_step = 2,
                                        value_hold_step = 10,
                                        callback = function(widget)
                                            local value = math.floor(widget.value)
                                            if value < 3 then value = 3 end
                                            if value % 2 == 0 then value = value + 1 end
                                            self.sauvola_window_size = value
                                            G_reader_settings:saveSetting("bubblezoom_sauvola_window_size", value)
                                            if touchmenu_instance then touchmenu_instance:updateItems() end
                                        end,
                                    }
                                    UIManager:show(spin)
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            },
                            {
                                text_func = function()
                                    return T(_("Sauvola k: %1"), string.format("%.2f", self.sauvola_k))
                                end,
                                help_text = _("Sauvola k controls how aggressive thresholding is. Higher values detect more foreground."),
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    local spin = SpinWidget:new{
                                        title_text = _("Sauvola k"),
                                        info_text = _("Higher values detect more foreground."),
                                        value = self.sauvola_k,
                                        default_value = 0.35,
                                        value_min = 0.05,
                                        value_max = 1.0,
                                        value_step = 0.05,
                                        value_hold_step = 0.1,
                                        precision = "%.2f",
                                        callback = function(widget)
                                            self.sauvola_k = widget.value
                                            G_reader_settings:saveSetting("bubblezoom_sauvola_k", widget.value)
                                            if touchmenu_instance then touchmenu_instance:updateItems() end
                                        end,
                                    }
                                    UIManager:show(spin)
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            },
                            {
                                text_func = function()
                                    return T(_("Sauvola R: %1"), string.format("%.0f", self.sauvola_r))
                                end,
                                help_text = _("Sauvola R is the dynamic range of standard deviation. Typical value is 128."),
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    local spin = SpinWidget:new{
                                        title_text = _("Sauvola R"),
                                        info_text = _("Dynamic range of standard deviation."),
                                        value = self.sauvola_r,
                                        default_value = 128.0,
                                        value_min = 16.0,
                                        value_max = 255.0,
                                        value_step = 1.0,
                                        value_hold_step = 10.0,
                                        precision = "%.0f",
                                        callback = function(widget)
                                            self.sauvola_r = widget.value
                                            G_reader_settings:saveSetting("bubblezoom_sauvola_r", widget.value)
                                            if touchmenu_instance then touchmenu_instance:updateItems() end
                                        end,
                                    }
                                    UIManager:show(spin)
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            },
                        },
                    },
                    {
                        text = _("Morphological Closing"),
                        help_text = _("Settings for morphological closing operation to help escape small enclosed regions."),
                        sub_item_table = {
                            {
                                text_func = function()
                                    return T(_("Closing radius: %1"), self.closing_radius)
                                end,
                                help_text = _("Radius in pixels for a tiny closing step that helps escape small enclosed regions."),
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    local spin = SpinWidget:new{
                                        title_text = _("Closing radius"),
                                        info_text = _("Radius in pixels for the closing step."),
                                        value = self.closing_radius,
                                        default_value = 1,
                                        value_min = 0,
                                        value_max = 4,
                                        value_step = 1,
                                        value_hold_step = 1,
                                        callback = function(widget)
                                            local value = math.floor(widget.value)
                                            if value < 0 then value = 0 end
                                            self.closing_radius = value
                                            G_reader_settings:saveSetting("bubblezoom_closing_radius", value)
                                            if touchmenu_instance then touchmenu_instance:updateItems() end
                                        end,
                                    }
                                    UIManager:show(spin)
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            },
                            {
                                text_func = function()
                                    return T(_("Closing margin: %1"), self.closing_margin)
                                end,
                                help_text = _("Extra pixels added around the initial fill bounds before closing."),
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    local spin = SpinWidget:new{
                                        title_text = _("Closing margin"),
                                        info_text = _("Extra pixels added around the initial fill bounds."),
                                        value = self.closing_margin,
                                        default_value = 6,
                                        value_min = 0,
                                        value_max = 20,
                                        value_step = 1,
                                        value_hold_step = 5,
                                        callback = function(widget)
                                            local value = math.floor(widget.value)
                                            if value < 0 then value = 0 end
                                            self.closing_margin = value
                                            G_reader_settings:saveSetting("bubblezoom_closing_margin", value)
                                            if touchmenu_instance then touchmenu_instance:updateItems() end
                                        end,
                                    }
                                    UIManager:show(spin)
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            },
                            {
                                text_func = function()
                                    return T(_("Max closing ROI: %1"), self.max_roi)
                                end,
                                help_text = _("Maximum size in pixels for the closing region to limit processing cost."),
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    local spin = SpinWidget:new{
                                        title_text = _("Max closing ROI"),
                                        info_text = _("Maximum width/height of the closing region."),
                                        value = self.max_roi,
                                        default_value = 96,
                                        value_min = 16,
                                        value_max = 256,
                                        value_step = 8,
                                        value_hold_step = 16,
                                        callback = function(widget)
                                            local value = math.floor(widget.value)
                                            if value < 16 then value = 16 end
                                            self.max_roi = value
                                            G_reader_settings:saveSetting("bubblezoom_max_roi", value)
                                            if touchmenu_instance then touchmenu_instance:updateItems() end
                                        end,
                                    }
                                    UIManager:show(spin)
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            },
                        },
                    },
                    {
                        text_func = function()
                            return T(_("Padding ratio: %1"), string.format("%.2f", self.padding_ratio))
                        end,
                        help_text = _("Extra padding added around the detected bubble before scaling. Set to 0 to disable."),
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            local spin = SpinWidget:new{
                                title_text = _("Padding ratio"),
                                info_text = _("Extra padding around the bubble before scaling."),
                                value = self.padding_ratio,
                                default_value = 0.0,
                                value_min = 0.0,
                                value_max = 0.5,
                                value_step = 0.01,
                                value_hold_step = 0.05,
                                precision = "%.2f",
                                callback = function(widget)
                                    local value = widget.value
                                    if value < 0 then value = 0 end
                                    self.padding_ratio = value
                                    G_reader_settings:saveSetting("bubblezoom_padding_ratio", value)
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            }
                            UIManager:show(spin)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    },
                    {
                        text_func = function()
                            return T(_("Fill cutoff: %1"), self.filled_cutoff)
                        end,
                        help_text = _("Threshold for recognizing area as speech bubble. Lower values may select small closed shapes like the inside of an 'o'."),
                        keep_menu_open = true,
                        separator = true,
                        callback = function(touchmenu_instance)
                            local spin = SpinWidget:new{
                                title_text = _("Fill cutoff"),
                                info_text = _("Minimum flood-fill pixel count to accept a bubble."),
                                value = self.filled_cutoff,
                                default_value = 200,
                                value_min = 10,
                                value_max = 5000,
                                value_step = 10,
                                value_hold_step = 100,
                                callback = function(widget)
                                    local value = math.floor(widget.value)
                                    if value < 1 then value = 1 end
                                    self.filled_cutoff = value
                                    G_reader_settings:saveSetting("bubblezoom_filled_cutoff", value)
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            }
                            UIManager:show(spin)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    },
                    {
                        text = _("Reset advanced defaults"),
                        help_text = _("Restore the default Sauvola parameters, cutoff, closing, and padding."),
                        keep_menu_open = true,
                        separator = true,
                        callback = function(touchmenu_instance)
                            self.sauvola_window_size = 31
                            self.sauvola_k = 0.35
                            self.sauvola_r = 128.0
                            self.filled_cutoff = 200
                            self.closing_radius = 1
                            self.closing_margin = 6
                            self.max_roi = 96
                            self.padding_ratio = 0.01
                            self.use_custom_contrast = false
                            self.custom_contrast = 2.0
                            G_reader_settings:saveSetting("bubblezoom_sauvola_window_size", 31)
                            G_reader_settings:saveSetting("bubblezoom_sauvola_k", 0.35)
                            G_reader_settings:saveSetting("bubblezoom_sauvola_r", 128.0)
                            G_reader_settings:saveSetting("bubblezoom_filled_cutoff", 200)
                            G_reader_settings:saveSetting("bubblezoom_closing_radius", 1)
                            G_reader_settings:saveSetting("bubblezoom_closing_margin", 6)
                            G_reader_settings:saveSetting("bubblezoom_max_roi", 96)
                            G_reader_settings:saveSetting("bubblezoom_padding_ratio", 0.01)
                            G_reader_settings:saveSetting("bubblezoom_use_custom_contrast", false)
                            G_reader_settings:saveSetting("bubblezoom_custom_contrast", 2.0)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    },
                },
            },
        },
    }
end

---Builds touch zones for bubble gestures and dismissal; used by onReaderReady and menu toggles.
function BubbleZoom:setupTouchZones()
    if not Device:isTouchDevice() then
        return
    end

    if self.touch_zones then
        self.ui:unRegisterTouchZones(self.touch_zones)
        self.touch_zones = nil
    end

    if not self.enabled then
        return
    end

    local zones = {}
    table.insert(zones, {
        id = "bubblezoom_tap_dismiss",
        ges = "tap",
        screen_zone = {
            ratio_x = 0, ratio_y = 0,
            ratio_w = 1, ratio_h = 1,
        },
        overrides = {
            "tap_top_left_corner",
            "tap_top_right_corner",
            "tap_left_bottom_corner",
            "tap_right_bottom_corner",
            "readerfooter_tap",
            "readerconfigmenu_ext_tap",
            "readerconfigmenu_tap",
            "readermenu_ext_tap",
            "readermenu_tap",
            "tap_forward",
            "tap_backward",
            "readerhighlight_tap",
        },
        handler = function(ges_ev)
            return self:maybeDismissOverlay(ges_ev)
        end,
    })
    if self.use_tap then
        table.insert(zones, {
            id = "bubblezoom_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "tap_forward",
                "tap_backward",
                "readerhighlight_tap",
            },
            handler = function(ges_ev)
                return self:onBubbleGesture(ges_ev, false)
            end,
        })
    end

    table.insert(zones, {
        id = "bubblezoom_hold",
        ges = "hold",
        screen_zone = {
            ratio_x = 0, ratio_y = 0,
            ratio_w = 1, ratio_h = 1,
        },
        overrides = {
            "readerhighlight_hold",
        },
        handler = function(ges_ev)
            return self:onBubbleGesture(ges_ev, true)
        end,
    })
    table.insert(zones, {
        id = "bubblezoom_hold_release",
        ges = "hold_release",
        screen_zone = {
            ratio_x = 0, ratio_y = 0,
            ratio_w = 1, ratio_h = 1,
        },
        overrides = {
            "readerhighlight_hold_release",
        },
        handler = function()
            return self:onBubbleHoldRelease()
        end,
    })

    self.touch_zones = zones
    self.ui:registerTouchZones(self.touch_zones)
end

---Returns true for comic book archive extensions; used by onBubbleGesture.
---@return boolean is_comic
function BubbleZoom:isComicDocument()
    if not self.document or not self.document.file then
        return false
    end
    local ext = util.getFileNameSuffix(self.document.file):lower()
    return ext == "cbz" or ext == "cbr" or ext == "cbt"
end

---Dismisses overlay when a gesture lands inside the overlay rect; used by tap/hold handlers.
---@param ges table Gesture event.
---@return boolean handled
function BubbleZoom:maybeDismissOverlay(ges)
    if not self.overlay_rect or not self.overlay_page then
        return false
    end
    local pos = self.view:screenToPageTransform(ges.pos)
    if not pos or pos.page ~= self.overlay_page then
        return false
    end
    if pos.x >= self.overlay_rect.x and pos.x <= (self.overlay_rect.x + self.overlay_rect.w)
        and pos.y >= self.overlay_rect.y and pos.y <= (self.overlay_rect.y + self.overlay_rect.h) then
        self.hold_consumed = false
        self.overlay_rect = nil
        self.overlay_src_rect = nil
        self.overlay_page = nil
        self.overlay_scale_active = nil
        UIManager:setDirty(self.ui.dialog, "partial")
        return true
    end
    return false
end

---Handles tap/hold to detect a bubble and show overlay; used by touch zone handlers.
---@param ges table Gesture event.
---@param consume_on_miss boolean Whether to consume the gesture when no bubble is found.
---@return boolean handled
function BubbleZoom:onBubbleGesture(ges, consume_on_miss)
    if not self.enabled then
        return false
    end
    if not self:isComicDocument() then
        return false
    end
    local pos = self.view:screenToPageTransform(ges.pos)
    if not pos or not pos.page then
        return false
    end
    if self:maybeDismissOverlay(ges) then
        return true
    end

    local rect = self:detectBubbleRect(pos.page, pos.x, pos.y)
    if not rect then
        if consume_on_miss then
            self.hold_consumed = true
            self.overlay_rect = nil
            self.overlay_src_rect = nil
            self.overlay_page = nil
            self.overlay_scale_active = nil
            UIManager:setDirty(self.ui.dialog, "partial")
        end
        UIManager:show(Notification:new{
            text = _("No bubble found"),
        })
        return true
    end

    local handled = self:showOverlayRect(pos.page, rect, pos.x, pos.y)
    if consume_on_miss then
        self.hold_consumed = handled
    end
    return handled
end

---Swallows hold-release after a consumed hold to avoid default actions; used by hold_release handler.
---@return boolean handled
function BubbleZoom:onBubbleHoldRelease()
    if self.hold_consumed then
        self.hold_consumed = false
        return true
    end
    return false
end

---Computes or reuses Sauvola cache (mask only) for a page render; used by detectBubbleRect.
---@param pageno number
---@param rotation number
---@param gamma number
---@return table|nil cache
function BubbleZoom:getSauvolaCache(pageno, rotation, gamma)
    local window_size = tonumber(self.sauvola_window_size) or 31
    if window_size < 3 then window_size = 3 end
    if window_size % 2 == 0 then window_size = window_size + 1 end
    local sauvola_k = tonumber(self.sauvola_k) or 0.35
    local sauvola_r = tonumber(self.sauvola_r) or 128.0
    if sauvola_r <= 0 then sauvola_r = 128.0 end

    local cache = self.sauvola_cache
    if cache
        and cache.page == pageno
        and cache.rotation == rotation
        and cache.gamma == gamma
        and cache.window_size == window_size
        and cache.k == sauvola_k
        and cache.r == sauvola_r then
        return cache
    end

    local tile = self.document:renderPage(pageno, nil, 1.0, rotation, gamma, true)
    if not tile or not tile.bb then
        return nil
    end

    local bb = tile.bb
    local width = bb:getWidth()
    local height = bb:getHeight()
    if width <= 0 or height <= 0 then
        return nil
    end

    local pixel_count = width * height
    local luma = ffi.new("uint8_t[?]", pixel_count)
    local idx = 0
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local c = bb:getPixel(x, y):getColorRGB24()
            luma[idx] = bit.rshift(77 * c.r + 150 * c.g + 29 * c.b, 8)
            idx = idx + 1
        end
    end

    -- For integral image padding
    local width1 = width + 1
    local height1 = height + 1
    local integral = ffi.new("int64_t[?]", width1 * height1)
    local integral_sq = ffi.new("int64_t[?]", width1 * height1)
    for y = 1, height1 - 1 do
        local row_offset = y * width1
        local prev_row = row_offset - width1
        local original_row = (y - 1) * width
        local row_sum = 0
        local row_squares = 0
        for x = 1, width1 - 1 do
            local value = luma[original_row + x - 1]
            row_sum = row_sum + value
            row_squares = row_squares + value * value
            integral[row_offset + x] = integral[prev_row + x] + row_sum
            integral_sq[row_offset + x] = integral_sq[prev_row + x] + row_squares
        end
    end

    -- Sauvola threshold mask
    -- J. Sauvola and M. Pietikainen, “Adaptive document image binarization,” Pattern Recognition 33(2), pp. 225-236, 2000. DOI:10.1016/S0031-3203(99)00055-2
    local mask = ffi.new("uint8_t[?]", pixel_count)
    local window_half = math.floor(window_size / 2)
    for y = 0, height - 1 do
        local y1 = y - window_half
        local y2 = y + window_half
        if y1 < 0 then y1 = 0 end
        if y2 >= height then y2 = height - 1 end
        local row_idx = y * width
        for x = 0, width - 1 do
            local x1 = x - window_half
            local x2 = x + window_half
            if x1 < 0 then x1 = 0 end
            if x2 >= width then x2 = width - 1 end

            local a = y1 * width1 + x1
            local b = y1 * width1 + (x2 + 1)
            local c = (y2 + 1) * width1 + x1
            local d = (y2 + 1) * width1 + (x2 + 1)

            local area = (x2 - x1 + 1) * (y2 - y1 + 1)
            local sum = tonumber(integral[d] + integral[a] - integral[b] - integral[c])
            local sum_sq = tonumber(integral_sq[d] + integral_sq[a] - integral_sq[b] - integral_sq[c])

            local mean = sum / area
            local variance = (sum_sq / area) - (mean * mean)
            local std_dev = variance > 0 and math.sqrt(variance) or 0
            local threshold = mean * (1 + sauvola_k * ((std_dev / sauvola_r) - 1))

            local index = row_idx + x
            if luma[index] > threshold then
                mask[index] = 255
            else
                mask[index] = 0
            end
        end
    end

    cache = {
        page = pageno,
        rotation = rotation,
        gamma = gamma,
        window_size = window_size,
        k = sauvola_k,
        r = sauvola_r,
        width = width,
        height = height,
        mask = mask,
    }
    self.sauvola_cache = cache
    return cache
end

---Returns the effective contrast for detection (system or custom).
---@return number gamma
function BubbleZoom:getDetectionGamma()
    local gamma = self.view and self.view.state and self.view.state.gamma or 1.0
    if not self.use_custom_contrast then
        return gamma
    end
    local custom = tonumber(self.custom_contrast) or gamma
    if custom < 0.8 then custom = 0.8 end
    if custom > 10.0 then custom = 10.0 end
    return custom
end

---Detects a speech bubble rectangle via Sauvola mask + flood fill; used by onBubbleGesture.
---@param pageno number
---@param tap_x number
---@param tap_y number
---@return Geom|nil rect
function BubbleZoom:detectBubbleRect(pageno, tap_x, tap_y)
    local rotation = self.view and self.view.state and self.view.state.rotation or 0
    local gamma = self:getDetectionGamma()
    local cache = self:getSauvolaCache(pageno, rotation, gamma)
    if not cache then
        return nil
    end

    local width = cache.width
    local height = cache.height
    if width <= 0 or height <= 0 then
        return nil
    end

    local mask = cache.mask

    local bx = math.floor(tap_x + 0.5)
    local by = math.floor(tap_y + 0.5)
    if bx < 0 or by < 0 or bx >= width or by >= height then
        return nil
    end

    local pixel_count = width * height

    ---Flood-fills from the tap using an optional closed mask; used by detectBubbleRect.
    ---@param closed userdata|nil
    ---@param roi table|nil
    ---@return number filled
    ---@return number min_x
    ---@return number max_x
    ---@return number min_y
    ---@return number max_y
    local function floodFill(closed, roi)
        local queue = ffi.new("struct { int32_t x; int32_t y; }[?]", pixel_count)
        local head = 0
        local tail = 0
        queue[0].x = bx
        queue[0].y = by

        local visited = ffi.new("uint8_t[?]", pixel_count)
        local min_x, max_x = bx, bx
        local min_y, max_y = by, by
        local filled = 0
        local start_index = by * width + bx
        visited[start_index] = 1

        while head <= tail do
            local x = queue[head].x
            local y = queue[head].y
            head = head + 1
            local index = y * width + x
            local is_white
            if closed
                and x >= roi.x1 and x <= roi.x2
                and y >= roi.y1 and y <= roi.y2 then
                local rindex = (y - roi.y1) * roi.w + (x - roi.x1)
                is_white = closed[rindex] == 255
            else
                is_white = mask[index] == 255
            end
            if is_white then
                filled = filled + 1
                if x < min_x then min_x = x end
                if x > max_x then max_x = x end
                if y < min_y then min_y = y end
                if y > max_y then max_y = y end

                if x > 0 then
                    local nindex = index - 1
                    if visited[nindex] == 0 then
                        visited[nindex] = 1
                        tail = tail + 1
                        queue[tail].x = x - 1
                        queue[tail].y = y
                    end
                end
                if x < width - 1 then
                    local nindex = index + 1
                    if visited[nindex] == 0 then
                        visited[nindex] = 1
                        tail = tail + 1
                        queue[tail].x = x + 1
                        queue[tail].y = y
                    end
                end
                if y > 0 then
                    local nindex = index - width
                    if visited[nindex] == 0 then
                        visited[nindex] = 1
                        tail = tail + 1
                        queue[tail].x = x
                        queue[tail].y = y - 1
                    end
                end
                if y < height - 1 then
                    local nindex = index + width
                    if visited[nindex] == 0 then
                        visited[nindex] = 1
                        tail = tail + 1
                        queue[tail].x = x
                        queue[tail].y = y + 1
                    end
                end
            end
        end

        return filled, min_x, max_x, min_y, max_y
    end

    ---Builds a locally closed mask for a ROI; used by detectBubbleRect.
    ---@param x1 number
    ---@param y1 number
    ---@param x2 number
    ---@param y2 number
    ---@param radius number
    ---@return userdata|nil closed
    ---@return number|nil roi_w
    ---@return number|nil roi_h
    local function buildClosedMask(x1, y1, x2, y2, radius)
        local roi_w = x2 - x1 + 1
        local roi_h = y2 - y1 + 1
        if roi_w <= 0 or roi_h <= 0 then
            return nil
        end

        local ex1 = x1 - radius
        if ex1 < 0 then ex1 = 0 end
        local ey1 = y1 - radius
        if ey1 < 0 then ey1 = 0 end
        local ex2 = x2 + radius
        if ex2 >= width then ex2 = width - 1 end
        local ey2 = y2 + radius
        if ey2 >= height then ey2 = height - 1 end

        local exp_w = ex2 - ex1 + 1
        local exp_h = ey2 - ey1 + 1

        local tmp = ffi.new("uint8_t[?]", exp_w * exp_h)
        local closed_exp = ffi.new("uint8_t[?]", exp_w * exp_h)

        for y = ey1, ey2 do
            local ry = y - ey1
            local row_offset = ry * exp_w
            for x = ex1, ex2 do
                local white = false
                for ny = y - radius, y + radius do
                    if ny >= 0 and ny < height then
                        local base = ny * width
                        for nx = x - radius, x + radius do
                            if nx >= 0 and nx < width then
                                if mask[base + nx] == 255 then
                                    white = true
                                    break
                                end
                            end
                        end
                    end
                    if white then break end
                end
                tmp[row_offset + (x - ex1)] = white and 255 or 0
            end
        end

        for y = 0, exp_h - 1 do
            local row_offset = y * exp_w
            for x = 0, exp_w - 1 do
                local keep = true
                for ny = y - radius, y + radius do
                    if ny < 0 or ny >= exp_h then
                        keep = false
                        break
                    end
                    local base = ny * exp_w
                    for nx = x - radius, x + radius do
                        if nx < 0 or nx >= exp_w then
                            keep = false
                            break
                        end
                        if tmp[base + nx] == 0 then
                            keep = false
                            break
                        end
                    end
                    if not keep then break end
                end
                closed_exp[row_offset + x] = keep and 255 or 0
            end
        end

        if ex1 == x1 and ey1 == y1 and exp_w == roi_w and exp_h == roi_h then
            return closed_exp, roi_w, roi_h
        end

        local closed = ffi.new("uint8_t[?]", roi_w * roi_h)
        for y = y1, y2 do
            local src_row = (y - ey1) * exp_w
            local dst_row = (y - y1) * roi_w
            for x = x1, x2 do
                closed[dst_row + (x - x1)] = closed_exp[src_row + (x - ex1)]
            end
        end

        return closed, roi_w, roi_h
    end

    local filled, min_x, max_x, min_y, max_y = floodFill(nil, nil)
    local cutoff = tonumber(self.filled_cutoff) or 200

    if filled <= cutoff then
        -- Apply closing to escape closed section.
        local closing_radius = tonumber(self.closing_radius) or 1
        if closing_radius < 0 then closing_radius = 0 end
        local closing_margin = tonumber(self.closing_margin) or 3
        if closing_margin < 0 then closing_margin = 0 end
        local roi_x1 = math.max(0, min_x - closing_margin)
        local roi_y1 = math.max(0, min_y - closing_margin)
        local roi_x2 = math.min(width - 1, max_x + closing_margin)
        local roi_y2 = math.min(height - 1, max_y + closing_margin)

        local max_roi = tonumber(self.max_roi) or 96
        if max_roi < 16 then max_roi = 16 end
        local roi_w = roi_x2 - roi_x1 + 1
        local roi_h = roi_y2 - roi_y1 + 1
        if roi_w > max_roi then
            local half = math.floor(max_roi / 2)
            roi_x1 = bx - half
            roi_x2 = roi_x1 + max_roi - 1
            if roi_x1 < 0 then
                roi_x1 = 0
                roi_x2 = math.min(width - 1, max_roi - 1)
            elseif roi_x2 >= width then
                roi_x2 = width - 1
                roi_x1 = math.max(0, roi_x2 - max_roi + 1)
            end
        end
        if roi_h > max_roi then
            local half = math.floor(max_roi / 2)
            roi_y1 = by - half
            roi_y2 = roi_y1 + max_roi - 1
            if roi_y1 < 0 then
                roi_y1 = 0
                roi_y2 = math.min(height - 1, max_roi - 1)
            elseif roi_y2 >= height then
                roi_y2 = height - 1
                roi_y1 = math.max(0, roi_y2 - max_roi + 1)
            end
        end

        local closed, closed_w, closed_h = buildClosedMask(roi_x1, roi_y1, roi_x2, roi_y2, closing_radius)
        if closed then
            local roi = {
                x1 = roi_x1,
                y1 = roi_y1,
                x2 = roi_x2,
                y2 = roi_y2,
                w = closed_w,
                h = closed_h,
            }
            filled, min_x, max_x, min_y, max_y = floodFill(closed, roi)
        end
    end

    -- Possibly a false positive, like the inside of an "o"
    if filled <= cutoff then
        return nil
    end

    return Geom:new{
        x = min_x,
        y = min_y,
        w = (max_x - min_x + 1),
        h = (max_y - min_y + 1),
    }
end

---Scales a rect around a point and clamps it to page bounds; used by showOverlayRect.
---@param rect Geom
---@param px number
---@param py number
---@param scale number
---@param page_size Geom|nil
---@return Geom scaled_rect
function BubbleZoom:scaleRectAtPoint(rect, px, py, scale, page_size)
    local rel_x = px - rect.x
    local rel_y = py - rect.y
    local new_w = rect.w * scale
    local new_h = rect.h * scale
    local new_x = px - (rel_x * scale)
    local new_y = py - (rel_y * scale)
    if page_size then
        if new_w > page_size.w then
            new_w = page_size.w
            new_x = 0
        else
            if new_x < 0 then new_x = 0 end
            if new_x + new_w > page_size.w then
                new_x = page_size.w - new_w
            end
        end
        if new_h > page_size.h then
            new_h = page_size.h
            new_y = 0
        else
            if new_y < 0 then new_y = 0 end
            if new_y + new_h > page_size.h then
                new_y = page_size.h - new_h
            end
        end
    end
    return Geom:new{
        x = new_x,
        y = new_y,
        w = new_w,
        h = new_h,
    }
end

---Stores overlay rects for rendering and schedules a repaint; used by onBubbleGesture.
---@param pageno number
---@param rect Geom
---@param tap_x number
---@param tap_y number
---@return boolean handled
function BubbleZoom:showOverlayRect(pageno, rect, tap_x, tap_y)
    if rect.w <= 0 or rect.h <= 0 then
        return false
    end
    local rotation = self.view and self.view.state and self.view.state.rotation or 0
    local page_size = self.document:getPageDimensions(pageno, 1.0, rotation)
    local padded = self:padRect(rect, page_size)
    local scale = self.overlay_scale
    if page_size then
        local max_scale_x = page_size.w / padded.w
        local max_scale_y = page_size.h / padded.h
        local max_scale = math.min(max_scale_x, max_scale_y)
        if max_scale < scale then
            scale = max_scale
        end
    end

    local scaled = self:scaleRectAtPoint(padded, tap_x, tap_y, scale, page_size)
    self.overlay_src_rect = padded
    self.overlay_rect = scaled
    self.overlay_page = pageno
    self.overlay_scale_active = scale
    UIManager:setDirty(self.ui.dialog, "partial")
    return true
end

---Adds padding to a rect and clamps to page bounds; used by showOverlayRect.
---@param rect Geom
---@param page_size Geom|nil
---@return Geom padded_rect
function BubbleZoom:padRect(rect, page_size)
    local pad_x = rect.w * self.padding_ratio
    local pad_y = rect.h * self.padding_ratio
    local padded = Geom:new{
        x = rect.x - pad_x,
        y = rect.y - pad_y,
        w = rect.w + (2 * pad_x),
        h = rect.h + (2 * pad_y),
    }
    if page_size then
        if padded.x < 0 then padded.x = 0 end
        if padded.y < 0 then padded.y = 0 end
        if padded.x + padded.w > page_size.w then
            padded.w = page_size.w - padded.x
        end
        if padded.y + padded.h > page_size.h then
            padded.h = page_size.h - padded.y
        end
    end
    return padded
end

return BubbleZoom
