local Device = require("device")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")
local SpinWidget = require("ui/widget/spinwidget")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local time = require("ui/time")
local bit = require("bit")
local ffi = require("ffi")
local util = require("util")
local Blitbuffer = require("ffi/blitbuffer")
local _ = require("gettext")
local T = require("ffi/util").template
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local math_sqrt = math.sqrt
local tonumber_local = tonumber
local bit_rshift = bit.rshift

-- GC every few cache drops.
local GC_EVERY = 5
local gc_count = 0
local DEBUG_TIMING = false
local FULL_SHAPE_ENABLED_DEFAULT = false
local SCANLINE_OUTLINE_WIDTH_DEFAULT = 2
local SCANLINE_OUTLINE_WIDTH_MIN = 0
local SCANLINE_OUTLINE_WIDTH_MAX = 6
local SAUVOLA_DOWNSAMPLE_MAX_WIDTH_DEFAULT = 1600
local SAUVOLA_DOWNSAMPLE_MAX_WIDTH_MIN = 0
local SAUVOLA_DOWNSAMPLE_MAX_WIDTH_MAX = 4096
local SAUVOLA_DOWNSAMPLE_ENABLED_DEFAULT = true

---Queue-based flood fill (current default); returns filled count, bounds, and optional mask.
local function floodFillQueue(bx, by, width, height, mask, pixel_count, closed, roi, need_mask)
    local function isWhite(x, y)
        if closed
            and x >= roi.x1 and x <= roi.x2
            and y >= roi.y1 and y <= roi.y2 then
            local rindex = (y - roi.y1) * roi.w + (x - roi.x1)
            return closed[rindex] == 255
        end
        return mask[y * width + x] == 255
    end

    local queue = ffi.new("struct { uint16_t x; uint16_t y; }[?]", pixel_count)
    local head = 0
    local tail = 0
    queue[0].x = bx
    queue[0].y = by

    local visited = ffi.new("uint8_t[?]", pixel_count)
    local min_x, max_x = bx, bx
    local min_y, max_y = by, by
    local filled = 0
    local start_index = by * width + bx
    if need_mask and not isWhite(bx, by) then
        return 0, bx, bx, by, by, nil
    end
    visited[start_index] = 1

    while head <= tail do
        local x = queue[head].x
        local y = queue[head].y
        head = head + 1
        local index = y * width + x
        local is_white = isWhite(x, y)
        if is_white then
            filled = filled + 1
            if x < min_x then min_x = x end
            if x > max_x then max_x = x end
            if y < min_y then min_y = y end
            if y > max_y then max_y = y end

            if x > 0 then
                local nindex = index - 1
                if visited[nindex] == 0 and (not need_mask or isWhite(x - 1, y)) then
                    visited[nindex] = 1
                    tail = tail + 1
                    queue[tail].x = x - 1
                    queue[tail].y = y
                end
            end
            if x < width - 1 then
                local nindex = index + 1
                if visited[nindex] == 0 and (not need_mask or isWhite(x + 1, y)) then
                    visited[nindex] = 1
                    tail = tail + 1
                    queue[tail].x = x + 1
                    queue[tail].y = y
                end
            end
            if y > 0 then
                local nindex = index - width
                if visited[nindex] == 0 and (not need_mask or isWhite(x, y - 1)) then
                    visited[nindex] = 1
                    tail = tail + 1
                    queue[tail].x = x
                    queue[tail].y = y - 1
                end
            end
            if y < height - 1 then
                local nindex = index + width
                if visited[nindex] == 0 and (not need_mask or isWhite(x, y + 1)) then
                    visited[nindex] = 1
                    tail = tail + 1
                    queue[tail].x = x
                    queue[tail].y = y + 1
                end
            end
        end
    end

    if not need_mask then
        return filled, min_x, max_x, min_y, max_y
    end
    if filled == 0 then
        return 0, bx, bx, by, by, nil
    end
    return filled, min_x, max_x, min_y, max_y, visited
end

---Scanline flood fill; returns filled, bounds, and optional visited mask.
local function floodFillScanline(bx, by, width, height, mask, pixel_count, closed, roi, need_mask)
    local function isWhite(x, y)
        if closed
            and x >= roi.x1 and x <= roi.x2
            and y >= roi.y1 and y <= roi.y2 then
            local rindex = (y - roi.y1) * roi.w + (x - roi.x1)
            return closed[rindex] == 255
        end
        return mask[y * width + x] == 255
    end

    local visited = ffi.new("uint8_t[?]", pixel_count)
    local stack = ffi.new("struct { uint16_t x; uint16_t y; }[?]", pixel_count)
    local head = 0
    local tail = 0
    stack[0].x = bx
    stack[0].y = by

    local filled = 0
    local min_x, max_x = bx, bx
    local min_y, max_y = by, by

    while head <= tail do
        local x = stack[head].x
        local y = stack[head].y
        head = head + 1

        local index = y * width + x
        if visited[index] ~= 0 or not isWhite(x, y) then
            goto continue
        end

        local left = x
        while left > 0 do
            local li = y * width + (left - 1)
            if visited[li] ~= 0 or not isWhite(left - 1, y) then
                break
            end
            left = left - 1
        end

        local right = x
        while right < width - 1 do
            local ri = y * width + (right + 1)
            if visited[ri] ~= 0 or not isWhite(right + 1, y) then
                break
            end
            right = right + 1
        end

        local row_index = y * width + left
        for xi = left, right do
            visited[row_index] = 1
            row_index = row_index + 1
        end

        filled = filled + (right - left + 1)
        if left < min_x then min_x = left end
        if right > max_x then max_x = right end
        if y < min_y then min_y = y end
        if y > max_y then max_y = y end

        local function scanNeighbor(ny)
            if ny < 0 or ny >= height then
                return
            end
            local xi = left
            while xi <= right do
                local ni = ny * width + xi
                if visited[ni] == 0 and isWhite(xi, ny) then
                    tail = tail + 1
                    stack[tail].x = xi
                    stack[tail].y = ny
                    xi = xi + 1
                    while xi <= right do
                        local nni = ny * width + xi
                        if visited[nni] ~= 0 or not isWhite(xi, ny) then
                            break
                        end
                        xi = xi + 1
                    end
                end
                xi = xi + 1
            end
        end

        scanNeighbor(y - 1)
        scanNeighbor(y + 1)

        ::continue::
    end

    if filled == 0 then
        return 0, bx, bx, by, by, nil
    end
    if not need_mask then
        return filled, min_x, max_x, min_y, max_y, nil
    end
    local visited_copy = ffi.new("uint8_t[?]", pixel_count)
    ffi.copy(visited_copy, visited, pixel_count)
    return filled, min_x, max_x, min_y, max_y, visited_copy
end

local function blitMaskRegionScaled(dest_bb, src_bb, dest_x, dest_y, region_mask, region_w, region_h, outline_color, outline_width)
    if not region_mask then
        return
    end
    local src_w = src_bb:getWidth()
    local src_h = src_bb:getHeight()
    local dest_w = dest_bb:getWidth()
    local dest_h = dest_bb:getHeight()

    for sy = 0, src_h - 1 do
        local dy = dest_y + sy
        if dy >= 0 and dy < dest_h then
            local ry = math_floor(sy * region_h / src_h)
            for sx = 0, src_w - 1 do
                local dx = dest_x + sx
                if dx >= 0 and dx < dest_w then
                    local rx = math_floor(sx * region_w / src_w)
                    if region_mask[ry * region_w + rx] ~= 0 then
                        dest_bb:setPixel(dx, dy, src_bb:getPixel(sx, sy))
                    end
                end
            end
        end
    end
    if outline_color and outline_width > 0 then
        for sy = 0, src_h - 1 do
            local dy = dest_y + sy
            if dy >= 0 and dy < dest_h then
                local ry = math_floor(sy * region_h / src_h)
                for sx = 0, src_w - 1 do
                    local dx = dest_x + sx
                    if dx >= 0 and dx < dest_w then
                        local rx = math_floor(sx * region_w / src_w)
                        local idx = ry * region_w + rx
                        if region_mask[idx] ~= 0 then
                            local is_edge = false
                            for oy = -outline_width, outline_width do
                                local ny = ry + oy
                                if ny < 0 or ny >= region_h then
                                    is_edge = true
                                    break
                                end
                                local base = ny * region_w
                                for ox = -outline_width, outline_width do
                                    local nx = rx + ox
                                    if nx < 0 or nx >= region_w then
                                        is_edge = true
                                        break
                                    end
                                    if region_mask[base + nx] == 0 then
                                        is_edge = true
                                        break
                                    end
                                end
                                if is_edge then break end
                            end
                            if is_edge then
                                dest_bb:setPixel(dx, dy, outline_color)
                            end
                        end
                    end
                end
            end
        end
    end
end

local function fillEnclosedHoles(mask_region, region_w, region_h)
    local size = region_w * region_h
    local visited = ffi.new("uint8_t[?]", size)
    local queue = ffi.new("int32_t[?]", size)
    for y = 0, region_h - 1 do
        local row = y * region_w
        for x = 0, region_w - 1 do
            local idx = row + x
            if mask_region[idx] == 0 and visited[idx] == 0 then
                local head = 0
                local tail = 0
                queue[0] = idx
                visited[idx] = 1
                local touches_border = (x == 0 or y == 0 or x == region_w - 1 or y == region_h - 1)
                while head <= tail do
                    local cur = queue[head]
                    head = head + 1
                    local cy = math_floor(cur / region_w)
                    local cx = cur - cy * region_w
                    if cx > 0 then
                        local ni = cur - 1
                        if mask_region[ni] == 0 and visited[ni] == 0 then
                            visited[ni] = 1
                            tail = tail + 1
                            queue[tail] = ni
                        end
                    else
                        touches_border = true
                    end
                    if cx < region_w - 1 then
                        local ni = cur + 1
                        if mask_region[ni] == 0 and visited[ni] == 0 then
                            visited[ni] = 1
                            tail = tail + 1
                            queue[tail] = ni
                        end
                    else
                        touches_border = true
                    end
                    if cy > 0 then
                        local ni = cur - region_w
                        if mask_region[ni] == 0 and visited[ni] == 0 then
                            visited[ni] = 1
                            tail = tail + 1
                            queue[tail] = ni
                        end
                    else
                        touches_border = true
                    end
                    if cy < region_h - 1 then
                        local ni = cur + region_w
                        if mask_region[ni] == 0 and visited[ni] == 0 then
                            visited[ni] = 1
                            tail = tail + 1
                            queue[tail] = ni
                        end
                    else
                        touches_border = true
                    end
                end
                if not touches_border then
                    for i = 0, tail do
                        mask_region[queue[i]] = 1
                    end
                end
            end
        end
    end
end

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
    local rx = math_floor(screen_rect.x + 0.5)
    local ry = math_floor(screen_rect.y + 0.5)
    local rw = math_floor(screen_rect.w + 0.5)
    local rh = math_floor(screen_rect.h + 0.5)
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
    if owner.overlay_mask_region and rotation == 0 then
        local tmp_bb = Blitbuffer.new(rw, rh, bb:getType())
        owner.document:drawPage(tmp_bb, 0, 0, rect_scaled, owner.overlay_page, zoom, rotation, gamma)
    local outline_width = owner.scanline_outline_width or SCANLINE_OUTLINE_WIDTH_DEFAULT
    local outline = outline_width > 0 and Blitbuffer.COLOR_BLACK or nil
    blitMaskRegionScaled(bb, tmp_bb, rx, ry, owner.overlay_mask_region, owner.overlay_mask_region_w, owner.overlay_mask_region_h, outline, outline_width)
    tmp_bb:free()
    else
        owner.document:drawPage(bb, rx, ry, rect_scaled, owner.overlay_page, zoom, rotation, gamma)
    end

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
    sauvola_downsample_max_width = SAUVOLA_DOWNSAMPLE_MAX_WIDTH_DEFAULT,
    sauvola_downsample_enabled = SAUVOLA_DOWNSAMPLE_ENABLED_DEFAULT,
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
    overlay_mask = nil,
    overlay_mask_w = nil,
    overlay_mask_h = nil,
    overlay_mask_rect = nil,
    overlay_mask_region = nil,
    overlay_mask_region_w = nil,
    overlay_mask_region_h = nil,
    overlay_tap_x = nil,
    overlay_tap_y = nil,
    overlay = nil,
    sauvola_cache = nil,
    use_custom_contrast = false,
    custom_contrast = 2.0,
    use_full_shape = FULL_SHAPE_ENABLED_DEFAULT,
    use_scanline_floodfill = false,
    scanline_outline_width = SCANLINE_OUTLINE_WIDTH_DEFAULT,
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
    self.sauvola_downsample_max_width = G_reader_settings:readSetting("bubblezoom_sauvola_downsample_max_width", SAUVOLA_DOWNSAMPLE_MAX_WIDTH_DEFAULT)
    self.sauvola_downsample_enabled = G_reader_settings:readSetting("bubblezoom_sauvola_downsample_enabled", SAUVOLA_DOWNSAMPLE_ENABLED_DEFAULT)
    self.filled_cutoff = G_reader_settings:readSetting("bubblezoom_filled_cutoff", 200)
    self.closing_radius = G_reader_settings:readSetting("bubblezoom_closing_radius", 1)
    self.closing_margin = G_reader_settings:readSetting("bubblezoom_closing_margin", 6)
    self.max_roi = G_reader_settings:readSetting("bubblezoom_max_roi", 96)
    self.use_custom_contrast = G_reader_settings:readSetting("bubblezoom_use_custom_contrast", false)
    self.custom_contrast = G_reader_settings:readSetting("bubblezoom_custom_contrast", 2.0)
    self.use_full_shape = G_reader_settings:readSetting("bubblezoom_use_full_shape", FULL_SHAPE_ENABLED_DEFAULT)
    self.use_scanline_floodfill = G_reader_settings:readSetting("bubblezoom_use_scanline_floodfill", false)
    self.scanline_outline_width = G_reader_settings:readSetting("bubblezoom_scanline_outline_width", SCANLINE_OUTLINE_WIDTH_DEFAULT)
    if self.scanline_outline_width < SCANLINE_OUTLINE_WIDTH_MIN then self.scanline_outline_width = SCANLINE_OUTLINE_WIDTH_MIN end
    if self.scanline_outline_width > SCANLINE_OUTLINE_WIDTH_MAX then self.scanline_outline_width = SCANLINE_OUTLINE_WIDTH_MAX end
    if self.sauvola_downsample_max_width < SAUVOLA_DOWNSAMPLE_MAX_WIDTH_MIN then
        self.sauvola_downsample_max_width = SAUVOLA_DOWNSAMPLE_MAX_WIDTH_MIN
    end
    if self.sauvola_downsample_max_width > SAUVOLA_DOWNSAMPLE_MAX_WIDTH_MAX then
        self.sauvola_downsample_max_width = SAUVOLA_DOWNSAMPLE_MAX_WIDTH_MAX
    end
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
    self.overlay_mask = nil
    self.overlay_mask_w = nil
    self.overlay_mask_h = nil
    self.overlay_mask_rect = nil
    self.overlay_mask_region = nil
    self.overlay_mask_region_w = nil
    self.overlay_mask_region_h = nil
    self.overlay_tap_x = nil
    self.overlay_tap_y = nil
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
                text = _("Full Shape Extraction"),
                sub_item_table = {
                    {
                        text = _("Enable full shape extraction"),
                        checked_func = function() return self.use_full_shape end,
                        help_text = _("Uses a flood-fill mask to zoom the exact bubble shape instead of a bounding box. May be slower."),
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self.use_full_shape = not self.use_full_shape
                            G_reader_settings:saveSetting("bubblezoom_use_full_shape", self.use_full_shape)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    },
                    {
                        text_func = function()
                            return T(_("Outline width: %1 px"), self.scanline_outline_width)
                        end,
                        help_text = _("Thickness of the black outline drawn around the bubble mask."),
                        keep_menu_open = true,
                        enabled_func = function() return self.use_full_shape end,
                        callback = function(touchmenu_instance)
                            local spin = SpinWidget:new{
                                title_text = _("Outline width"),
                                info_text = _("Thickness of the black outline drawn around the bubble mask."),
                                value = self.scanline_outline_width,
                                default_value = SCANLINE_OUTLINE_WIDTH_DEFAULT,
                                value_min = SCANLINE_OUTLINE_WIDTH_MIN,
                                value_max = SCANLINE_OUTLINE_WIDTH_MAX,
                                value_step = 1,
                                value_hold_step = 1,
                                precision = "%.0f",
                                callback = function(widget)
                                    self.scanline_outline_width = math_floor(widget.value)
                                    G_reader_settings:saveSetting("bubblezoom_scanline_outline_width", self.scanline_outline_width)
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
                                            local value = math_floor(widget.value)
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
                            {
                                text = _("Enable preprocess downsampling"),
                                checked_func = function() return self.sauvola_downsample_enabled end,
                                help_text = _("Use a lower-resolution render for Sauvola preprocessing on large pages to speed up preprocessing. Aggressive downsampling may reduce bubble detection accuracy."),
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self.sauvola_downsample_enabled = not self.sauvola_downsample_enabled
                                    G_reader_settings:saveSetting("bubblezoom_sauvola_downsample_enabled", self.sauvola_downsample_enabled)
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            },
                            {
                                text_func = function()
                                    return T(_("Preprocess max width: %1 px"), self.sauvola_downsample_max_width)
                                end,
                                help_text = _("When downsampling is enabled, pages wider than this use a downsampled render for preprocessing."),
                                keep_menu_open = true,
                                enabled_func = function() return self.sauvola_downsample_enabled end,
                                callback = function(touchmenu_instance)
                                    local spin = SpinWidget:new{
                                        title_text = _("Preprocess max width"),
                                        info_text = _("When downsampling is enabled, pages wider than this use a downsampled render for preprocessing."),
                                        value = self.sauvola_downsample_max_width,
                                        default_value = SAUVOLA_DOWNSAMPLE_MAX_WIDTH_DEFAULT,
                                        value_min = SAUVOLA_DOWNSAMPLE_MAX_WIDTH_MIN,
                                        value_max = SAUVOLA_DOWNSAMPLE_MAX_WIDTH_MAX,
                                        value_step = 50,
                                        value_hold_step = 200,
                                        precision = "%.0f",
                                        callback = function(widget)
                                            local value = math_floor(widget.value)
                                            if value < SAUVOLA_DOWNSAMPLE_MAX_WIDTH_MIN then value = SAUVOLA_DOWNSAMPLE_MAX_WIDTH_MIN end
                                            if value > SAUVOLA_DOWNSAMPLE_MAX_WIDTH_MAX then value = SAUVOLA_DOWNSAMPLE_MAX_WIDTH_MAX end
                                            self.sauvola_downsample_max_width = value
                                            G_reader_settings:saveSetting("bubblezoom_sauvola_downsample_max_width", value)
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
                        text = _("Scanline Flood Fill"),
                        checked_func = function() return self.use_scanline_floodfill end,
                        help_text = _("Uses a scanline-based flood fill algorithm. Can be faster than the default queue method on some devices."),
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self.use_scanline_floodfill = not self.use_scanline_floodfill
                            G_reader_settings:saveSetting("bubblezoom_use_scanline_floodfill", self.use_scanline_floodfill)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
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
                                            local value = math_floor(widget.value)
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
                                            local value = math_floor(widget.value)
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
                                            local value = math_floor(widget.value)
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
                                    local value = math_floor(widget.value)
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
                            self.sauvola_downsample_max_width = SAUVOLA_DOWNSAMPLE_MAX_WIDTH_DEFAULT
                            self.sauvola_downsample_enabled = SAUVOLA_DOWNSAMPLE_ENABLED_DEFAULT
                            self.filled_cutoff = 200
                            self.closing_radius = 1
                            self.closing_margin = 6
                            self.max_roi = 96
                            self.padding_ratio = 0.01
                            self.use_custom_contrast = false
                            self.custom_contrast = 2.0
                            self.use_scanline_floodfill = false
                            self.scanline_outline_width = SCANLINE_OUTLINE_WIDTH_DEFAULT
                            G_reader_settings:saveSetting("bubblezoom_sauvola_window_size", 31)
                            G_reader_settings:saveSetting("bubblezoom_sauvola_k", 0.35)
                            G_reader_settings:saveSetting("bubblezoom_sauvola_r", 128.0)
                            G_reader_settings:saveSetting("bubblezoom_sauvola_downsample_max_width", SAUVOLA_DOWNSAMPLE_MAX_WIDTH_DEFAULT)
                            G_reader_settings:saveSetting("bubblezoom_sauvola_downsample_enabled", SAUVOLA_DOWNSAMPLE_ENABLED_DEFAULT)
                            G_reader_settings:saveSetting("bubblezoom_filled_cutoff", 200)
                            G_reader_settings:saveSetting("bubblezoom_closing_radius", 1)
                            G_reader_settings:saveSetting("bubblezoom_closing_margin", 6)
                            G_reader_settings:saveSetting("bubblezoom_max_roi", 96)
                            G_reader_settings:saveSetting("bubblezoom_padding_ratio", 0.01)
                            G_reader_settings:saveSetting("bubblezoom_use_custom_contrast", false)
                            G_reader_settings:saveSetting("bubblezoom_custom_contrast", 2.0)
                            G_reader_settings:saveSetting("bubblezoom_use_scanline_floodfill", false)
                            G_reader_settings:saveSetting("bubblezoom_scanline_outline_width", SCANLINE_OUTLINE_WIDTH_DEFAULT)
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
        self.overlay_mask = nil
        self.overlay_mask_w = nil
        self.overlay_mask_h = nil
        self.overlay_mask_rect = nil
        self.overlay_mask_region = nil
        self.overlay_mask_region_w = nil
        self.overlay_mask_region_h = nil
        self.overlay_tap_x = nil
        self.overlay_tap_y = nil
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

    local rect, visited_mask = self:detectBubbleRect(pos.page, pos.x, pos.y)
    if not rect then
        if consume_on_miss then
            self.hold_consumed = true
            self.overlay_rect = nil
            self.overlay_src_rect = nil
            self.overlay_page = nil
            self.overlay_scale_active = nil
            self.overlay_mask = nil
            self.overlay_mask_w = nil
            self.overlay_mask_h = nil
            self.overlay_mask_rect = nil
            self.overlay_mask_region = nil
            self.overlay_mask_region_w = nil
            self.overlay_mask_region_h = nil
            self.overlay_tap_x = nil
            self.overlay_tap_y = nil
            UIManager:setDirty(self.ui.dialog, "partial")
        end
        UIManager:show(Notification:new{
            text = _("No bubble found"),
        })
        return true
    end

    local handled = self:showOverlayRect(pos.page, rect, pos.x, pos.y, visited_mask)
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
    local window_size = tonumber_local(self.sauvola_window_size) or 31
    if window_size < 3 then window_size = 3 end
    if window_size % 2 == 0 then window_size = window_size + 1 end
    local sauvola_k = tonumber_local(self.sauvola_k) or 0.35
    local sauvola_r = tonumber_local(self.sauvola_r) or 128.0
    if sauvola_r <= 0 then sauvola_r = 128.0 end

    local max_width = tonumber_local(self.sauvola_downsample_max_width) or SAUVOLA_DOWNSAMPLE_MAX_WIDTH_DEFAULT
    if max_width < SAUVOLA_DOWNSAMPLE_MAX_WIDTH_MIN then max_width = SAUVOLA_DOWNSAMPLE_MAX_WIDTH_MIN end
    if max_width > SAUVOLA_DOWNSAMPLE_MAX_WIDTH_MAX then max_width = SAUVOLA_DOWNSAMPLE_MAX_WIDTH_MAX end
    if max_width <= 0 then max_width = SAUVOLA_DOWNSAMPLE_MAX_WIDTH_DEFAULT end
    local page_size = self.document:getPageDimensions(pageno, 1.0, rotation)
    local render_scale = 1.0
    local naive_scale = 1.0
    if page_size and page_size.w and page_size.w > 0 then
        naive_scale = max_width / page_size.w
        if naive_scale > 1.0 then naive_scale = 1.0 end
    end
    if self.sauvola_downsample_enabled and page_size and page_size.w and page_size.h and page_size.w > 0 and page_size.h > 0 then
        local width_scale = 1.0
        if page_size.w > max_width then
            width_scale = max_width / page_size.w
        end
        local target_pixels = max_width * max_width
        local area_scale = math_sqrt(target_pixels / (page_size.w * page_size.h))
        if area_scale > 1.0 then area_scale = 1.0 end
        render_scale = math_min(width_scale, area_scale)
    end
    local cache = self.sauvola_cache
    if cache
        and cache.page == pageno
        and cache.rotation == rotation
        and cache.gamma == gamma
        and cache.window_size == window_size
        and cache.k == sauvola_k
        and cache.r == sauvola_r
        and cache.scale == render_scale then
        return cache
    end

    local tile = self.document:renderPage(pageno, nil, render_scale, rotation, gamma, true)
    if not tile or not tile.bb then
        return nil
    end

    local bb = tile.bb
    local width = bb:getWidth()
    local height = bb:getHeight()
    if width <= 0 or height <= 0 then
        return nil
    end
    local prep_start
    if DEBUG_TIMING then
        prep_start = time.now()
    end
    local pixel_count = width * height
    local luma = ffi.new("uint8_t[?]", pixel_count)
    local bbdump, src_ptr, src_stride
    local buffer_mode
    local bb_type = bb:getType()
    local bb_rotation = bb:getRotation()
    local bb_inverse = bb:getInverse()
    if bb_type == Blitbuffer.TYPE_BBRGB24 and bb_rotation == 0 and bb_inverse == 0 then
        src_ptr = ffi.cast("uint8_t*", bb.data)
        src_stride = bb.stride
        buffer_mode = "direct"
    elseif bb_type == Blitbuffer.TYPE_BBRGB24 then
        bbdump = Blitbuffer.new(width, height, Blitbuffer.TYPE_BBRGB24)
        bbdump:blitFrom(bb)
        src_ptr = ffi.cast("uint8_t*", bbdump.data)
        src_stride = bbdump.stride
        buffer_mode = "blit"
    else
        local src_w
        bbdump, src_ptr, src_w, src_stride = bb:getBufferData()
        buffer_mode = "convert"
    end
    local idx = 0
    for y = 0, height - 1 do
        local row = src_ptr + y * src_stride
        for x = 0, width - 1 do
            local px = row + x * 3
            luma[idx] = bit_rshift(77 * px[0] + 150 * px[1] + 29 * px[2], 8)
            idx = idx + 1
        end
    end
    if bbdump then
        bbdump:free()
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
    local window_half = math_floor(window_size / 2)
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
            local sum = tonumber_local(integral[d] + integral[a] - integral[b] - integral[c])
            local sum_sq = tonumber_local(integral_sq[d] + integral_sq[a] - integral_sq[b] - integral_sq[c])

            local mean = sum / area
            local variance = (sum_sq / area) - (mean * mean)
            local std_dev = variance > 0 and math_sqrt(variance) or 0
            local threshold = mean * (1 + sauvola_k * ((std_dev / sauvola_r) - 1))

            local index = row_idx + x
            if luma[index] > threshold then
                mask[index] = 255
            else
                mask[index] = 0
            end
        end
    end
    if DEBUG_TIMING then
        local orig_w = page_size and page_size.w or 0
        local orig_h = page_size and page_size.h or 0
        logger.dbg(string.format("bubblezoom sauvola prep: %.3f ms (%s, orig %dx%d, %dx%d, scale %.3f, naive %.3f)",
            time.to_ms(time.since(prep_start)), buffer_mode, orig_w, orig_h, width, height, render_scale, naive_scale))
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
        scale = render_scale,
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
    local custom = tonumber_local(self.custom_contrast) or gamma
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
    local mask_scale = cache.scale or 1.0
    if width <= 0 or height <= 0 then
        return nil
    end
    if width > 65535 or height > 65535 then
        return nil
    end

    local mask = cache.mask

    local bx = math_floor(tap_x * mask_scale + 0.5)
    local by = math_floor(tap_y * mask_scale + 0.5)
    if bx < 0 or by < 0 or bx >= width or by >= height then
        return nil
    end

    local pixel_count = width * height

    local use_scanline = self.use_scanline_floodfill
    local use_full_shape = self.use_full_shape
    ---Flood-fills from the tap using an optional closed mask; used by detectBubbleRect.
    ---@param closed userdata|nil
    ---@param roi table|nil
    ---@return number filled
    ---@return number min_x
    ---@return number max_x
    ---@return number min_y
    ---@return number max_y
    ---@return userdata|nil visited_mask
    local function runFloodFill(closed, roi)
        if use_scanline then
            return floodFillScanline(bx, by, width, height, mask, pixel_count, closed, roi, use_full_shape)
        end
        return floodFillQueue(bx, by, width, height, mask, pixel_count, closed, roi, use_full_shape)
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

    local flood_start
    if DEBUG_TIMING then
        flood_start = time.now()
    end
    local filled, min_x, max_x, min_y, max_y, visited_mask = runFloodFill(nil, nil)
    if DEBUG_TIMING then
        logger.dbg(string.format("bubblezoom floodfill: %.3f ms (initial)",
            time.to_ms(time.since(flood_start))))
    end
    local cutoff = tonumber_local(self.filled_cutoff) or 200

    if filled <= cutoff then
        -- Apply closing to escape closed section.
        local closing_radius = tonumber_local(self.closing_radius) or 1
        if closing_radius < 0 then closing_radius = 0 end
        local closing_margin = tonumber_local(self.closing_margin) or 3
        if closing_margin < 0 then closing_margin = 0 end
        local roi_x1 = math_max(0, min_x - closing_margin)
        local roi_y1 = math_max(0, min_y - closing_margin)
        local roi_x2 = math_min(width - 1, max_x + closing_margin)
        local roi_y2 = math_min(height - 1, max_y + closing_margin)

        local max_roi = tonumber_local(self.max_roi) or 96
        if max_roi < 16 then max_roi = 16 end
        local roi_w = roi_x2 - roi_x1 + 1
        local roi_h = roi_y2 - roi_y1 + 1
        if roi_w > max_roi then
            local half = math_floor(max_roi / 2)
            roi_x1 = bx - half
            roi_x2 = roi_x1 + max_roi - 1
            if roi_x1 < 0 then
                roi_x1 = 0
                roi_x2 = math_min(width - 1, max_roi - 1)
            elseif roi_x2 >= width then
                roi_x2 = width - 1
                roi_x1 = math_max(0, roi_x2 - max_roi + 1)
            end
        end
        if roi_h > max_roi then
            local half = math_floor(max_roi / 2)
            roi_y1 = by - half
            roi_y2 = roi_y1 + max_roi - 1
            if roi_y1 < 0 then
                roi_y1 = 0
                roi_y2 = math_min(height - 1, max_roi - 1)
            elseif roi_y2 >= height then
                roi_y2 = height - 1
                roi_y1 = math_max(0, roi_y2 - max_roi + 1)
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
            if DEBUG_TIMING then
                flood_start = time.now()
            end
            filled, min_x, max_x, min_y, max_y, visited_mask = runFloodFill(closed, roi)
            if DEBUG_TIMING then
                logger.dbg(string.format("bubblezoom floodfill: %.3f ms (closed)",
                    time.to_ms(time.since(flood_start))))
            end
        end
    end

    -- Possibly a false positive, like the inside of an "o"
    if filled <= cutoff then
        return nil
    end

    local rect_min_x, rect_max_x, rect_min_y, rect_max_y = min_x, max_x, min_y, max_y
    if mask_scale ~= 1.0 then
        local inv = 1.0 / mask_scale
        rect_min_x = math_floor(rect_min_x * inv)
        rect_min_y = math_floor(rect_min_y * inv)
        rect_max_x = math_floor((rect_max_x + 1) * inv - 1)
        rect_max_y = math_floor((rect_max_y + 1) * inv - 1)
    end

    local rect = Geom:new{
        x = rect_min_x,
        y = rect_min_y,
        w = (rect_max_x - rect_min_x + 1),
        h = (rect_max_y - rect_min_y + 1),
    }
    if use_full_shape then
        return rect, visited_mask
    end
    return rect, nil
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
---@param visited_mask userdata|nil
---@return boolean handled
function BubbleZoom:showOverlayRect(pageno, rect, tap_x, tap_y, visited_mask)
    if rect.w <= 0 or rect.h <= 0 then
        return false
    end
    local rotation = self.view and self.view.state and self.view.state.rotation or 0
    local page_size = self.document:getPageDimensions(pageno, 1.0, rotation)
    local use_shape = self.use_full_shape and visited_mask ~= nil
    local padded = rect
    if not use_shape then
        padded = self:padRect(rect, page_size)
    end
    local scale = self.overlay_scale
    if page_size then
        local max_scale_x = page_size.w / padded.w
        local max_scale_y = page_size.h / padded.h
        local max_scale = math_min(max_scale_x, max_scale_y)
        if max_scale < scale then
            scale = max_scale
        end
    end

    local scaled = self:scaleRectAtPoint(padded, tap_x, tap_y, scale, page_size)
    self.overlay_src_rect = padded
    self.overlay_rect = scaled
    self.overlay_page = pageno
    self.overlay_scale_active = scale
    self.overlay_mask = use_shape and visited_mask or nil
    self.overlay_mask_rect = use_shape and rect or nil
    if use_shape then
        self.overlay_mask_w = self.sauvola_cache and self.sauvola_cache.width or nil
        self.overlay_mask_h = self.sauvola_cache and self.sauvola_cache.height or nil
    else
        self.overlay_mask_w = nil
        self.overlay_mask_h = nil
    end
    if use_shape then
        local region_w = rect.w
        local region_h = rect.h
        local mask_region = ffi.new("uint8_t[?]", region_w * region_h)
        local page_w = self.overlay_mask_w
        local page_h = self.overlay_mask_h
        local mask_scale = self.sauvola_cache and self.sauvola_cache.scale or 1.0
        if mask_scale == 1.0 then
            for ry = 0, region_h - 1 do
                local py = rect.y + ry
                local src_row = py * page_w
                local dst_row = ry * region_w
                for rx = 0, region_w - 1 do
                    local px = rect.x + rx
                    mask_region[dst_row + rx] = visited_mask[src_row + px]
                end
            end
        else
            for ry = 0, region_h - 1 do
                local py = rect.y + ry
                local my = math_floor(py * mask_scale)
                if my < 0 then my = 0 end
                if my >= page_h then my = page_h - 1 end
                local src_row = my * page_w
                local dst_row = ry * region_w
                for rx = 0, region_w - 1 do
                    local px = rect.x + rx
                    local mx = math_floor(px * mask_scale)
                    if mx < 0 then mx = 0 end
                    if mx >= page_w then mx = page_w - 1 end
                    mask_region[dst_row + rx] = visited_mask[src_row + mx]
                end
            end
        end
        fillEnclosedHoles(mask_region, region_w, region_h)
        self.overlay_mask_region = mask_region
        self.overlay_mask_region_w = region_w
        self.overlay_mask_region_h = region_h
    else
        self.overlay_mask_region = nil
        self.overlay_mask_region_w = nil
        self.overlay_mask_region_h = nil
    end
    self.overlay_tap_x = tap_x
    self.overlay_tap_y = tap_y
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
