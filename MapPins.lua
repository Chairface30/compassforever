-- Chair Legacy: MapPins.lua
-- On the world map, while it shows a zone with areas still covered:
--   - a marker on each of them, numbered in route order while that zone's
--     route is walked; click one to head there next (it starts the route if
--     none is running);
--   - a bar across the top of the map saying how many are left, with a
--     button to start or stop the route and one to open the zone in the
--     Chair Legacy window.
--
-- Everything sits on frames of our own laid over the map. The map is only
-- read (which map it shows, how big its canvas is), never driven.

local _, ns = ...

local overlay, barFrame
local pins, used = {}, 0
local PIN = 16

local function Canvas()
    local map = _G.WorldMapFrame
    local sc = map and map.ScrollContainer
    return map, sc, sc and sc.Child
end

local function ShownZone()
    local map = Canvas()
    if not map then return nil end
    local ok, mapID = pcall(map.GetMapID, map)
    mapID = ok and ns.Num(mapID)
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
            GameTooltip:AddLine("Not uncovered yet.", 1, 0.82, 0)
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

local function Place(p, x, y)
    p:ClearAllPoints()
    p:SetPoint("CENTER", overlay, "TOPLEFT", x * overlay:GetWidth(), -y * overlay:GetHeight())
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

local function Refresh()
    if not overlay then return end
    for i = 1, used do pins[i]:Hide() end
    used = 0
    local zone = ns.db and ns.db.mapPins and ShownZone() or nil
    RefreshBar(zone)
    if not zone then return end
    -- The canvas grows as the map zooms; the markers stay one size on screen.
    local okS, scale = pcall(overlay.GetEffectiveScale, overlay)
    local inv = (okS and ns.Num(scale) and scale > 0) and (UIParent:GetEffectiveScale() / scale) or 1

    if ns.route and ns.route.zone == zone then
        for i, stop in ipairs(ns.route.stops) do
            local p = Pin()
            p:SetScale(inv)
            p.zone, p.node, p.first = zone, stop.node, i == 1
            p.num:SetText(i)
            p:SetSize(i == 1 and 22 or PIN, i == 1 and 22 or PIN)
            p.dot:SetVertexColor(i == 1 and 0.3 or 1, 1, i == 1 and 0.35 or 0.3)
            Place(p, stop.x, stop.y)
        end
        return
    end
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
    o:SetFrameLevel((child:GetFrameLevel() or 1) + 50)

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
    overlay, barFrame = o, bar

    if type(map.OnMapChanged) == "function" then
        pcall(hooksecurefunc, map, "OnMapChanged", SafeRefresh)
    end
    map:HookScript("OnShow", SafeRefresh)
    child:HookScript("OnSizeChanged", SafeRefresh)
end

ns.On("login", Setup)
ns.On("route", Refresh)
ns.On("progress", Refresh)
ns.On("settings", Refresh)
