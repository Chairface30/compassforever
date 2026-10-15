-- Compass Forever: Layers.lua
-- What a zone's map holds, drawn over the window's map, each kind with its
-- own switch (the Layers button in the map's corner). Flight masters are for
-- everyone; the rest is for the map's authors (Core.lua, MAPPERS): what the
-- routes are made of, so a zone can be checked and mapped by eye.
--
--   Flight masters    every flight point for your faction, known or not
--   Area outlines     each area's outline from the terrain (the option)
-- From the game's own data (Data/MapData.lua, tools/build_mapdata.py):
--   Zone edge         the zone's real edge: its terrain chunks' outline
--   Ways in and out   where walkable ground crosses that edge, with the
--                     neighbour's name and how wide
--   Place names       the world map's own place names
--   Area triggers     the game's trigger spots, circles and boxes
--   Area hover boxes  each area's hover box on the world map
-- And what the routes are made of:
--   Zone ground       the ground a route inside the zone keeps to
--   Walls, Zone lines, Roads, Ledges
--                     your own (while editing) and the built-in ones
--   Walking network   the waypoints and links paths are found over: cut by
--                     a wall in red, one way (a ledge) in orange, kept out
--                     of this zone's own paths by a zone line in purple,
--                     a drawn road's in green
--   Portals and boats the ends of the rides the paths can take
--   Unreachable areas areas a route inside the zone can't walk to from all
--                     the others, in red, with how many they do reach

local _, ns = ...

local LAYERS = {
    { key = "fp", label = "Flight masters", default = true,
      tip = "Every flight point for your faction: green if you know it, yellow if not." },
    { key = "outlines", label = "Area outlines",
      tip = "Each area's outline, from the terrain.",
      get = function() return ns.db.areaBorders ~= false end,
      set = function(on) ns.db.areaBorders = on end },
    { key = "border", label = "Zone edge", mapper = true, default = false,
      tip = "From the game's terrain: the zone's real edge, round every chunk of ground that is the zone or one of its subzones." },
    { key = "crossings", label = "Ways in and out", mapper = true, default = true,
      tip = "From the game's terrain: where walkable ground crosses the zone's edge into the next zone, "
          .. "with its name and how wide (in 33-yard chunks). Water counts as walkable here." },
    { key = "places", label = "Place names", mapper = true, default = false,
      tip = "From the game's data: the world map's own place names." },
    { key = "triggers", label = "Area triggers", mapper = true, default = false,
      tip = "From the game's data: its trigger spots (inns, entrances and the like), at their real size." },
    { key = "hits", label = "Area hover boxes", mapper = true, default = false,
      tip = "From the game's data: the box over which the world map lights each area up." },
    { key = "ground", label = "Zone ground", mapper = true, default = false,
      tip = "The ground a route inside the zone keeps to: the zone's own terrain and a little over 100 yards round it." },
    { key = "walls", label = "Walls", mapper = true, default = true, tip = "Never crossed." },
    { key = "zonelines", label = "Zone lines", mapper = true, default = true,
      tip = "Walls for paths inside the zone; crossed only coming in or going out." },
    { key = "roads", label = "Roads", mapper = true, default = true, tip = "Paths keep to them." },
    { key = "ledges", label = "Ledges", mapper = true, default = true,
      tip = "One-way walls: jumped down (to the ticked side), never climbed." },
    { key = "builtin", label = "Built-in lines too", mapper = true, default = true,
      tip = "Walls, zone lines, roads and ledges built into the addon, drawn thinner, as well as your own." },
    { key = "graph", label = "Walking network", mapper = true, default = false,
      tip = "The waypoints and links paths are found over. Red: cut by a wall. Orange: one way (a ledge). "
          .. "Purple: kept out of this zone's own paths by a zone line. Green: a drawn road." },
    { key = "rides", label = "Portals and boats", mapper = true, default = false,
      tip = "The ends of rides paths can take, joined by a line." },
    { key = "cutoff", label = "Unreachable areas", mapper = true, default = false,
      tip = "Areas a route inside the zone can't walk to from all the others, in red, with how many they reach. "
          .. "Worked out in the background the first time." },
}
local byKey = {}
for _, L in ipairs(LAYERS) do byKey[L.key] = L end

-- Is a layer showing?
function ns.LayerOn(key)
    local L = byKey[key]
    if not L or not ns.db then return false end
    if L.mapper and not ns.CanEdit() then return false end
    if L.get then return L.get() end
    local v = ns.db.layers and ns.db.layers[key]
    if v == nil then return L.default end
    return v and true or false
end

local function SetLayer(key, on)
    local L = byKey[key]
    if L.set then
        L.set(on)
    else
        ns.db.layers = ns.db.layers or {}
        ns.db.layers[key] = on and true or false
    end
    ns.WindowRedraw()
end
ns.SetLayer = SetLayer

-- Ticks along a ledge, on its drop side (right of the way it was drawn):
-- { x1, y1, x2, y2 } in pixels from the canvas' top left, y down.
local TICK = 6
function ns.LedgeTicks(line, cw, ch)
    local out = {}
    for k = 1, #line - 3, 2 do
        local ax, ay = line[k] * cw, line[k + 1] * ch
        local bx, by = line[k + 2] * cw, line[k + 3] * ch
        local dx, dy = bx - ax, by - ay
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 4 then
            local nx, ny = -dy / len * TICK, dx / len * TICK
            local steps = math.max(1, math.floor(len / 14))
            for q = 1, steps do
                local t = (q - 0.5) / steps
                local mx, my = ax + dx * t, ay + dy * t
                out[#out + 1] = { mx, my, mx + nx, my + ny }
            end
        end
    end
    return out
end

-------------------------------------------------------------------------------
-- Drawing
-------------------------------------------------------------------------------

local lines, dots, cells, fps, notes = {}, {}, {}, {}, {}
local nLines, nDots, nCells, nFps, nNotes = 0, 0, 0, 0, 0
local canvas, cw, ch

local function Line(x1, y1, x2, y2, c, thick)
    nLines = nLines + 1
    local l = lines[nLines]
    if not l then
        l = canvas:CreateLine(nil, "ARTWORK", nil, 2)
        lines[nLines] = l
    end
    l:SetThickness(thick or 1.5)
    l:SetStartPoint("TOPLEFT", canvas, x1 * cw, -y1 * ch)
    l:SetEndPoint("TOPLEFT", canvas, x2 * cw, -y2 * ch)
    l:SetColorTexture(c[1], c[2], c[3], c[4])
    l:Show()
end

local function Dot(x, y, size, c)
    nDots = nDots + 1
    local t = dots[nDots]
    if not t then
        t = canvas:CreateTexture(nil, "OVERLAY", nil, 1)
        t:SetTexture("Interface\\Buttons\\WHITE8X8")
        dots[nDots] = t
    end
    t:SetSize(size, size)
    t:ClearAllPoints()
    t:SetPoint("CENTER", canvas, "TOPLEFT", x * cw, -y * ch)
    t:SetVertexColor(c[1], c[2], c[3], c[4])
    t:Show()
end

local function Cell(x1, y1, x2, y2, c)
    nCells = nCells + 1
    local t = cells[nCells]
    if not t then
        t = canvas:CreateTexture(nil, "ARTWORK", nil, -1)
        t:SetTexture("Interface\\Buttons\\WHITE8X8")
        cells[nCells] = t
    end
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", canvas, "TOPLEFT", x1 * cw, -y1 * ch)
    t:SetPoint("BOTTOMRIGHT", canvas, "TOPLEFT", x2 * cw, -y2 * ch)
    t:SetVertexColor(c[1], c[2], c[3], c[4])
    t:Show()
end

local function Note(x, y, text)
    nNotes = nNotes + 1
    local f = notes[nNotes]
    if not f then
        f = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        notes[nNotes] = f
    end
    f:ClearAllPoints()
    f:SetPoint("BOTTOM", canvas, "TOPLEFT", x * cw, -y * ch + 6)
    f:SetText(text)
    f:Show()
end

-- A flight master: an icon with its name under the cursor.
local function FlightPin(x, y, name, known)
    nFps = nFps + 1
    local b = fps[nFps]
    if not b then
        b = CreateFrame("Frame", nil, canvas)
        b:SetSize(16, 16)
        b.icon = b:CreateTexture(nil, "OVERLAY", nil, 2)
        b.icon:SetAllPoints()
        b:EnableMouse(true)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.name, 1, 1, 1)
            GameTooltip:AddLine(self.known and "Flight master: you know this flight point."
                or "Flight master: talk to them to learn this flight point.",
                self.known and 0.3 or 1, self.known and 1 or 0.82, self.known and 0.3 or 0, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        fps[nFps] = b
    end
    b.name, b.known = name, known
    b:SetFrameLevel(canvas:GetFrameLevel() + 6)
    b.icon:SetTexture(known and "Interface\\TaxiFrame\\UI-Taxi-Icon-Green" or "Interface\\TaxiFrame\\UI-Taxi-Icon-Yellow")
    b:ClearAllPoints()
    b:SetPoint("CENTER", canvas, "TOPLEFT", x * cw, -y * ch)
    b:Show()
end

local function Polyline(pts, c, thick)
    for k = 1, #pts - 3, 2 do Line(pts[k], pts[k + 1], pts[k + 2], pts[k + 3], c, thick) end
end

-- The flight masters on whatever map is shown.
local function DrawFlights(view)
    local known = ns.KnownFlights and ns.KnownFlights() or {}
    for id, node in pairs(ns.FLIGHT_NODES or {}) do
        if not ns.FlightForMe or ns.FlightForMe(node.side) then
            local cont = ns.CONTINENT_YARDS and ns.CONTINENT_YARDS[node.continent]
            local r = cont and ns.MapRect and ns.MapRect(view.map, cont.map)
            local x, y
            if cont and view.map == cont.map then
                x, y = node.x, node.y
            elseif r then
                x, y = (node.x - r.l) / (r.r - r.l), (node.y - r.t) / (r.b - r.t)
            end
            if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                FlightPin(x, y, node.name, known[id] and true or false)
            end
        end
    end
end

local GROUND = { 0.2, 0.8, 1, 0.16 }
local function DrawGround(zone)
    local t = ns.TERRITORY and ns.TERRITORY[zone.ach]
    if not t then return end
    for r, runs in ipairs(t.runs) do
        local y1 = (r - 1 - t.margin) / t.rows
        for k = 1, #runs - 1, 2 do
            Cell((runs[k] - t.margin) / t.cols, y1, (runs[k + 1] + 1 - t.margin) / t.cols, y1 + 1 / t.rows, GROUND)
        end
    end
end

-- The game's own data for the zone's map (Data/MapData.lua).
local EDGE, CROSS, PLACE, TRIGGER, HIT = { 1, 1, 1, 0.8 }, { 0.2, 1, 0.6, 1 }, { 1, 0.9, 0.6, 1 },
    { 1, 0.3, 0.8, 0.9 }, { 0.5, 0.8, 1, 0.7 }
local function MapData(zone)
    return ns.MAPDATA and ns.MAPDATA[zone.ach]
end

local function DrawBorder(zone)
    local d = MapData(zone)
    for _, r in ipairs(d and d.border or {}) do
        local pts = {}
        for k = 1, #r do pts[k] = r[k] / 10000 end
        pts[#pts + 1], pts[#pts + 2] = r[1] / 10000, r[2] / 10000
        Polyline(pts, EDGE, 2)
    end
end

local function DrawCrossings(zone)
    local d = MapData(zone)
    for _, c in ipairs(d and d.crossings or {}) do
        local x, y = c[1] / 10000, c[2] / 10000
        Dot(x, y, 12, { 0, 0, 0, 0.8 })
        Dot(x, y, 8, CROSS)
        Note(x, y, string.format("|cff33ff99to %s (%d)|r", c[3], c[4]))
    end
end

local function DrawPlaces(zone)
    local d = MapData(zone)
    for _, p in ipairs(d and d.places or {}) do
        local x, y = p[1] / 10000, p[2] / 10000
        Dot(x, y, 5, PLACE)
        Note(x, y, "|cffffe699" .. p[3] .. "|r")
    end
end

local function DrawTriggers(zone)
    local d = MapData(zone)
    for _, t in ipairs(d and d.triggers or {}) do
        local x, y, rad, bl, bw, yaw = t[1] / 10000, t[2] / 10000, t[3], t[4], t[5], t[6]
        local pts = {}
        if rad > 0 then
            for q = 0, 24 do
                local a = q / 24 * 2 * math.pi
                pts[#pts + 1] = x + math.cos(a) * rad / zone.w
                pts[#pts + 1] = y + math.sin(a) * rad / zone.h
            end
        elseif bl > 0 then
            -- a box: length along the yaw (world north), width across; on the
            -- map north is up and west is left
            local cs, sn = math.cos(yaw), math.sin(yaw)
            for _, k in ipairs({ { 1, 1 }, { 1, -1 }, { -1, -1 }, { -1, 1 }, { 1, 1 } }) do
                local north, west = k[1] * bl / 2, k[2] * bw / 2
                local n2, w2 = north * cs - west * sn, north * sn + west * cs
                pts[#pts + 1] = x - w2 / zone.w
                pts[#pts + 1] = y - n2 / zone.h
            end
        end
        if #pts >= 4 then Polyline(pts, TRIGGER, 1.5) end
        Dot(x, y, 4, TRIGGER)
    end
end

local function DrawHits(zone)
    local d = MapData(zone)
    for _, h in ipairs(d and d.hits or {}) do
        local l, t, r, b = h[1] / 10000, h[2] / 10000, h[3] / 10000, h[4] / 10000
        Polyline({ l, t, r, t, r, b, l, b, l, t }, HIT, 1.5)
        Note((l + r) / 2, t, "|cff80ccff" .. h[5] .. "|r")
    end
end

-- Built-in lines (thin): the player's own are drawn by the editing tools.
local BUILT = {
    walls = { "WALLS", { 1, 0.25, 0.2, 0.8 } },
    zonelines = { "ZONELINES", { 0.8, 0.45, 1, 0.8 } },
    roads = { "ROADS", { 0.6, 1, 0.05, 0.8 } },
    ledges = { "LEDGES", { 1, 0.55, 0.1, 0.8 } },
}
local function DrawBuiltIn(zone)
    if ns.TakenOver and ns.TakenOver(zone) then return end
    for kind, b in pairs(BUILT) do
        local all = ns[b[1]] and ns[b[1]][zone.ach]
        if all and ns.LayerOn(kind) then
            for _, line in ipairs(all) do
                if line.circle then
                    local c = line.circle
                    local pts = {}
                    for q = 0, 36 do
                        local a = q / 36 * 2 * math.pi
                        pts[#pts + 1] = c[1] + math.cos(a) * c[3] / zone.w
                        pts[#pts + 1] = c[2] + math.sin(a) * c[3] / zone.h
                    end
                    Polyline(pts, b[2], 1.5)
                else
                    Polyline(line, b[2], 1.5)
                    if kind == "ledges" then
                        for _, t in ipairs(ns.LedgeTicks(line, cw, ch)) do
                            Line(t[1] / cw, t[2] / ch, t[3] / cw, t[4] / ch, b[2], 1.5)
                        end
                    end
                end
            end
        end
    end
end

local LINK = {
    open = { 0.9, 0.9, 0.9, 0.25 }, cut = { 1, 0.2, 0.2, 0.7 }, oneway = { 1, 0.55, 0.1, 0.8 },
    zoneline = { 0.8, 0.45, 1, 0.8 }, road = { 0.6, 1, 0.05, 0.6 },
}
local waiting
local function DrawGraph(zone)
    local pts, links = ns.GraphOnZone(zone)
    if not pts then
        -- the network is still being read: look again in a moment
        if not waiting and C_Timer and C_Timer.After then
            waiting = true
            C_Timer.After(1, function()
                waiting = false
                ns.WindowRedraw()
            end)
        end
        return
    end
    for _, l in ipairs(links) do Line(l[1], l[2], l[3], l[4], LINK[l[5]], 1) end
    for _, p in ipairs(pts) do Dot(p[1], p[2], p[3] and 3 or 4, p[3] and LINK.road or { 1, 1, 1, 0.7 }) end
end

local RIDE = { 0.3, 0.9, 1, 1 }
local function DrawRides(zone)
    for _, l in ipairs(ns.LINKS or {}) do
        local a = l.a.map == zone.map and l.a
        local b = l.b.map == zone.map and l.b
        if a and b then Line(a.x, a.y, b.x, b.y, RIDE, 1.5) end
        for _, e in ipairs({ a, b }) do
            if e then
                Dot(e.x, e.y, 9, RIDE)
                Note(e.x, e.y, l.kind .. " to " .. (e == l.a and l.b.place or l.a.place))
            end
        end
    end
end

local CUT = { 1, 0.15, 0.15, 1 }
local function DrawCutOff(zone)
    local cut, others = ns.ZoneCutOff(zone)
    if not cut then
        Note(0.5, 0.04, "|cffff5555Working out which areas can be reached...|r")
        return
    end
    local any = false
    for node, reach in pairs(cut) do
        any = true
        local area = ns.AreaOf and ns.AreaOf(node)
        local m = ns.NodeMarker(node)
        if area then
            for _, r in ipairs(area.rings) do
                local pts = {}
                for k = 1, #r do pts[k] = r[k] end
                pts[#pts + 1], pts[#pts + 2] = r[1], r[2]
                Polyline(pts, CUT, 2.5)
            end
        end
        Dot(m[1], m[2], 10, CUT)
        Note(m[1], m[2], string.format("|cffff5555%s: reaches %d/%d|r", node.name, reach, others))
    end
    if not any then Note(0.5, 0.04, "|cff55dd55Every area can be reached from every other.|r") end
end

function ns.DrawLayers()
    local view
    canvas, cw, ch, view = ns.WindowMapSpace()
    if not canvas then return end
    nLines, nDots, nCells, nFps, nNotes = 0, 0, 0, 0, 0
    for _, list in ipairs({ lines, dots, cells, fps, notes }) do
        for _, o in ipairs(list) do o:Hide() end
    end
    if ns.LayerOn("fp") then DrawFlights(view) end
    local zone = view.kind == "zone" and view.zone
    if not zone then return end
    if ns.LayerOn("ground") then DrawGround(zone) end
    if ns.LayerOn("graph") and canvas.CreateLine then DrawGraph(zone) end
    if ns.LayerOn("builtin") and canvas.CreateLine then DrawBuiltIn(zone) end
    if ns.LayerOn("hits") and canvas.CreateLine then DrawHits(zone) end
    if ns.LayerOn("border") and canvas.CreateLine then DrawBorder(zone) end
    if ns.LayerOn("triggers") and canvas.CreateLine then DrawTriggers(zone) end
    if ns.LayerOn("places") then DrawPlaces(zone) end
    if ns.LayerOn("crossings") then DrawCrossings(zone) end
    if ns.LayerOn("rides") and canvas.CreateLine then DrawRides(zone) end
    if ns.LayerOn("cutoff") and canvas.CreateLine then DrawCutOff(zone) end
end

ns.On("plancosts", function()
    if ns.LayerOn("cutoff") then ns.WindowRedraw() end
end)

-------------------------------------------------------------------------------
-- The Layers button and its list
-------------------------------------------------------------------------------

local panel
local function BuildPanel(button)
    panel = CreateFrame("Frame", nil, button, "BackdropTemplate")
    panel:SetFrameLevel(button:GetFrameLevel() + 10)
    panel:EnableMouse(true)
    if panel.SetBackdrop then
        panel:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 14,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        panel:SetBackdropColor(0.06, 0.05, 0.04, 0.95)
        panel:SetBackdropBorderColor(0.8, 0.65, 0.3)
    end
    panel:SetPoint("TOPRIGHT", button, "BOTTOMRIGHT", 0, -2)
    panel.boxes = {}
    panel:Hide()
end

local function FillPanel()
    for _, b in ipairs(panel.boxes) do b:Hide() end
    local y, n = -8, 0
    local mapper = ns.CanEdit()
    for _, L in ipairs(LAYERS) do
        if mapper or not L.mapper then
            n = n + 1
            local box = panel.boxes[n]
            if not box then
                box = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
                box:SetSize(22, 22)
                box.label = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                box.label:SetPoint("LEFT", box, "RIGHT", 2, 0)
                box:SetScript("OnClick", function(self) SetLayer(self.key, self:GetChecked()) end)
                box:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                    GameTooltip:AddLine(self.title, 1, 1, 1)
                    GameTooltip:AddLine(self.tip, 1, 0.82, 0, true)
                    GameTooltip:Show()
                end)
                box:SetScript("OnLeave", function() GameTooltip:Hide() end)
                panel.boxes[n] = box
            end
            box.key, box.title, box.tip = L.key, L.label, L.tip
            box.label:SetText(L.label)
            box:SetChecked(ns.LayerOn(L.key))
            box:ClearAllPoints()
            box:SetPoint("TOPLEFT", 8, y)
            box:Show()
            y = y - 22
        end
    end
    panel:SetSize(190, -y + 8)
end

-- Made by UI.lua with the window, in the map's top right corner.
function ns.MakeLayersButton(parent, anchor)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(64, 22)
    b:SetText("Layers")
    b:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -6, -6)
    BuildPanel(b)
    b:SetScript("OnClick", function()
        if panel:IsShown() then
            panel:Hide()
        else
            FillPanel()
            panel:Show()
        end
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Layers", 1, 1, 1)
        GameTooltip:AddLine("What to show on the map.", 1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

-------------------------------------------------------------------------------
-- /cf data: everything a zone's map holds, in numbers
-------------------------------------------------------------------------------

function ns.ZoneDataSummary(zone)
    local out = {}
    local function Add(text) out[#out + 1] = text end
    local outlined, mapOnly = 0, 0
    for _, node in ipairs(zone.nodes) do
        if ns.AreaOf and ns.AreaOf(node) then outlined = outlined + 1 end
        if node.mapOnly then mapOnly = mapOnly + 1 end
    end
    Add(string.format("%s (Explore achievement %d, map %d): %.0f x %.0f yards", zone.name, zone.ach, zone.map,
        zone.w, zone.h))
    Add(string.format("  areas: %d (%d outlined, %d on the map only)", #zone.nodes, outlined, mapOnly))
    local d = MapData(zone)
    if d then
        local ways = {}
        for _, c in ipairs(d.crossings) do ways[#ways + 1] = string.format("%s (%d)", c[3], c[4]) end
        Add(string.format("  from the game: %d place names, %d area triggers, %d hover boxes, edge of %d ring%s",
            #d.places, #d.triggers, #d.hits, #d.border, #d.border == 1 and "" or "s"))
        Add("  ways in and out: " .. (#ways > 0 and table.concat(ways, ", ") or "none"))
    end
    for _, k in ipairs({ { "walls", "WALLS" }, { "zonelines", "ZONELINES" }, { "roads", "ROADS" }, { "ledges", "LEDGES" } }) do
        local built = ns[k[2]] and ns[k[2]][zone.ach]
        local mine = ns.OwnLines(zone, k[1])
        Add(string.format("  %s: %d built in, %d your own%s", k[1], built and #built or 0, mine and #mine or 0,
            (ns.TakenOver and ns.TakenOver(zone)) and " (built-in taken over)" or ""))
    end
    local t = ns.TERRITORY and ns.TERRITORY[zone.ach]
    if t then
        local n = 0
        for _, runs in ipairs(t.runs) do
            for k = 1, #runs - 1, 2 do n = n + runs[k + 1] - runs[k] + 1 end
        end
        Add(string.format("  ground: %d cells of 33 yards (%d x %d grid, %d margin)", n, t.cols, t.rows, t.margin))
    end
    local fp, known = 0, 0
    local mine = ns.KnownFlights and ns.KnownFlights() or {}
    for id, node in pairs(ns.FLIGHT_NODES or {}) do
        local where = node.name:match(",%s*(.+)$")
        if where and zone.name:sub(1, #where) == where and (not ns.FlightForMe or ns.FlightForMe(node.side)) then
            fp = fp + 1
            if mine[id] then known = known + 1 end
        end
    end
    Add(string.format("  flight masters: %d for your faction, %d known", fp, known))
    local pts, links = ns.GraphOnZone(zone)
    if pts then
        local by = {}
        for _, l in ipairs(links) do by[l[5]] = (by[l[5]] or 0) + 1 end
        Add(string.format("  walking network: %d waypoints, %d links (%d cut by walls, %d one way, %d zone line, %d road)",
            #pts, #links, by.cut or 0, by.oneway or 0, by.zoneline or 0, by.road or 0))
    else
        Add("  walking network: still being read, ask again in a moment")
    end
    local cut, others = ns.ZoneCutOff(zone)
    if cut then
        local names = {}
        for node, reach in pairs(cut) do names[#names + 1] = string.format("%s (%d/%d)", node.name, reach, others) end
        table.sort(names)
        Add(#names == 0 and "  every area reaches every other"
            or "  can't reach every other area: " .. table.concat(names, ", "))
    else
        Add("  reachability: being worked out, ask again in a moment")
    end
    return out
end
