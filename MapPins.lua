-- Chair Legacy: MapPins.lua
-- The map areas still covered, drawn on the world map while it shows their
-- zone: a numbered marker per stop while that zone's route is walked, a plain
-- dot otherwise.
--
-- The markers sit on a frame of our own laid over the map's canvas. The map is
-- only read (which map is shown, how big the canvas is), never driven: see
-- the never-drive-blizzard-frames note in Chaircraft's history.

local _, ns = ...

local overlay
local pins, used = {}, 0
local PIN = 14

local function Canvas()
    local map = _G.WorldMapFrame
    local sc = map and map.ScrollContainer
    return map, sc and sc.Child
end

local function Pin()
    used = used + 1
    local p = pins[used]
    if not p then
        p = CreateFrame("Frame", nil, overlay)
        p:SetSize(PIN, PIN)
        p.dot = p:CreateTexture(nil, "ARTWORK")
        p.dot:SetAllPoints()
        p.dot:SetTexture("Interface\\Minimap\\ObjectIcons")
        p.dot:SetTexCoord(0.125, 0.25, 0.125, 0.25)   -- the round yellow marker
        p.num = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        p.num:SetPoint("BOTTOM", p, "TOP", 0, -2)
        p:EnableMouse(true)
        p:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.title or "", 1, 1, 1)
            if self.sub then GameTooltip:AddLine(self.sub, 0.8, 0.8, 0.8, true) end
            GameTooltip:Show()
        end)
        p:SetScript("OnLeave", function() GameTooltip:Hide() end)
        pins[used] = p
    end
    p:Show()
    return p
end

local function Place(p, x, y)
    local w, h = overlay:GetWidth(), overlay:GetHeight()
    p:ClearAllPoints()
    p:SetPoint("CENTER", overlay, "TOPLEFT", x * w, -y * h)
end

local function Refresh()
    if not overlay then return end
    for i = 1, used do pins[i]:Hide() end
    used = 0
    if not ns.db or not ns.db.mapPins then return end
    local map = Canvas()
    local okM, mapID = pcall(map.GetMapID, map)
    mapID = okM and ns.Num(mapID)
    local zone = mapID and ns.ZoneByMap(mapID)
    if not zone then return end
    -- The canvas grows as the map zooms; the markers stay the same size on
    -- screen.
    local okS, scale = pcall(overlay.GetEffectiveScale, overlay)
    local parentScale = UIParent:GetEffectiveScale()
    local inv = (okS and ns.Num(scale) and scale > 0) and (parentScale / scale) or 1

    if ns.route and ns.route.zone == zone then
        for i, stop in ipairs(ns.route.stops) do
            local p = Pin()
            p:SetScale(inv)
            p.num:SetText(i)
            p.dot:SetVertexColor(i == 1 and 0.3 or 1, 1, i == 1 and 0.3 or 1)
            p.title = i .. ". " .. stop.node.name
            p.sub = string.format("%.1f, %.1f%s", stop.x * 100, stop.y * 100,
                stop.node.rough and " (approximate)" or "")
            Place(p, stop.x, stop.y)
        end
        return
    end
    for _, node in ipairs(ns.ZoneRemaining(zone)) do
        local p = Pin()
        p:SetScale(inv)
        p.num:SetText("")
        p.dot:SetVertexColor(1, 1, 1)
        local pt = ns.NodePoints(node)[1]
        p.title = node.name
        p.sub = string.format("Not yet uncovered. %.1f, %.1f", pt[1] * 100, pt[2] * 100)
        Place(p, pt[1], pt[2])
    end
end

local function Setup()
    if overlay then return end
    local map, child = Canvas()
    if not (map and child) then return end
    overlay = CreateFrame("Frame", nil, child)
    overlay:SetAllPoints(child)
    overlay:SetFrameLevel((child:GetFrameLevel() or 1) + 50)
    if type(map.OnMapChanged) == "function" then
        pcall(hooksecurefunc, map, "OnMapChanged", function() pcall(Refresh) end)
    end
    map:HookScript("OnShow", function() pcall(Refresh) end)
    child:HookScript("OnSizeChanged", function() pcall(Refresh) end)
end

ns.On("login", function() pcall(Setup) end)
ns.On("route", function() pcall(Refresh) end)
ns.On("progress", function() pcall(Refresh) end)
