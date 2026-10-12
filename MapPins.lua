-- Compass Forever: MapPins.lua
-- On the world map, while it shows a zone with areas still covered:
--   - a marker on each of them, numbered in route order while that zone's
--     route is walked; click one to head there next (it starts the route if
--     none is running);
--   - a bar across the top of the map saying how many are left, with a
--     button to start or stop the route and one to open the zone in the
--     Compass Forever window;
--   - the areas still covered drawn in gray, so the whole zone shows (its
--     own option, worldMapGray, apart from the markers);
--   - while a route runs, on whatever map is open (the route's zone, the
--     zone next door, the continent): the route's lines and its numbered
--     stops, carried across zone lines (RouteDraw.lua).
--
-- Everything sits on frames of our own laid over the map. The map is only
-- read (which map it shows, how big its canvas is, the frame levels its own
-- pins use), never driven. Our markers and bar go above the map's top-most
-- pin level, so nothing of the map's covers them; the gray art goes at the
-- level of the map's own uncovered-area art, under every pin.

local _, ns = ...

local overlay, barFrame, grayFrame, grayPool
local lines = {}
local DrawLines
local pins, used = {}, 0
local PIN = 16

local function Canvas()
    local map = _G.WorldMapFrame
    local sc = map and map.ScrollContainer
    return map, sc, sc and sc.Child
end

local function ShownMap()
    local map = Canvas()
    if not map then return nil end
    local ok, mapID = pcall(map.GetMapID, map)
    return ok and ns.Num(mapID) or nil
end

local function ShownZone()
    local mapID = ShownMap()
    return mapID and ns.ZoneByMap(mapID)
end

local function Pin()
    used = used + 1
    local p = pins[used]
    if not p then
        p = CreateFrame("Button", nil, overlay)
        p:SetSize(PIN, PIN)
        p.dot = p:CreateTexture(nil, "ARTWORK")
        p.dot:SetAllPoints()
        p.dot:SetTexture("Interface\\COMMON\\Indicator-Yellow")
        p.num = p:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        p.num:SetPoint("BOTTOM", p, "TOP", 0, -2)
        p:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.node.name, 1, 1, 1)
            if self.node.fp then
                GameTooltip:AddLine("A flight master you haven't met: talk to them to learn this flight point.", 0.4, 0.75, 1, true)
            else
                GameTooltip:AddLine("Not uncovered yet.", 1, 0.82, 0)
            end
            if self.node.rough then
                GameTooltip:AddLine("Approximate spot: this area has no ground of its own.", 1, 0.5, 0.5, true)
            end
            GameTooltip:AddLine(self.first and "Your next stop." or "Click to go here next.", 0.6, 1, 0.6)
            GameTooltip:Show()
        end)
        p:SetScript("OnLeave", function() GameTooltip:Hide() end)
        p:SetScript("OnClick", function(self) ns.RouteVia(self.zone, self.node) end)
        pins[used] = p
    end
    p:Show()
    return p
end

-- A frame's anchor offsets are counted in its own scaled units, and the
-- markers are scaled to stay one size as the map zooms: the offsets are
-- divided by that scale, or every marker drifts down and right of its spot
-- (further the further it is from the corner).
local function Place(p, x, y)
    local okS, s = pcall(p.GetScale, p)
    s = (okS and ns.Num(s) and s > 0) and s or 1
    p:ClearAllPoints()
    p:SetPoint("CENTER", overlay, "TOPLEFT", x * overlay:GetWidth() / s, -y * overlay:GetHeight() / s)
end

local function RefreshBar(zone)
    local bar = barFrame
    if not zone then bar:Hide() return end
    local d, t = ns.ZoneCounts(zone)
    local routed = ns.route and ns.route.zone == zone
    if d == t then
        bar.text:SetText("|cff55dd55" .. zone.name .. " is fully explored.|r")
        bar.route:Hide()
    else
        bar.text:SetText(string.format("%s: |cffffd100%d area%s to uncover|r", zone.name, t - d, t - d == 1 and "" or "s"))
        bar.route:SetText(routed and "Stop route" or "Start route")
        bar.route:Show()
    end
    bar.zone = zone
    bar:Show()
end

-- The route's lines on the shown map, kept one width on screen as it zooms.
DrawLines = function(mapID, inv)
    for _, l in ipairs(lines) do l:Hide() end
    if type(overlay.CreateLine) ~= "function" then return end
    ns.DrawRouteOn(overlay, mapID, overlay:GetWidth(), overlay:GetHeight(), function(i)
        local l = lines[i]
        if not l then
            l = overlay:CreateLine(nil, "ARTWORK")
            lines[i] = l
        end
        l:Show()
        return l
    end, 3 * (inv or 1))
end

-- The map's own pin frame levels: its uncovered-area art, and the highest
-- level any of its pins use. Read only; fallbacks if the map has none.
local function Levels(map, child)
    local base = (child:GetFrameLevel() or 1)
    local okM, mgr = pcall(function() return map:GetPinFrameLevelsManager() end)
    if not (okM and type(mgr) == "table" and mgr.GetValidFrameLevel) then return base + 1, base + 3000 end
    local okE, explore = pcall(mgr.GetValidFrameLevel, mgr, "PIN_FRAME_LEVEL_MAP_EXPLORATION")
    local okT, top = pcall(mgr.GetValidFrameLevel, mgr, "PIN_FRAME_LEVEL_TOPMOST")
    explore = okE and ns.Num(explore) or base + 1
    top = okT and ns.Num(top) or base + 3000
    return explore, top
end

local function Refresh()
    if not overlay then return end
    for i = 1, used do pins[i]:Hide() end
    used = 0
    grayPool:Begin()
    local map, _, child = Canvas()
    local explore, top = Levels(map, child)
    grayFrame:SetFrameLevel(explore)
    overlay:SetFrameLevel(math.min(top + 100, 9000))
    barFrame:SetFrameLevel(math.min(top + 200, 9100))
    for _, l in ipairs(lines) do l:Hide() end
    local shown = ShownZone()
    if shown and ns.db and ns.db.worldMapGray ~= false then
        local lw = ns.ArtLayer(shown.map)
        ns.DrawCoveredGray(grayPool, shown, (child:GetWidth() or 0) / lw)
    end
    local on = ns.db and ns.db.mapPins
    local zone = on and shown or nil
    RefreshBar(zone)
    if not on then return end
    -- The canvas grows as the map zooms; the markers stay one size on screen.
    local okS, scale = pcall(overlay.GetEffectiveScale, overlay)
    local inv = (okS and ns.Num(scale) and scale > 0) and (UIParent:GetEffectiveScale() / scale) or 1

    if ns.route then
        local mapID = ShownMap()
        if mapID then
            for _, stop in ipairs(ns.RouteStopsOn(mapID)) do
                local p = Pin()
                p:SetScale(inv)
                p.zone, p.node, p.first = ns.route.zone, stop.node, stop.i == 1
                p.num:SetText(stop.i)
                p:SetSize(stop.i == 1 and 22 or PIN, stop.i == 1 and 22 or PIN)
                p.dot:SetVertexColor(stop.i == 1 and 0.3 or 1, 1, stop.i == 1 and 0.35 or 0.3)
                Place(p, stop.x, stop.y)
            end
            DrawLines(mapID, inv)
        end
        return
    end
    if not zone then return end

    for _, node in ipairs(ns.ZoneRemaining(zone)) do
        local p = Pin()
        p:SetScale(inv)
        p.zone, p.node, p.first = zone, node, false
        p.num:SetText("")
        p:SetSize(PIN, PIN)
        p.dot:SetVertexColor(1, 0.9, 0.3)
        local pt = ns.NodePoints(node)[1]
        Place(p, pt[1], pt[2])
    end
end

-- From the map's own hooks: an error must never break the map, but the
-- first one is said in chat so it gets reported.
local reported = false
local function SafeRefresh()
    local ok, err = pcall(Refresh)
    if not ok and not reported then
        reported = true
        ns.Print("|cffff5555world map:|r", err)
    end
end

local function Setup()
    if overlay then return end
    local map, sc, child = Canvas()
    if not (map and sc and child) then return end
    -- Built whole before it is kept, so a failure part way leaves nothing
    -- half made: the next login simply tries again.
    local o = CreateFrame("Frame", nil, child)
    o:SetAllPoints(child)
    local g = CreateFrame("Frame", nil, child)
    g:SetAllPoints(child)
    g:EnableMouse(false)

    local bar = CreateFrame("Frame", nil, map, "BackdropTemplate")
    bar:SetSize(420, 30)
    bar:SetPoint("TOP", sc, "TOP", 0, -6)
    bar:SetFrameLevel((sc:GetFrameLevel() or 1) + 60)
    if bar.SetBackdrop then
        bar:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        bar:SetBackdropColor(0, 0, 0, 0.75)
    end
    bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bar.text:SetPoint("LEFT", 10, 0)
    bar.open = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    bar.open:SetSize(60, 20)
    bar.open:SetPoint("RIGHT", -6, 0)
    bar.open:SetText("Plan")
    bar.open:SetScript("OnClick", function() ns.ShowZone(bar.zone) end)
    bar.route = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    bar.route:SetSize(96, 20)
    bar.route:SetPoint("RIGHT", bar.open, "LEFT", -4, 0)
    bar.route:SetScript("OnClick", function()
        if ns.route and ns.route.zone == bar.zone then ns.StopRoute() else ns.StartRoute(bar.zone) end
    end)
    bar:Hide()
    overlay, barFrame, grayFrame, grayPool = o, bar, g, ns.TexturePool(g, "ARTWORK")

    if type(map.OnMapChanged) == "function" then
        pcall(hooksecurefunc, map, "OnMapChanged", SafeRefresh)
    end
    map:HookScript("OnShow", SafeRefresh)
    local tick = 0
    o:SetScript("OnUpdate", function(_, dt)
        tick = tick + (ns.Num(dt) or 0)
        if tick < 0.2 then return end
        tick = 0
        if not (ns.route and ns.db and ns.db.mapPins) then return end
        local mapID = ShownMap()
        if not mapID then return end
        local okS, scale = pcall(o.GetEffectiveScale, o)
        local inv = (okS and ns.Num(scale) and scale > 0) and (UIParent:GetEffectiveScale() / scale) or 1
        pcall(DrawLines, mapID, inv)
    end)
    child:HookScript("OnSizeChanged", SafeRefresh)
end

ns.On("login", Setup)
ns.On("route", Refresh)
ns.On("progress", Refresh)
ns.On("settings", Refresh)
