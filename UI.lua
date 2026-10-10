-- Chair Legacy: UI.lua
-- The window. Zones down the left with how much of each is uncovered; on the
-- right the chosen zone's own map, drawn with the parts this character has
-- uncovered (the rest stays in fog, as on the world map), a marker on every
-- area still to find, the route through them as a line, and you.
--
-- Click a marker to go there next. Start or stop the route under the map.
-- The map art is read from the client (C_Map art layers and the uncovered
-- overlays) and drawn on our own textures; no Blizzard frame is touched.

local _, ns = ...

local W, H = 900, 590
local LIST_W = 250
local MAP_W, MAP_H = 600, 400
local ROW_H = 38
local GREEN, GOLD, GRAY = "|cff55dd55", "|cffffd100", "|cff999999"

local frame, mapBox, scroll, listChild
local overallBar, autoBox, pinBox, contButtons
local zoneTitle, zoneInfo, nextInfo, routeButton, skipButton
local zoneRows = {}
local continent = 0
local selected            -- the zone shown on the right
local Refresh

-------------------------------------------------------------------------------
-- Small widgets
-------------------------------------------------------------------------------

local function Bar(parent, w, h)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetSize(w, h)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetMinMaxValues(0, 1)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.5)
    bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.text:SetPoint("CENTER")
    return bar
end

local function SetBar(bar, done, total)
    local f = total > 0 and done / total or 0
    bar:SetValue(f)
    if done == total then bar:SetStatusBarColor(0.25, 0.8, 0.3)
    else bar:SetStatusBarColor(0.95, 0.7, 0.15) end
end

local function Check(parent, label, tip, onClick)
    local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    c:SetSize(24, 24)
    c.label = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    c.label:SetPoint("LEFT", c, "RIGHT", 2, 1)
    c.label:SetText(label)
    c:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    c:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(label, 1, 1, 1)
        GameTooltip:AddLine(tip, 1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    c:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return c
end

-------------------------------------------------------------------------------
-- The zone list
-------------------------------------------------------------------------------

local function ZoneTooltip(owner, zone)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local d, t = ns.ZoneCounts(zone)
    GameTooltip:AddLine(zone.name, 1, 1, 1)
    if d == t then
        GameTooltip:AddLine("Fully explored.", 0.3, 0.9, 0.3)
    else
        GameTooltip:AddLine(string.format("%d of %d areas uncovered. Still to find:", d, t), 1, 0.82, 0)
        local left = ns.ZoneRemaining(zone)
        for i = 1, math.min(#left, 12) do GameTooltip:AddLine("  " .. left[i].name, 0.9, 0.9, 0.9) end
        if #left > 12 then GameTooltip:AddLine("  and " .. (#left - 12) .. " more", 0.6, 0.6, 0.6) end
    end
    GameTooltip:Show()
end

local function ZoneRow(i)
    local row = zoneRows[i]
    if row then return row end
    row = CreateFrame("Button", nil, listChild)
    row:SetSize(LIST_W - 26, ROW_H - 2)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(1, 1, 1, 0.05)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 0.82, 0, 0.12)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("TOPLEFT", 6, -5)
    row.name:SetJustifyH("LEFT")
    row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.count:SetPoint("TOPRIGHT", -6, -6)
    row.bar = Bar(row, LIST_W - 38, 5)
    row.bar:SetPoint("BOTTOMLEFT", 6, 6)
    row:SetScript("OnClick", function(self)
        selected = self.zone
        Refresh()
    end)
    row:SetScript("OnEnter", function(self) ZoneTooltip(self, self.zone) end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    zoneRows[i] = row
    return row
end

local function RefreshList()
    local here = ns.CurrentZone()
    local n = 0
    for _, zone in ipairs(ns.ZONES) do
        if zone.continent == continent then
            n = n + 1
            local row = ZoneRow(n)
            row.zone = zone
            local d, t = ns.ZoneCounts(zone)
            local tag = ""
            if zone == here then tag = " |cff66ccff(here)|r" end
            if ns.route and ns.route.zone == zone then tag = tag .. " |cff55dd55(route)|r" end
            row.name:SetText((d == t and GRAY or "") .. zone.name .. "|r" .. tag)
            row.count:SetText(d == t and (GREEN .. "Done|r") or (GOLD .. (t - d) .. " left|r"))
            SetBar(row.bar, d, t)
            if zone == selected then row.bg:SetColorTexture(1, 0.82, 0, 0.22)
            else row.bg:SetColorTexture(1, 1, 1, d == t and 0.02 or 0.06) end
            row:Show()
        end
    end
    for i = n + 1, #zoneRows do zoneRows[i]:Hide() end
    listChild:SetHeight(math.max(1, n * ROW_H))
    for _, b in ipairs(contButtons) do b:SetEnabled(b.continent ~= continent) end
end

-------------------------------------------------------------------------------
-- The map
-------------------------------------------------------------------------------

local tiles, overlays, pins, lines = {}, {}, {}, {}
local playerDot
local hasLines

local function Pool(list, used, make)
    local t = list[used]
    if not t then t = make() list[used] = t end
    t:Show()
    return t
end

-- The zone's map art: base tiles, then each uncovered overlay on top.
local function DrawArt(zone)
    for _, t in ipairs(tiles) do t:Hide() end
    for _, t in ipairs(overlays) do t:Hide() end
    local okL, layers = ns.Ask(ns.API("C_Map", "GetMapArtLayers"), zone.map)
    local layer = okL and type(layers) == "table" and layers[1]
    local lw = layer and ns.Num(layer.layerWidth) or 1002
    local tw = layer and ns.Num(layer.tileWidth) or 256
    local th = layer and ns.Num(layer.tileHeight) or 256
    local scale = MAP_W / lw
    local okT, files = ns.Ask(ns.API("C_Map", "GetMapArtLayerTextures"), zone.map, 1)
    if okT and type(files) == "table" then
        local cols = math.ceil(lw / tw)
        for i, file in ipairs(files) do
            local t = Pool(tiles, i, function() return mapBox:CreateTexture(nil, "BACKGROUND") end)
            t:SetTexture(file)
            t:SetSize(tw * scale, th * scale)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", ((i - 1) % cols) * tw * scale, -math.floor((i - 1) / cols) * th * scale)
        end
    end

    local okE, explored = ns.Ask(ns.API("C_MapExplorationInfo", "GetExploredMapTextures"), zone.map)
    if not (okE and type(explored) == "table") then return end
    local used = 0
    local TILE = 256
    for _, info in ipairs(explored) do
        local ids = info.fileDataIDs
        local wide, tall = ns.Num(info.numTexturesWide), ns.Num(info.numTexturesTall)
        local texW, texH = ns.Num(info.textureWidth), ns.Num(info.textureHeight)
        local ox, oy = ns.Num(info.offsetX), ns.Num(info.offsetY)
        if type(ids) == "table" and wide and tall and texW and texH and ox and oy and not info.isShownByMouseOver then
            for j = 1, tall do
                local ph, fh = TILE, TILE
                if j == tall then
                    ph = texH % TILE
                    if ph == 0 then ph = TILE end
                    fh = 16
                    while fh < ph do fh = fh * 2 end
                end
                for k = 1, wide do
                    local pw, fw = TILE, TILE
                    if k == wide then
                        pw = texW % TILE
                        if pw == 0 then pw = TILE end
                        fw = 16
                        while fw < pw do fw = fw * 2 end
                    end
                    local file = ids[(j - 1) * wide + k]
                    if file then
                        used = used + 1
                        local t = Pool(overlays, used, function() return mapBox:CreateTexture(nil, "BORDER") end)
                        t:SetTexture(file)
                        t:SetTexCoord(0, pw / fw, 0, ph / fh)
                        t:SetSize(pw * scale, ph * scale)
                        t:ClearAllPoints()
                        t:SetPoint("TOPLEFT", (ox + TILE * (k - 1)) * scale, -(oy + TILE * (j - 1)) * scale)
                    end
                end
            end
        end
    end
end

local function Pin(i)
    return Pool(pins, i, function()
        local p = CreateFrame("Button", nil, mapBox)
        p:SetFrameLevel(mapBox:GetFrameLevel() + 5)
        p.dot = p:CreateTexture(nil, "ARTWORK")
        p.dot:SetAllPoints()
        p.dot:SetTexture("Interface\\COMMON\\Indicator-Yellow")
        p.num = p:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        p.num:SetPoint("BOTTOM", p, "TOP", 0, -3)
        p:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.node.name, 1, 1, 1)
            local pt = ns.NodePoints(self.node)[1]
            GameTooltip:AddLine(string.format("%.1f, %.1f", pt[1] * 100, pt[2] * 100), 0.7, 0.7, 0.7)
            if self.done then
                GameTooltip:AddLine("Uncovered.", 0.3, 0.9, 0.3)
            else
                if self.node.rough then
                    GameTooltip:AddLine("Approximate spot: this area has no ground of its own.", 1, 0.5, 0.5, true)
                end
                GameTooltip:AddLine(self.order == 1 and "Your next stop." or "Click to go here next.", 1, 0.82, 0)
            end
            GameTooltip:Show()
        end)
        p:SetScript("OnLeave", function() GameTooltip:Hide() end)
        p:SetScript("OnClick", function(self)
            if not self.done then ns.RouteVia(selected, self.node) end
        end)
        return p
    end)
end

local function Line(i)
    return Pool(lines, i, function()
        local l = mapBox:CreateLine(nil, "ARTWORK")
        l:SetThickness(2)
        return l
    end)
end

local function Join(l, x1, y1, x2, y2, r, g, b, a)
    l:SetStartPoint("TOPLEFT", mapBox, x1 * MAP_W, -y1 * MAP_H)
    l:SetEndPoint("TOPLEFT", mapBox, x2 * MAP_W, -y2 * MAP_H)
    l:SetColorTexture(r, g, b, a)
end

-- The player on the shown map, and the leg from them to the first stop.
local function DrawPlayer()
    if not selected then return end
    local px, py = ns.PlayerOn(selected.map)
    local inside = px and px >= 0 and px <= 1 and py >= 0 and py <= 1
    playerDot:SetShown(inside and true or false)
    if inside then
        playerDot:ClearAllPoints()
        playerDot:SetPoint("CENTER", mapBox, "TOPLEFT", px * MAP_W, -py * MAP_H)
        local ok, facing = pcall(GetPlayerFacing)
        if ok and ns.Num(facing) and playerDot.SetRotation then pcall(playerDot.SetRotation, playerDot, facing) end
    end
    local first = lines[1]
    local stop = ns.CurrentStop()
    if hasLines and first and ns.route and ns.route.zone == selected and stop then
        if inside then
            first:Show()
            Join(first, px, py, stop.x, stop.y, 0.3, 1, 0.35, 0.9)
        else
            first:Hide()
        end
    end
end

local function DrawMap()
    for _, p in ipairs(pins) do p:Hide() end
    for _, l in ipairs(lines) do l:Hide() end
    if not selected then return end
    local zone = selected
    pcall(DrawArt, zone)

    local state = ns.ZoneState(zone).state
    local order = {}
    local routed = ns.route and ns.route.zone == zone
    if routed then
        for i, stop in ipairs(ns.route.stops) do order[stop.node] = { i = i, x = stop.x, y = stop.y } end
    end
    local n = 0
    for i, node in ipairs(zone.nodes) do
        n = n + 1
        local p = Pin(n)
        local done = state[i] == true
        local o = order[node]
        local pt = ns.NodePoints(node)[1]
        local x, y = o and o.x or pt[1], o and o.y or pt[2]
        p.node, p.done, p.order = node, done, o and o.i
        local size = done and 10 or (o and o.i == 1 and 22 or 16)
        p:SetSize(size, size)
        p:ClearAllPoints()
        p:SetPoint("CENTER", mapBox, "TOPLEFT", x * MAP_W, -y * MAP_H)
        if done then
            p.dot:SetVertexColor(0.3, 1, 0.3, 0.55)
            p.num:SetText("")
        elseif o and o.i == 1 then
            p.dot:SetVertexColor(0.3, 1, 0.35, 1)
            p.num:SetText(GREEN .. "1|r")
        else
            p.dot:SetVertexColor(node.rough and 1 or 1, node.rough and 0.5 or 0.9, node.rough and 0.4 or 0.3, 1)
            p.num:SetText(o and o.i or "")
        end
    end

    if routed and hasLines then
        local stops = ns.route.stops
        for i = 2, #stops do
            local l = Line(i)
            Join(l, stops[i - 1].x, stops[i - 1].y, stops[i].x, stops[i].y, 1, 0.82, 0.1, 0.75)
        end
        Line(1)
    end
    DrawPlayer()
end

-------------------------------------------------------------------------------
-- Under the map
-------------------------------------------------------------------------------

local function RefreshInfo()
    if not selected then
        zoneTitle:SetText("")
        zoneInfo:SetText("Pick a zone on the left.")
        nextInfo:SetText("")
        routeButton:Hide()
        skipButton:Hide()
        return
    end
    local zone = selected
    local d, t = ns.ZoneCounts(zone)
    zoneTitle:SetText(zone.name)
    local routed = ns.route and ns.route.zone == zone
    if d == t then
        zoneInfo:SetText(GREEN .. "Fully explored. All " .. t .. " areas uncovered.|r")
    elseif routed then
        zoneInfo:SetText(string.format("%d of %d areas uncovered. Route: %d stop%s, about %s.", d, t,
            #ns.route.stops, #ns.route.stops == 1 and "" or "s", ns.Yards(ns.route.yards)))
    else
        zoneInfo:SetText(string.format("%d of %d areas uncovered. %s%d to find.|r", d, t, GOLD, t - d))
    end
    nextInfo:SetText(routed and (ns.NextStopText() or "") or
        (d < t and (GRAY .. "Start the route, or click a marker to head there first.|r") or ""))
    routeButton:SetShown(d < t)
    routeButton:SetText(routed and "Stop route" or "Start route")
    skipButton:SetShown(routed and #ns.route.stops > 1)
end

-------------------------------------------------------------------------------
-- The window
-------------------------------------------------------------------------------

Refresh = function()
    if not frame or not frame:IsShown() then return end
    local ad, at, zd, zt = ns.Totals()
    SetBar(overallBar, ad, at)
    overallBar.text:SetText(string.format("Explorer: %d / %d areas, %d / %d zones", ad, at, zd, zt))
    autoBox:SetChecked(ns.db.autoRoute)
    pinBox:SetChecked(ns.db.mapPins)
    RefreshList()
    DrawMap()
    RefreshInfo()
end
ns.RefreshWindow = Refresh

local function Build()
    if frame then return end
    frame = CreateFrame("Frame", "ChairLegacyFrame", UIParent, "BackdropTemplate")
    frame:SetSize(W, H)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        ns.SavePoint(self, ns.db.window)
    end)
    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
    end
    tinsert(UISpecialFrames, "ChairLegacyFrame")

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 22, -18)
    title:SetText(ns.title .. ": Exploration")
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    overallBar = Bar(frame, 330, 18)
    overallBar:SetPoint("TOPLEFT", 22, -46)

    autoBox = Check(frame, "Route me automatically when I enter a zone",
        "Entering a zone with areas still to uncover starts its route and tells you where to run. "
        .. "Leaving the zone ends that route.", function(on) ns.SetAutoRoute(on) end)
    autoBox:SetPoint("TOPLEFT", 380, -38)
    pinBox = Check(frame, "Show markers on the world map",
        "Areas still to uncover, numbered in route order, plus a bar to start the route.",
        function(on)
            ns.db.mapPins = on
            ns.Fire("settings")
        end)
    pinBox:SetPoint("TOPLEFT", 380, -60)

    contButtons = {}
    for i, c in ipairs({ { 0, "Eastern Kingdoms" }, { 1, "Kalimdor" } }) do
        local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        b:SetSize(LIST_W / 2 - 4, 22)
        b:SetPoint("TOPLEFT", 18 + (i - 1) * (LIST_W / 2), -92)
        b:SetText(c[2])
        b.continent = c[1]
        b:SetScript("OnClick", function()
            continent = c[1]
            if scroll.SetVerticalScroll then scroll:SetVerticalScroll(0) end
            Refresh()
        end)
        contButtons[i] = b
    end

    scroll = CreateFrame("ScrollFrame", "ChairLegacyZoneList", frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 18, -122)
    scroll:SetSize(LIST_W - 26, H - 140)
    listChild = CreateFrame("Frame", nil, scroll)
    listChild:SetSize(LIST_W - 26, 1)
    scroll:SetScrollChild(listChild)

    local border = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    border:SetPoint("TOPLEFT", LIST_W + 26, -88)
    border:SetSize(MAP_W + 8, MAP_H + 8)
    if border.SetBackdrop then
        border:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12 })
        border:SetBackdropBorderColor(0.6, 0.5, 0.3)
    end
    mapBox = CreateFrame("Frame", nil, frame)
    mapBox:SetPoint("TOPLEFT", border, "TOPLEFT", 4, -4)
    mapBox:SetSize(MAP_W, MAP_H)
    if mapBox.SetClipsChildren then mapBox:SetClipsChildren(true) end
    local paper = mapBox:CreateTexture(nil, "BACKGROUND", nil, -8)
    paper:SetAllPoints()
    paper:SetColorTexture(0.12, 0.1, 0.07, 1)
    hasLines = type(mapBox.CreateLine) == "function"
    playerDot = mapBox:CreateTexture(nil, "OVERLAY")
    playerDot:SetTexture("Interface\\Minimap\\MinimapArrow")
    playerDot:SetSize(24, 24)
    playerDot:Hide()

    zoneTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    zoneTitle:SetPoint("TOPLEFT", border, "BOTTOMLEFT", 4, -10)
    zoneInfo = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    zoneInfo:SetPoint("TOPLEFT", zoneTitle, "BOTTOMLEFT", 0, -6)
    nextInfo = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nextInfo:SetPoint("TOPLEFT", zoneInfo, "BOTTOMLEFT", 0, -6)

    routeButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    routeButton:SetSize(130, 26)
    routeButton:SetPoint("TOPRIGHT", border, "BOTTOMRIGHT", 0, -8)
    routeButton:SetScript("OnClick", function()
        if ns.route and ns.route.zone == selected then ns.StopRoute() else ns.StartRoute(selected) end
    end)
    skipButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    skipButton:SetSize(130, 26)
    skipButton:SetPoint("TOPRIGHT", routeButton, "BOTTOMRIGHT", 0, -4)
    skipButton:SetText("Skip this stop")
    skipButton:SetScript("OnClick", function() ns.SkipStop() end)

    local elapsed = 0
    frame:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + (ns.Num(dt) or 0)
        if elapsed < 0.1 then return end
        elapsed = 0
        pcall(DrawPlayer)
    end)
    frame:SetScript("OnShow", function()
        ns.InvalidateProgress()
        Refresh()
    end)
    ns.RestorePoint(frame, ns.db.window, "CENTER", "CENTER", 0, 0)
end

-- Open on `zone`, or on the route's zone, the zone you are in, or the first
-- one with work left.
function ns.ShowZone(zone)
    Build()
    selected = zone or (ns.route and ns.route.zone) or ns.CurrentZone() or selected
    if not selected then
        for _, z in ipairs(ns.ZONES) do
            local d, t = ns.ZoneCounts(z)
            if d < t then selected = z break end
        end
    end
    if selected then continent = selected.continent end
    frame:Show()
    Refresh()
end

function ns.ToggleWindow()
    if frame and frame:IsShown() then frame:Hide() else ns.ShowZone() end
end

-- Through ns.Fire, which reports an error instead of hiding it.
ns.On("progress", function() Refresh() end)
ns.On("route", function() Refresh() end)
ns.On("settings", function() Refresh() end)
