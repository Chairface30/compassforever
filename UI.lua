-- Compass Forever: UI.lua
-- The window. Zones down the left with how much of each is uncovered; on the
-- right a map that works like the world map:
--
--   Azeroth    - both continents, each with its progress; click one to open it.
--   continent  - its zones, each with what is left; hover one to light it up,
--                click it to open it. Right-click goes back to Azeroth.
--   zone       - the zone's own map: what you have uncovered in color, what is
--                still covered in gray, a marker on every area still to find,
--                the route as a line, and you. Click a marker to go there
--                next. Right-click goes back to the continent.
--
-- A trail above the map (Azeroth > Eastern Kingdoms > Elwynn Forest) can be
-- clicked too. Map art is read from the client and drawn on our own
-- textures; no Blizzard frame is touched.

local _, ns = ...

local W, H = 900, 600
local LIST_W = 250
local MAP_W, MAP_H = 600, 400
local ROW_H = 38
local GREEN, GOLD, GRAY = "|cff55dd55", "|cffffd100", "|cff999999"

local WORLD = 947
local CONTINENT_MAP = { [0] = 1415, [1] = 1414 }
local CONTINENT_NAME = { [0] = "Eastern Kingdoms", [1] = "Kalimdor" }

local frame, mapBox, scroll, listChild
local overallBar, autoBox, pinBox, contButtons, trail
local zoneTitle, zoneInfo, nextInfo, routeButton, skipButton
local zoneRows = {}
local continent = 0          -- the continent the list shows
local view = { kind = "continent", map = CONTINENT_MAP[0] }
local Refresh

local function ContinentOfMap(mapID)
    for c, m in pairs(CONTINENT_MAP) do
        if m == mapID then return c end
    end
    return nil
end

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
    bar:SetValue(total > 0 and done / total or 0)
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
-- Moving between maps
-------------------------------------------------------------------------------

local function ShowZoneView(zone)
    view = { kind = "zone", map = zone.map, zone = zone }
    continent = zone.continent
    Refresh()
end

local function ShowContinentView(c)
    view = { kind = "continent", map = CONTINENT_MAP[c] }
    continent = c
    Refresh()
end

local function ShowWorldView()
    view = { kind = "world", map = WORLD }
    Refresh()
end

-- Right-click: one level up.
local function ZoomOut()
    if view.kind == "zone" then ShowContinentView(view.zone.continent)
    elseif view.kind == "continent" then ShowWorldView() end
end

-------------------------------------------------------------------------------
-- The zone list
-------------------------------------------------------------------------------

local function ZoneTooltip(owner, zone, anchor)
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
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
    row:SetScript("OnClick", function(self) ShowZoneView(self.zone) end)
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
            if view.zone == zone then row.bg:SetColorTexture(1, 0.82, 0, 0.22)
            else row.bg:SetColorTexture(1, 1, 1, d == t and 0.02 or 0.06) end
            row:Show()
        end
    end
    for i = n + 1, #zoneRows do zoneRows[i]:Hide() end
    listChild:SetHeight(math.max(1, n * ROW_H))
    for _, b in ipairs(contButtons) do
        b:SetEnabled(not (view.kind == "continent" and b.continent == continent))
    end
end

-------------------------------------------------------------------------------
-- The map
-------------------------------------------------------------------------------

local baseTiles, colorArt, grayArt
local pins, badges, lines = {}, {}, {}
local playerDot, highlight
local hasLines

local function Pool(list, i, make)
    local t = list[i]
    if not t then t = make() list[i] = t end
    t:Show()
    return t
end

-- A map's art: base tiles, then each uncovered overlay in color, and for a
-- zone each still-covered area in gray.
local function DrawArt(mapID, zone)
    baseTiles:Begin()
    colorArt:Begin()
    grayArt:Begin()
    local lw, _, tw, th = ns.ArtLayer(mapID)
    local scale = MAP_W / lw
    local okT, files = ns.Ask(ns.API("C_Map", "GetMapArtLayerTextures"), mapID, 1)
    if okT and type(files) == "table" then
        local cols = math.ceil(lw / tw)
        for i, file in ipairs(files) do
            local t = baseTiles:Next()
            t:SetTexture(file)
            t:SetSize(tw * scale, th * scale)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", ((i - 1) % cols) * tw * scale, -math.floor((i - 1) / cols) * th * scale)
        end
    end
    local okE, explored = ns.Ask(ns.API("C_MapExplorationInfo", "GetExploredMapTextures"), mapID)
    if okE and type(explored) == "table" then
        for _, info in ipairs(explored) do
            local ids = info.fileDataIDs
            local texW, texH = ns.Num(info.textureWidth), ns.Num(info.textureHeight)
            local ox, oy = ns.Num(info.offsetX), ns.Num(info.offsetY)
            if type(ids) == "table" and texW and texH and ox and oy and not info.isShownByMouseOver then
                ns.EachTile(ox, oy, texW, texH, ids, tw, th, function(file, x, y, w, h, u, v)
                    local t = colorArt:Next()
                    t:SetTexture(file)
                    t:SetTexCoord(0, u, 0, v)
                    t:SetSize(w * scale, h * scale)
                    t:ClearAllPoints()
                    t:SetPoint("TOPLEFT", x * scale, -y * scale)
                end)
            end
        end
    end
    if zone then ns.DrawCoveredGray(grayArt, zone, scale) end
end

-- Where the cursor is on the map, as fractions; nil when off it.
local function CursorOnMap()
    local okC, cx, cy = pcall(GetCursorPosition)
    if not okC or not cx then return nil end
    local s = mapBox:GetEffectiveScale()
    local left, top = mapBox:GetLeft(), mapBox:GetTop()
    if not (s and left and top) then return nil end
    local x, y = (cx / s - left) / MAP_W, (top - cy / s) / MAP_H
    if x < 0 or x > 1 or y < 0 or y > 1 then return nil end
    return x, y
end

-- The map under a point of the shown map: a zone (on a continent) or a
-- continent (on Azeroth).
local function MapAt(x, y)
    local ok, info = ns.Ask(ns.API("C_Map", "GetMapInfoAtPosition"), view.map, x, y)
    return ok and type(info) == "table" and ns.Num(info.mapID) or nil
end

local function Target(x, y)
    local mapID = MapAt(x, y)
    if not mapID then return nil end
    if view.kind == "continent" then
        local zone = ns.ZoneByMap(mapID)
        return zone and { zone = zone } or nil
    elseif view.kind == "world" then
        local c = ContinentOfMap(mapID)
        return c and { continent = c } or nil
    end
    return nil
end

-- Light up what the cursor is over, as the world map does.
local hovered
local function Hover()
    if not (view.kind ~= "zone" and mapBox:IsMouseOver()) then
        if hovered then
            hovered = nil
            highlight:Hide()
            GameTooltip:Hide()
        end
        return
    end
    local x, y = CursorOnMap()
    local target = x and Target(x, y)
    local key = target and (target.zone or target.continent)
    if key == hovered then return end
    hovered = key
    highlight:Hide()
    if not target then
        GameTooltip:Hide()
        return
    end
    local ok, file, atlas, px, py, tx, ty, sx, sy =
        ns.Ask(ns.API("C_Map", "GetMapHighlightInfoAtPosition"), view.map, x, y)
    if ok and ns.Num(file) and file > 0 and ns.Num(tx) and tx > 0 and ns.Num(ty) and ty > 0 then
        highlight:SetTexture(file)
        highlight:SetTexCoord(0, px, 0, py)
        highlight:SetSize(tx * MAP_W, ty * MAP_H)
        highlight:ClearAllPoints()
        highlight:SetPoint("TOPLEFT", mapBox, "TOPLEFT", sx * MAP_W, -sy * MAP_H)
        highlight:Show()
    end
    if target.zone then
        ZoneTooltip(mapBox, target.zone, "ANCHOR_CURSOR")
        GameTooltip:AddLine("Click to open. Right-click to see Azeroth.", 0.6, 1, 0.6)
        GameTooltip:Show()
    else
        local ad, at, zd, zt = ns.Totals(target.continent)
        GameTooltip:SetOwner(mapBox, "ANCHOR_CURSOR")
        GameTooltip:AddLine(CONTINENT_NAME[target.continent], 1, 1, 1)
        GameTooltip:AddLine(string.format("%d of %d areas, %d of %d zones explored", ad, at, zd, zt), 1, 0.82, 0)
        GameTooltip:AddLine("Click to open.", 0.6, 1, 0.6)
        GameTooltip:Show()
    end
end

local function OnMapClick(_, button)
    if button == "RightButton" then
        ZoomOut()
        return
    end
    local x, y = CursorOnMap()
    local target = x and Target(x, y)
    if not target then return end
    hovered = nil
    highlight:Hide()
    GameTooltip:Hide()
    if target.zone then ShowZoneView(target.zone) else ShowContinentView(target.continent) end
end

local function Pin(i)
    return Pool(pins, i, function()
        local p = CreateFrame("Button", nil, mapBox)
        p:SetFrameLevel(mapBox:GetFrameLevel() + 5)
        p:RegisterForClicks("LeftButtonUp", "RightButtonUp")
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
        p:SetScript("OnClick", function(self, button)
            if button == "RightButton" then ZoomOut()
            elseif not self.done then ns.RouteVia(view.zone, self.node) end
        end)
        return p
    end)
end

-- A count over each zone of a continent (or each continent of Azeroth).
local function Badge(i)
    return Pool(badges, i, function()
        local b = CreateFrame("Frame", nil, mapBox)
        b:SetFrameLevel(mapBox:GetFrameLevel() + 4)
        b:SetSize(80, 30)
        b:EnableMouse(false)
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetPoint("CENTER")
        b.bg:SetColorTexture(0, 0, 0, 0.55)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        b.text:SetPoint("CENTER")
        return b
    end)
end

local function PlaceBadge(b, text, x, y)
    b.text:SetText(text)
    local w = (b.text:GetStringWidth() or 40) + 10
    b.bg:SetSize(w, (b.text:GetStringHeight() or 12) + 6)
    b:ClearAllPoints()
    b:SetPoint("CENTER", mapBox, "TOPLEFT", x * MAP_W, -y * MAP_H)
end

-- Where `mapID` sits on the shown map: its middle, as fractions.
local function MiddleOn(mapID)
    local ok, left, right, top, bottom = ns.Ask(ns.API("C_Map", "GetMapRectOnMap"), mapID, view.map)
    if not (ok and ns.Num(left) and ns.Num(right) and ns.Num(top) and ns.Num(bottom)) then return nil end
    return (left + right) / 2, (top + bottom) / 2
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
    local px, py = ns.PlayerOn(view.map)
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
    if hasLines and first and view.kind == "zone" and ns.route and ns.route.zone == view.zone and stop then
        if inside then
            first:Show()
            Join(first, px, py, stop.x, stop.y, 0.3, 1, 0.35, 0.9)
        else
            first:Hide()
        end
    end
end

local function DrawZone(zone)
    local state = ns.ZoneState(zone).state
    local order = {}
    local routed = ns.route and ns.route.zone == zone
    if routed then
        for i, stop in ipairs(ns.route.stops) do order[stop.node] = { i = i, x = stop.x, y = stop.y } end
    end
    for i, node in ipairs(zone.nodes) do
        local p = Pin(i)
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
            p.dot:SetVertexColor(1, node.rough and 0.5 or 0.9, node.rough and 0.4 or 0.3, 1)
            p.num:SetText(o and o.i or "")
        end
    end
    if routed and hasLines then
        local stops = ns.route.stops
        for i = 2, #stops do
            Join(Line(i), stops[i - 1].x, stops[i - 1].y, stops[i].x, stops[i].y, 1, 0.82, 0.1, 0.75)
        end
        Line(1)
    end
end

local function DrawContinent(c)
    local n = 0
    for _, zone in ipairs(ns.ZONES) do
        if zone.continent == c then
            local x, y = MiddleOn(zone.map)
            if x then
                n = n + 1
                local d, t = ns.ZoneCounts(zone)
                PlaceBadge(Badge(n), d == t and (GREEN .. "Done|r") or (GOLD .. (t - d) .. " left|r"), x, y)
            end
        end
    end
end

local function DrawWorld()
    for c, mapID in pairs(CONTINENT_MAP) do
        local x, y = MiddleOn(mapID)
        if x then
            local ad, at, zd, zt = ns.Totals(c)
            PlaceBadge(Badge(c + 1), string.format("%s\n%s%d / %d zones|r", CONTINENT_NAME[c],
                zd == zt and GREEN or GOLD, zd, zt), x, y)
        end
    end
end

local function DrawMap()
    for _, p in ipairs(pins) do p:Hide() end
    for _, b in ipairs(badges) do b:Hide() end
    for _, l in ipairs(lines) do l:Hide() end
    highlight:Hide()
    hovered = nil
    pcall(DrawArt, view.map, view.zone)
    if view.kind == "zone" then DrawZone(view.zone)
    elseif view.kind == "continent" then DrawContinent(continent)
    else DrawWorld() end
    DrawPlayer()
end

-------------------------------------------------------------------------------
-- The trail above the map, and the text under it
-------------------------------------------------------------------------------

local function RefreshTrail()
    local parts = { { "Azeroth", ShowWorldView } }
    if view.kind ~= "world" then
        local c = view.zone and view.zone.continent or continent
        parts[2] = { CONTINENT_NAME[c], function() ShowContinentView(c) end }
    end
    if view.kind == "zone" then parts[3] = { view.zone.name } end
    local x = 0
    for i, b in ipairs(trail) do
        local part = parts[i]
        if part then
            local last = i == #parts
            b.text:SetText((last and "|cffffffff" or GOLD) .. part[1] .. "|r" .. (last and "" or GRAY .. "  >|r"))
            b:SetWidth((b.text:GetStringWidth() or 60) + 8)
            b:ClearAllPoints()
            b:SetPoint("BOTTOMLEFT", mapBox, "TOPLEFT", x, 8)
            x = x + b:GetWidth() + 4
            b.go = not last and part[2] or nil
            b:Show()
        else
            b:Hide()
        end
    end
end

local function RefreshInfo()
    routeButton:Hide()
    skipButton:Hide()
    nextInfo:SetText("")
    if view.kind == "world" then
        local ad, at, zd, zt = ns.Totals()
        zoneTitle:SetText("Azeroth")
        zoneInfo:SetText(string.format("%d of %d areas, %d of %d zones explored.", ad, at, zd, zt))
        nextInfo:SetText(GRAY .. "Click a continent to open it.|r")
        return
    end
    if view.kind == "continent" then
        local ad, at, zd, zt = ns.Totals(continent)
        zoneTitle:SetText(CONTINENT_NAME[continent])
        zoneInfo:SetText(string.format("%d of %d areas, %d of %d zones explored.", ad, at, zd, zt))
        nextInfo:SetText(GRAY .. "Click a zone to open it. Right-click to see Azeroth.|r")
        return
    end
    local zone = view.zone
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
        (GRAY .. (d < t and "Start the route, or click a marker to head there first. " or "")
            .. "Right-click the map to go back.|r"))
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
    RefreshTrail()
    RefreshInfo()
end
ns.RefreshWindow = Refresh

local function Build()
    if frame then return end
    frame = CreateFrame("Frame", "CompassForeverFrame", UIParent, "BackdropTemplate")
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
    tinsert(UISpecialFrames, "CompassForeverFrame")

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 22, -18)
    title:SetText(ns.title)
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    overallBar = Bar(frame, 330, 18)
    overallBar:SetPoint("TOPLEFT", 22, -46)

    autoBox = Check(frame, "Route me automatically when I enter a zone",
        "Entering a zone with areas still to uncover starts its route and tells you where to run. "
        .. "Leaving the zone ends that route.", function(on) ns.SetAutoRoute(on) end)
    autoBox:SetPoint("TOPLEFT", 380, -38)
    pinBox = Check(frame, "Show markers on the world map",
        "Areas still to uncover, numbered in route order, drawn in gray where still covered, "
        .. "plus a bar to start the route.",
        function(on)
            ns.db.mapPins = on
            ns.Fire("settings")
        end)
    pinBox:SetPoint("TOPLEFT", 380, -60)

    contButtons = {}
    for i, c in ipairs({ 0, 1 }) do
        local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        b:SetSize(LIST_W / 2 - 4, 22)
        b:SetPoint("TOPLEFT", 18 + (i - 1) * (LIST_W / 2), -100)
        b:SetText(CONTINENT_NAME[c])
        b.continent = c
        b:SetScript("OnClick", function()
            if scroll.SetVerticalScroll then scroll:SetVerticalScroll(0) end
            ShowContinentView(c)
        end)
        contButtons[i] = b
    end

    scroll = CreateFrame("ScrollFrame", "CompassForeverZoneList", frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 18, -130)
    scroll:SetSize(LIST_W - 26, H - 148)
    listChild = CreateFrame("Frame", nil, scroll)
    listChild:SetSize(LIST_W - 26, 1)
    scroll:SetScrollChild(listChild)

    local border = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    border:SetPoint("TOPLEFT", LIST_W + 26, -112)
    border:SetSize(MAP_W + 8, MAP_H + 8)
    if border.SetBackdrop then
        border:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12 })
        border:SetBackdropBorderColor(0.6, 0.5, 0.3)
    end
    mapBox = CreateFrame("Frame", nil, frame)
    mapBox:SetPoint("TOPLEFT", border, "TOPLEFT", 4, -4)
    mapBox:SetSize(MAP_W, MAP_H)
    if mapBox.SetClipsChildren then mapBox:SetClipsChildren(true) end
    mapBox:EnableMouse(true)
    mapBox:SetScript("OnMouseUp", OnMapClick)
    local paper = mapBox:CreateTexture(nil, "BACKGROUND", nil, -8)
    paper:SetAllPoints()
    paper:SetColorTexture(0.12, 0.1, 0.07, 1)
    baseTiles = ns.TexturePool(mapBox, "BACKGROUND", 0)
    grayArt = ns.TexturePool(mapBox, "BORDER", 0)
    colorArt = ns.TexturePool(mapBox, "BORDER", 1)
    highlight = mapBox:CreateTexture(nil, "ARTWORK", nil, 1)
    highlight:SetBlendMode("ADD")
    highlight:SetAlpha(0.6)
    highlight:Hide()
    hasLines = type(mapBox.CreateLine) == "function"
    playerDot = mapBox:CreateTexture(nil, "OVERLAY")
    playerDot:SetTexture("Interface\\Minimap\\MinimapArrow")
    playerDot:SetSize(24, 24)
    playerDot:Hide()

    trail = {}
    for i = 1, 3 do
        local b = CreateFrame("Button", nil, frame)
        b:SetHeight(18)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        b.text:SetPoint("LEFT", 2, 0)
        b:SetScript("OnClick", function(self) if self.go then self.go() end end)
        trail[i] = b
    end

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
        if ns.route and ns.route.zone == view.zone then ns.StopRoute() else ns.StartRoute(view.zone) end
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
        pcall(Hover)
    end)
    frame:SetScript("OnShow", function()
        ns.InvalidateProgress()
        Refresh()
    end)
    ns.RestorePoint(frame, ns.db.window, "CENTER", "CENTER", 0, 0)
end

-- Open on `zone`, or on the route's zone, the zone you are in, or your
-- continent's map.
function ns.ShowZone(zone)
    Build()
    zone = zone or (ns.route and ns.route.zone) or ns.CurrentZone()
    frame:Show()
    if zone then ShowZoneView(zone) else ShowContinentView(continent) end
end

function ns.ToggleWindow()
    if frame and frame:IsShown() then frame:Hide() else ns.ShowZone() end
end

-- For the tests: what the map shows, and a click on it.
function ns.WindowView() return view end
ns.WindowZoomOut = ZoomOut
ns.WindowOpen = function(target)
    if target.zone then ShowZoneView(target.zone) else ShowContinentView(target.continent) end
end
ns.WindowTarget = Target

-- Through ns.Fire, which reports an error instead of hiding it.
ns.On("progress", function() Refresh() end)
ns.On("route", function() Refresh() end)
ns.On("settings", function() Refresh() end)
