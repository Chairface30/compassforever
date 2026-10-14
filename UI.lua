-- Compass Forever: UI.lua
-- The window. Zones down the left with how much of each is uncovered; on the
-- right a map that works like the world map:
--
--   Azeroth    - both continents, each with its progress; click one to open it.
--   continent  - its zones, each with what is left; hover one to light it up,
--                click it to open it. Right-click goes back to Azeroth.
--   zone       - the zone's own map: what you have uncovered in color, what is
--                still covered in gray, each area's outline, the route as a
--                line, and you. Click an area to go there next. Right-click
--                goes back to the continent.
--
-- The mouse wheel zooms any of them in and out around the cursor (out past
-- full size goes up a level), and a zoomed map can be dragged around.
--
-- A trail above the map (Azeroth > Eastern Kingdoms > Elwynn Forest) can be
-- clicked too. Map art is read from the client and drawn on our own
-- textures; no Blizzard frame is touched.

local _, ns = ...

-- The layout, in one place. Left: continent tabs over the zone list, in an
-- inset. Right: the trail and zoom buttons over the map, and under it what
-- the map shows, with the route buttons beside it. Every line of text has a
-- width, so none of it runs into the next thing.
local W, H = 900, 616
local PAD = 16
local LIST_W = 248                  -- the list's inset, scroll bar included
local ROW_W = LIST_W - 38           -- a row, leaving the scroll bar room
local MAP_W, MAP_H = 600, 400
local MAP_X = PAD + LIST_W + 12     -- the map's border, from the frame's left
local TOP = -80                     -- where the list inset and the map border start
local BUTTON_W = 140
local TEXT_W = MAP_W - BUTTON_W - 16
local ROW_H = 44
local GREEN, GOLD, GRAY = "|cff55dd55", "|cffffd100", "|cff999999"
local HERE_RGB, ROUTE_RGB = { 0.4, 0.8, 1 }, { 0.33, 0.87, 0.33 }

local WORLD = 947
local CONTINENT_MAP = { [0] = 1415, [1] = 1414 }
local CONTINENT_NAME = { [0] = "Eastern Kingdoms", [1] = "Kalimdor" }

local frame, mapBox, scroll, listChild
local overallBar, contButtons, trail, strip, zoomIn, zoomOut
local optionsButton, options, optionBoxes
local zoneTitle, zoneInfo, nextInfo, hint, routeButton, skipButton
local scrolledTo
local zoneRows = {}
local continent = 0          -- the continent the list shows
local view = { kind = "continent", map = CONTINENT_MAP[0] }
local Refresh

-- Everything on the map is drawn on `canvas`, MAP_W x MAP_H times `zoom`,
-- inside the clipped mapBox. offX, offY: how far the canvas's top-left sits
-- left of and above the box's.
local canvas
local zoom, offX, offY = 1, 0, 0
-- After Me: the map keeps you in its middle as you move, onto the next map
-- when you cross into one. Dragging the map, or opening another, stops it.
local follow = false
local function SetFollow(on)
    follow = on and true or false
    if frame and frame.meButton then
        frame.meButton:SetText(follow and "|cff55ddffMe|r" or "Me")
    end
end
local ZOOM_MAX, ZOOM_STEP = 4, 1.25
local function CW() return MAP_W * zoom end
local function CH() return MAP_H * zoom end

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
    -- kept inside the bar: cut short rather than running past its ends
    bar.text:SetPoint("LEFT", 4, 0)
    bar.text:SetPoint("RIGHT", -4, 0)
    pcall(bar.text.SetWordWrap, bar.text, false)
    return bar
end

local function SetBar(bar, done, total)
    bar:SetValue(total > 0 and done / total or 0)
    if done == total then bar:SetStatusBarColor(0.25, 0.8, 0.3)
    else bar:SetStatusBarColor(0.95, 0.7, 0.15) end
end

-- One line of text that stops at `width` instead of running on.
local function Label(parent, font, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", font)
    fs:SetJustifyH("LEFT")
    if width then fs:SetWidth(width) end
    pcall(fs.SetWordWrap, fs, false)
    return fs
end

-- Text that wraps at `width`, at most `lines` lines.
local function Para(parent, font, width, lines)
    local fs = parent:CreateFontString(nil, "OVERLAY", font)
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetWidth(width)
    pcall(fs.SetWordWrap, fs, true)
    if lines then pcall(fs.SetMaxLines, fs, lines) end
    return fs
end

local function Inset(parent)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        f:SetBackdropColor(0, 0, 0, 0.45)
        f:SetBackdropBorderColor(0.6, 0.5, 0.3)
    end
    return f
end

local function Tip(owner, title, text)
    owner:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title, 1, 1, 1)
        if text then GameTooltip:AddLine(text, 1, 0.82, 0, true) end
        GameTooltip:Show()
    end)
    owner:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- A setting: a box, its name, and a short line under it saying what it does.
local function Check(parent, label, desc, tip, onClick)
    local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    c:SetSize(24, 24)
    c.label = Label(c, "GameFontHighlight", 230)
    c.label:SetPoint("TOPLEFT", c, "TOPRIGHT", 2, -4)
    c.label:SetText(label)
    c.desc = Label(c, "GameFontDisableSmall", 230)
    c.desc:SetPoint("TOPLEFT", c.label, "BOTTOMLEFT", 0, -2)
    c.desc:SetText(desc)
    c:SetHitRectInsets(0, -232, 0, -10)
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

local function ResetZoom()
    zoom, offX, offY = 1, 0, 0
    SetFollow(false)
end

local function ShowZoneView(zone)
    ResetZoom()
    view = { kind = "zone", map = zone.map, zone = zone }
    continent = zone.continent
    Refresh()
end

local function ShowContinentView(c)
    ResetZoom()
    view = { kind = "continent", map = CONTINENT_MAP[c] }
    continent = c
    Refresh()
end

local function ShowWorldView()
    ResetZoom()
    view = { kind = "world", map = WORLD }
    Refresh()
end

-- Any other map (a city, a map inside a zone): its art, you and the route,
-- but no areas to explore. The window can open every map the world map can.
local function MapInfo(mapID)
    local ok, info = ns.Ask(ns.API("C_Map", "GetMapInfo"), mapID)
    return ok and type(info) == "table" and info or nil
end

-- The continent a map is on (0 or 1), from its parents.
local function ContinentAbove(mapID)
    for _ = 1, 8 do
        if not mapID then return nil end
        local c = ContinentOfMap(mapID)
        if c then return c end
        local info = MapInfo(mapID)
        mapID = info and ns.Num(info.parentMapID)
    end
    return nil
end

local function ShowMapView(mapID)
    ResetZoom()
    local info = MapInfo(mapID)
    view = { kind = "map", map = mapID, name = info and ns.Text(info.name) or "Map" }
    continent = ContinentAbove(mapID) or continent
    Refresh()
end

-- Open whichever view suits a map: a zone, a continent, Azeroth or a map.
local function OpenMap(mapID)
    local zone = mapID and ns.ZoneByMap(mapID)
    if zone then return ShowZoneView(zone) end
    local c = mapID and ContinentOfMap(mapID)
    if c then return ShowContinentView(c) end
    if not mapID or mapID == WORLD then return ShowWorldView() end
    ShowMapView(mapID)
end

-- Right-click: one level up.
local function ZoomOut()
    if view.kind == "zone" then ShowContinentView(view.zone.continent)
    elseif view.kind == "continent" then ShowWorldView()
    elseif view.kind == "map" then
        local info = MapInfo(view.map)
        local parent = info and ns.Num(info.parentMapID)
        if parent and parent > 0 then OpenMap(parent) else ShowContinentView(continent) end
    end
end

-------------------------------------------------------------------------------
-- The zone list
-------------------------------------------------------------------------------

local function ZoneTooltip(owner, zone, anchor)
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    local d, t = ns.ZoneCounts(zone)
    GameTooltip:AddLine(zone.name, 1, 1, 1)
    if zone == ns.CurrentZone() then GameTooltip:AddLine("You are here.", unpack(HERE_RGB)) end
    if ns.route and ns.route.zone == zone then GameTooltip:AddLine("Your current route.", unpack(ROUTE_RGB)) end
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
    -- A row: the name (cut short if need be) with what is left at the right,
    -- a line saying you are here or on its route, and a bar. A stripe down
    -- the left edge says the same at a glance.
    row = CreateFrame("Button", nil, listChild)
    row:SetSize(ROW_W, ROW_H - 3)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 0.82, 0, 0.12)
    row.stripe = row:CreateTexture(nil, "ARTWORK")
    row.stripe:SetPoint("TOPLEFT")
    row.stripe:SetPoint("BOTTOMLEFT")
    row.stripe:SetWidth(3)
    row.count = Label(row, "GameFontHighlightSmall")
    row.count:SetPoint("TOPRIGHT", -8, -7)
    row.count:SetJustifyH("RIGHT")
    row.name = Label(row, "GameFontNormal", ROW_W - 72)
    row.name:SetPoint("TOPLEFT", 10, -6)
    row.status = Label(row, "GameFontHighlightSmall", ROW_W - 18)
    row.status:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
    row.bar = Bar(row, ROW_W - 18, 4)
    row.bar:SetPoint("BOTTOMLEFT", 10, 6)
    row:SetScript("OnClick", function(self) ShowZoneView(self.zone) end)
    row:SetScript("OnEnter", function(self) ZoneTooltip(self, self.zone) end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    zoneRows[i] = row
    return row
end

-- A zone's name as shown: purple once mapped by hand (built in), with a gold
-- asterisk while it's marked done and waiting to be built in.
local HAND = "|cffcc88ff"
local function ZoneName(zone, dim)
    local color = ns.ZoneHandMapped(zone) and HAND or (dim and GRAY or "")
    local mark = ns.ZoneMarkedDone(zone) and (GOLD .. " *|r") or ""
    return color .. zone.name .. "|r" .. mark
end

local function RefreshList()
    local here = ns.CurrentZone()
    local n, selected = 0, nil
    for _, zone in ipairs(ns.ZONES) do
        if zone.continent == continent then
            n = n + 1
            local row = ZoneRow(n)
            row.zone = zone
            local d, t = ns.ZoneCounts(zone)
            local isHere = zone == here
            local routed = ns.route and ns.route.zone == zone
            row.name:SetText(ZoneName(zone, d == t))
            row.count:SetText(d == t and (GREEN .. "Done|r") or (GOLD .. (t - d) .. " left|r"))
            if isHere and routed then
                row.status:SetText("|cff66ccffYou are here|r" .. GRAY .. ", |r|cff55dd55on your route|r")
            elseif routed then
                row.status:SetText("|cff55dd55On your route|r")
            elseif isHere then
                row.status:SetText("|cff66ccffYou are here|r")
            else
                row.status:SetText(GRAY .. d .. " of " .. t .. " areas|r")
            end
            local rgb = routed and ROUTE_RGB or (isHere and HERE_RGB)
            if rgb then row.stripe:SetColorTexture(rgb[1], rgb[2], rgb[3], 1) end
            row.stripe:SetShown(rgb and true or false)
            SetBar(row.bar, d, t)
            if view.zone == zone then
                selected = n
                row.bg:SetColorTexture(1, 0.82, 0, 0.2)
            else
                row.bg:SetColorTexture(1, 1, 1, n % 2 == 0 and 0.03 or 0.06)
            end
            row:Show()
        end
    end
    for i = n + 1, #zoneRows do zoneRows[i]:Hide() end
    listChild:SetHeight(math.max(1, n * ROW_H))
    for _, b in ipairs(contButtons) do
        if b.continent == continent then b:LockHighlight() else b:UnlockHighlight() end
    end
    -- Bring a newly opened zone into the list's view, once: after that the
    -- list stays where the player scrolls it.
    local h = ns.Num(scroll:GetHeight()) or 0
    if selected and scrolledTo ~= view.zone and h > 0 then
        scrolledTo = view.zone
        local cur = ns.Num(scroll:GetVerticalScroll()) or 0
        local top = (selected - 1) * ROW_H
        local want = cur
        if top < cur then want = top
        elseif top + ROW_H > cur + h then want = top + ROW_H - h end
        want = math.max(0, math.min(want, n * ROW_H - h))
        if want ~= cur then pcall(scroll.SetVerticalScroll, scroll, want) end
    elseif not selected then
        scrolledTo = nil
    end
end

-------------------------------------------------------------------------------
-- The map
-------------------------------------------------------------------------------

local baseTiles, colorArt, grayArt
local pins, badges, lines = {}, {}, {}
local playerDot, highlight
local hasLines
-- Wall mode: clicks on a zone's map draw walls (Pathing.lua) instead.
local wallMode, drawing, wallButton = false, nil, nil
local editKind = "walls"      -- what wall mode draws: "walls" or "roads"
local circleCenter            -- a circle's middle, set by its first Shift-click
local wallLines = {}
local WallClick

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
    local scale = CW() / lw
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
    -- art the map shows for an area the Legacy challenge hasn't on this
    -- character stays gray (Progress.lua)
    local notYet = {}
    if zone then
        local state = ns.ZoneState(zone).state
        for i, node in ipairs(zone.nodes) do
            if node.ox and state[i] ~= true then notYet[node.ox .. ":" .. node.oy] = true end
        end
    end
    if okE and type(explored) == "table" then
        for _, info in ipairs(explored) do
            local ids = info.fileDataIDs
            local texW, texH = ns.Num(info.textureWidth), ns.Num(info.textureHeight)
            local ox, oy = ns.Num(info.offsetX), ns.Num(info.offsetY)
            if type(ids) == "table" and texW and texH and ox and oy and not info.isShownByMouseOver
                    and not notYet[ox .. ":" .. oy] then
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
    if zone and wallMode then
        -- drawing walls: every area uncovered, in color, to see the ground
        for _, node in ipairs(zone.nodes) do
            if node.files and #node.files > 0 then
                ns.EachTile(node.ox, node.oy, node.tw, node.th, node.files, tw, th,
                    function(file, x, y, w, h, u, v)
                        local t = colorArt:Next()
                        t:SetTexture(file)
                        t:SetTexCoord(0, u, 0, v)
                        t:SetSize(w * scale, h * scale)
                        t:ClearAllPoints()
                        t:SetPoint("TOPLEFT", x * scale, -y * scale)
                        if t.SetDesaturated then t:SetDesaturated(false) end
                        t:SetVertexColor(1, 1, 1, 1)
                    end)
            end
        end
    elseif zone then
        ns.DrawCoveredGray(grayArt, zone, scale)
    end
end

-- Where the cursor is on the map, as fractions; nil when off it.
-- The cursor in the box, in pixels from its top-left; nil when off it.
local function CursorInBox()
    local okC, cx, cy = pcall(GetCursorPosition)
    if not okC or not cx then return nil end
    local s = mapBox:GetEffectiveScale()
    local left, top = mapBox:GetLeft(), mapBox:GetTop()
    if not (s and left and top) then return nil end
    local bx, by = cx / s - left, top - cy / s
    if bx < 0 or bx > MAP_W or by < 0 or by > MAP_H then return nil end
    return bx, by
end

-- The cursor as a fraction of the shown map, however far it is zoomed.
local function CursorOnMap()
    local bx, by = CursorInBox()
    if not bx then return nil end
    return (offX + bx) / CW(), (offY + by) / CH()
end

-- The map under a point of the shown map: a zone (on a continent) or a
-- continent (on Azeroth).
local function MapAt(x, y)
    local ok, info = ns.Ask(ns.API("C_Map", "GetMapInfoAtPosition"), view.map, x, y)
    return ok and type(info) == "table" and ns.Num(info.mapID) or nil
end

local function Target(x, y)
    local mapID = MapAt(x, y)
    if not mapID or mapID == view.map then return nil end
    if view.kind == "world" then
        local c = ContinentOfMap(mapID)
        return c and { continent = c } or nil
    end
    local zone = ns.ZoneByMap(mapID)
    if zone then return { zone = zone } end
    return { map = mapID }
end

-- The area of the shown zone under a point, by its outline (Areas.lua);
-- nil outside every outline, or off a zone's map.
local function AreaAt(x, y)
    if view.kind ~= "zone" or not x then return nil end
    for _, node in ipairs(view.zone.nodes) do
        if ns.InArea(node, x, y) then return node end
    end
    return nil
end

-- On a zone's map, the area under the cursor says its name.
local function AreaTooltip(node)
    local zone = view.zone
    GameTooltip:SetOwner(mapBox, "ANCHOR_CURSOR")
    GameTooltip:AddLine(node.name, 1, 1, 1)
    if node.mapOnly then
        GameTooltip:AddLine("On the map only: the Explore achievement doesn't count it.", 0.7, 0.7, 0.7, true)
    end
    local order
    if ns.route and ns.route.zone == zone then
        for i, stop in ipairs(ns.route.stops) do
            if stop.node == node then order = i end
        end
    end
    local state = ns.ZoneState(zone).state
    for i, n in ipairs(zone.nodes) do
        if n == node and state[i] == true then GameTooltip:AddLine("Uncovered.", 0.3, 0.9, 0.3) end
    end
    if order then
        GameTooltip:AddLine(order == 1 and "Your next stop." or "Stop " .. order .. " of the route.", 1, 0.82, 0)
    end
    GameTooltip:AddLine("Click to go here.", 0.6, 1, 0.6)
    GameTooltip:Show()
end

-- Light up what the cursor is over, as the world map does.
local hovered
local function Hover()
    if view.kind == "zone" and not wallMode and mapBox:IsMouseOver() then
        local node = AreaAt(CursorOnMap())
        if node == hovered then return end
        hovered = node
        highlight:Hide()
        if node then AreaTooltip(node) else GameTooltip:Hide() end
        return
    end
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
    local key = target and (target.zone or target.continent or target.map)
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
        highlight:SetSize(tx * CW(), ty * CH())
        highlight:ClearAllPoints()
        highlight:SetPoint("TOPLEFT", canvas, "TOPLEFT", sx * CW(), -sy * CH())
        highlight:Show()
    end
    if target.zone then
        ZoneTooltip(mapBox, target.zone, "ANCHOR_CURSOR")
        GameTooltip:AddLine("Click to open. Right-click to see Azeroth.", 0.6, 1, 0.6)
        GameTooltip:Show()
    elseif target.map then
        local info = MapInfo(target.map)
        GameTooltip:SetOwner(mapBox, "ANCHOR_CURSOR")
        GameTooltip:AddLine(info and ns.Text(info.name) or "Map", 1, 1, 1)
        GameTooltip:AddLine("Click to open.", 0.6, 1, 0.6)
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

local function PlaceCanvas()
    offX = math.max(0, math.min(CW() - MAP_W, offX))
    offY = math.max(0, math.min(CH() - MAP_H, offY))
    canvas:SetSize(CW(), CH())
    canvas:ClearAllPoints()
    canvas:SetPoint("TOPLEFT", mapBox, "TOPLEFT", -offX, offY)
end

local DrawMap

-- The wheel: zoom around the point under the cursor, which stays put.
-- Out past full size goes up a level, as the world map does.
local function OnWheel(_, delta)
    local old = zoom
    if delta > 0 then
        zoom = math.min(ZOOM_MAX, zoom * ZOOM_STEP)
    elseif zoom <= 1.001 then
        ZoomOut()
        return
    else
        zoom = math.max(1, zoom / ZOOM_STEP)
    end
    if zoom == old then return end
    local bx, by = CursorInBox()
    bx, by = bx or MAP_W / 2, by or MAP_H / 2
    local fx, fy = (offX + bx) / (MAP_W * old), (offY + by) / (MAP_H * old)
    offX, offY = fx * CW() - bx, fy * CH() - by
    PlaceCanvas()
    DrawMap()
end

-- The Me button: the zone you are in, zoomed in (if it was at full size)
-- and centered on you.
local CENTER_ZOOM = 2
local function CenterOnMe()
    local here = ns.PlayerMap()
    local zone = here and ns.ZoneByMap(here) or (not here and ns.CurrentZone())
    local mapID
    if zone then
        if not (view.kind == "zone" and view.zone == zone) then ShowZoneView(zone) end
        mapID = zone.map
    elseif here then
        if view.map ~= here then OpenMap(here) end
        mapID = here
    else
        ns.Print("Can't tell where you are.")
        return
    end
    local px, py = ns.PlayerOn(mapID)
    if not (px and py) then return end
    if zoom < CENTER_ZOOM then zoom = CENTER_ZOOM end
    offX, offY = px * CW() - MAP_W / 2, py * CH() - MAP_H / 2
    PlaceCanvas()
    SetFollow(true)
    DrawMap()
end

-- Dragging a zoomed map moves it; a press that hardly moves is a click.
local drag
local function DragUpdate()
    if not drag then return end
    local okC, cx, cy = pcall(GetCursorPosition)
    if not okC or not cx then return end
    local s = mapBox:GetEffectiveScale()
    local dx, dy = (cx - drag.x) / s, (cy - drag.y) / s
    if math.abs(dx) + math.abs(dy) > 4 then drag.moved = true end
    if drag.moved then
        SetFollow(false)
        offX, offY = drag.offX - dx, drag.offY + dy
        PlaceCanvas()
    end
end

local function OnMapDown(_, button)
    if button ~= "LeftButton" or zoom <= 1.001 then return end
    local okC, cx, cy = pcall(GetCursorPosition)
    if not okC or not cx then return end
    drag = { x = cx, y = cy, offX = offX, offY = offY }
    mapBox:SetScript("OnUpdate", DragUpdate)
end

local function OnMapClick(_, button)
    if drag then
        local moved = drag.moved
        drag = nil
        mapBox:SetScript("OnUpdate", nil)
        if moved then return end
    end
    if wallMode and view.kind == "zone" then
        WallClick(button)
        return
    end
    if button == "RightButton" then
        ZoomOut()
        return
    end
    local x, y = CursorOnMap()
    -- an area with an outline: a route to it, as its marker's click was
    local node = AreaAt(x, y)
    if node then
        GameTooltip:Hide()
        ns.RouteVia(view.zone, node)
        return
    end
    local target = x and Target(x, y)
    if not target then return end
    hovered = nil
    highlight:Hide()
    GameTooltip:Hide()
    if target.zone then ShowZoneView(target.zone)
    elseif target.map then ShowMapView(target.map)
    else ShowContinentView(target.continent) end
end

local function Pin(i)
    return Pool(pins, i, function()
        local p = CreateFrame("Button", nil, canvas)
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
            local pt = ns.NodeMarker(self.node)
            GameTooltip:AddLine(string.format("%.1f, %.1f", pt[1] * 100, pt[2] * 100), 0.7, 0.7, 0.7)
            if self.done then
                GameTooltip:AddLine("Uncovered.", 0.3, 0.9, 0.3)
                GameTooltip:AddLine(self.order == 1 and "Your next stop." or "Click to go here.", 1, 0.82, 0)
            elseif self.node.fp then
                GameTooltip:AddLine("A flight master you haven't met: talk to them to learn this flight point.", 0.4, 0.75, 1, true)
                GameTooltip:AddLine(self.order == 1 and "Your next stop." or "Click to go here next.", 1, 0.82, 0)
            else
                if self.node.rough then
                    GameTooltip:AddLine("Approximate: this area has no ground of its own.", 1, 0.5, 0.5, true)
                end
                GameTooltip:AddLine(self.order == 1 and "Your next stop." or "Click to go here next.", 1, 0.82, 0)
            end
            GameTooltip:Show()
        end)
        p:SetScript("OnLeave", function() GameTooltip:Hide() end)
        p:SetScript("OnClick", function(self, button)
            if button == "RightButton" then ZoomOut()
            else ns.RouteVia(self.zone or view.zone, self.node) end
        end)
        return p
    end)
end

-- A count over each zone of a continent (or each continent of Azeroth).
local function Badge(i)
    return Pool(badges, i, function()
        local b = CreateFrame("Frame", nil, canvas)
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
    b:SetPoint("CENTER", canvas, "TOPLEFT", x * CW(), -y * CH())
end

-- Where `mapID` sits on the shown map: its middle, as fractions.
local function MiddleOn(mapID)
    local ok, left, right, top, bottom = ns.Ask(ns.API("C_Map", "GetMapRectOnMap"), mapID, view.map)
    if not (ok and ns.Num(left) and ns.Num(right) and ns.Num(top) and ns.Num(bottom)) then return nil end
    return (left + right) / 2, (top + bottom) / 2
end

local function Line(i)
    return Pool(lines, i, function()
        local l = canvas:CreateLine(nil, "ARTWORK")
        l:SetThickness(2)
        return l
    end)
end

-------------------------------------------------------------------------------
-- Walls and roads: drawn on a zone's map
-------------------------------------------------------------------------------
-- No path crosses a wall; paths keep to a road until they have to leave it.
-- Left-click adds a corner to the line being drawn, right-click finishes it
-- (or, with none being drawn, removes the segment under the cursor; with
-- Shift, its whole line). For walls,
-- Shift-click sets a circle's middle, a second Shift-click its edge: no path
-- enters it. A zone's lines become the player's own copy on the first change.

local WALL_COLOR = { 1, 0.25, 0.2, 0.95 }
local ROAD_COLOR = { 0.6, 1, 0.05, 1 }       -- bright lime green
local ZONE_LINE_COLOR = { 0.8, 0.45, 1, 1 }  -- purple

-- Only the player's own lines are drawn and edited; shipped ones (Data/)
-- still steer paths but stay out of sight.
local function Lines(zone, kind)
    return ns.OwnLines(zone, kind) or {}
end

local function WallLine(i)
    return Pool(wallLines, i, function()
        local l = canvas:CreateLine(nil, "OVERLAY")
        l:SetThickness(3)
        return l
    end)
end

local function DrawWalls()
    for _, l in ipairs(wallLines) do l:Hide() end
    if not (hasLines and view.kind == "zone") then return end
    -- shown with the editing tools (Edit walls and roads), and while drawing
    if not (ns.Editing() or wallMode) then return end
    local n = 0
    local function Draw(pts, r, g, b, a)
        for k = 1, #pts - 3, 2 do
            n = n + 1
            local l = WallLine(n)
            l:SetStartPoint("TOPLEFT", canvas, pts[k] * CW(), -pts[k + 1] * CH())
            l:SetEndPoint("TOPLEFT", canvas, pts[k + 2] * CW(), -pts[k + 3] * CH())
            l:SetColorTexture(r, g, b, a)
        end
    end
    local zone = view.zone
    local function Ring(x, y, yards, r, g, b, a)
        local pts = {}
        for k = 0, 36 do
            local t = k / 36 * 2 * math.pi
            pts[#pts + 1] = x + math.cos(t) * yards / zone.w
            pts[#pts + 1] = y + math.sin(t) * yards / zone.h
        end
        Draw(pts, r, g, b, a)
    end
    -- the kind being edited in full, the rest faintly, so they can be seen
    for _, kind in ipairs({ "roads", "walls", "zonelines" }) do
        local c = kind == "roads" and ROAD_COLOR or kind == "zonelines" and ZONE_LINE_COLOR or WALL_COLOR
        local alpha = (wallMode and editKind == kind) and c[4] or 0.45
        for _, wall in ipairs(Lines(zone, kind)) do
            if wall.circle then
                Ring(wall.circle[1], wall.circle[2], wall.circle[3], c[1], c[2], c[3], alpha)
            else
                Draw(wall, c[1], c[2], c[3], alpha)
            end
        end
    end
    if wallMode and drawing then Draw(drawing, 1, 0.85, 0.2, 1) end
    if wallMode and circleCenter then
        local x, y = CursorOnMap()
        if x then
            local yards = math.sqrt(((x - circleCenter[1]) * zone.w) ^ 2 + ((y - circleCenter[2]) * zone.h) ^ 2)
            Ring(circleCenter[1], circleCenter[2], math.max(1, yards), 1, 0.85, 0.2, 1)
        end
    end
end

-- The zone's own walls or roads (the player's; shipped ones aren't edited).
local function OwnWalls(zone, kind)
    kind = kind or editKind
    ns.db[kind] = ns.db[kind] or {}
    local mine = ns.db[kind][zone.ach]
    if not mine then
        mine = {}
        ns.db[kind][zone.ach] = mine
    end
    return mine
end

local function Round(v) return math.floor(v * 10000 + 0.5) / 10000 end

-- The wall (or road) nearest the cursor, within a few pixels: its index.
local function WallAt(zone, x, y)
    local best, bestD = nil, 10
    for w, wall in ipairs(Lines(zone, editKind)) do
        local c = wall.circle
        if c then
            -- inside it, or near its edge
            local yards = math.sqrt(((x - c[1]) * zone.w) ^ 2 + ((y - c[2]) * zone.h) ^ 2)
            if yards <= c[3] then
                best, bestD = w, 0
            end
        end
        for k = 1, #wall - 3, 2 do
            local ax, ay = wall[k] * CW(), wall[k + 1] * CH()
            local bx, by = wall[k + 2] * CW(), wall[k + 3] * CH()
            local px, py = x * CW(), y * CH()
            local dx, dy = bx - ax, by - ay
            local len2 = dx * dx + dy * dy
            local t = len2 > 0 and math.max(0, math.min(1, ((px - ax) * dx + (py - ay) * dy) / len2)) or 0
            local d = math.sqrt((px - ax - t * dx) ^ 2 + (py - ay - t * dy) ^ 2)
            if d < bestD then best, bestD = w, d end
        end
    end
    return best
end

-- The segment of a line nearest (x, y), within a few pixels, among the
-- player's own lines of `kinds`: kind, the line's index, and k, where the
-- segment starts in the line's flat list. nil when none is that close.
local function SegmentAt(zone, kinds, x, y)
    local bestKind, bestLine, bestK, bestD
    for _, kind in ipairs(kinds) do
        for w, line in ipairs(Lines(zone, kind)) do
            if not line.circle then
                for k = 1, #line - 3, 2 do
                    local ax, ay = line[k] * CW(), line[k + 1] * CH()
                    local bx, by = line[k + 2] * CW(), line[k + 3] * CH()
                    local px, py = x * CW(), y * CH()
                    local dx, dy = bx - ax, by - ay
                    local len2 = dx * dx + dy * dy
                    local t = len2 > 0 and math.max(0, math.min(1, ((px - ax) * dx + (py - ay) * dy) / len2)) or 0
                    local d = math.sqrt((px - ax - t * dx) ^ 2 + (py - ay - t * dy) ^ 2)
                    if d < 10 and (not bestD or d < bestD) then
                        bestKind, bestLine, bestK, bestD = kind, w, k, d
                    end
                end
            end
        end
    end
    return bestKind, bestLine, bestK
end

-- Take segment k out of line w of `kind`: the line is split round it (the
-- pieces left keep their exact corners; one of a single point is dropped).
-- Returns the segment's ends, x1, y1, x2, y2.
local function CutSegment(zone, kind, w, k)
    local from = OwnWalls(zone, kind)
    local line = from[w]
    local before, after = {}, {}
    for i = 1, k + 1 do before[#before + 1] = line[i] end
    for i = k + 2, #line do after[#after + 1] = line[i] end
    table.remove(from, w)
    if #after >= 4 then table.insert(from, w, after) end
    if #before >= 4 then table.insert(from, w, before) end
    if #from == 0 then ns.db[kind][zone.ach] = nil end
    return line[k], line[k + 1], line[k + 2], line[k + 3]
end

-- Ctrl-click: the one segment of a wall nearest the cursor becomes a zone
-- line (or a zone line's, a wall), meeting what's left of its line end to end.
local function SwapSegment(zone, x, y)
    local kind, w, k = SegmentAt(zone, { "walls", "zonelines" }, x, y)
    if not kind then return false end
    local toKind = kind == "walls" and "zonelines" or "walls"
    table.insert(OwnWalls(zone, toKind), { CutSegment(zone, kind, w, k) })
    ns.WallsChanged()
    ns.Print(toKind == "zonelines" and "That wall segment is a zone line now."
        or "That zone line segment is a wall now.")
    return true
end
ns.SwapSegment = SwapSegment

-- (x, y: where, for the tests; else under the cursor)
WallClick = function(button, x, y)
    local zone = view.zone
    if not x then x, y = CursorOnMap() end
    if not x then return end
    if button == "LeftButton" and IsControlKeyDown() and editKind ~= "roads" and not drawing and not circleCenter then
        SwapSegment(zone, x, y)
    elseif button == "LeftButton" and IsShiftKeyDown() and editKind == "walls" then
        if not circleCenter then
            circleCenter = { Round(x), Round(y) }
        else
            local yards = math.sqrt(((x - circleCenter[1]) * zone.w) ^ 2 + ((y - circleCenter[2]) * zone.h) ^ 2)
            if yards >= 5 then
                table.insert(OwnWalls(zone), { circle = { circleCenter[1], circleCenter[2], math.floor(yards + 0.5) } })
                ns.WallsChanged()
            end
            circleCenter = nil
        end
    elseif button == "LeftButton" then
        drawing = drawing or {}
        drawing[#drawing + 1], drawing[#drawing + 2] = Round(x), Round(y)
    elseif circleCenter then
        circleCenter = nil
    elseif drawing then
        -- right-click ends this wall; the next left-click starts another
        if #drawing >= 4 then
            local walls = OwnWalls(zone)
            table.insert(walls, drawing)
            ns.WallsChanged()
            ns.Print(string.format("%s added (%d in %s). Left-click to start the next one.",
                editKind == "roads" and "Road" or editKind == "zonelines" and "Zone line" or "Wall", #walls, zone.name))
        end
        drawing = nil
    else
        -- right-click: the one segment under the cursor (a circle: all of
        -- it); Shift-right-click: the whole line
        local kind, w, k = SegmentAt(zone, { editKind }, x, y)
        if kind and not IsShiftKeyDown() then
            CutSegment(zone, kind, w, k)
            ns.WallsChanged()
        else
            w = WallAt(zone, x, y)
            if w then
                table.remove(OwnWalls(zone), w)
                if #OwnWalls(zone) == 0 then ns.db[editKind][zone.ach] = nil end
                ns.WallsChanged()
            end
        end
    end
    DrawWalls()
end

-- The Clear button: every wall, zone line or road of the kind being drawn
-- in the shown zone (the player's own), gone at once. The first click only
-- asks; a second within a few seconds clears.
local CLEAR_NAMES = { walls = "walls", roads = "roads", zonelines = "zone lines" }
local clearAsked
local function ClearLabel()
    local b = frame and frame.clearButton
    if not b then return end
    local name = CLEAR_NAMES[editKind] or "walls"
    b:SetText(clearAsked and "|cffff5544Sure? Click|r" or "Clear " .. name)
end

local function ClearLines(kind, now)
    local zone = view.zone
    if not (zone and CLEAR_NAMES[kind]) then return end
    local okT, t = pcall(GetTime)
    t = okT and t or 0
    if not now and not (clearAsked and t - clearAsked < 4) then
        clearAsked = t
        ClearLabel()
        C_Timer.After(4, function()
            if clearAsked == t then
                clearAsked = nil
                ClearLabel()
            end
        end)
        return
    end
    clearAsked = nil
    ClearLabel()
    local mine = ns.db[kind] and ns.db[kind][zone.ach]
    local n = mine and #mine or 0
    if ns.db[kind] then ns.db[kind][zone.ach] = nil end
    drawing, circleCenter = nil, nil
    if n > 0 then ns.WallsChanged() end
    ns.Print(string.format("Cleared %d %s in %s.", n, CLEAR_NAMES[kind], zone.name))
    DrawWalls()
end
ns.ClearLines = ClearLines

-- Wall mode on or off; `kind` picks walls or roads (walls by default).
local function SetWallMode(on, kind)
    wallMode = on and true or false
    editKind = kind or "walls"
    drawing, circleCenter = nil, nil
    clearAsked = nil
    if frame and frame.clearButton then
        frame.clearButton:SetShown(wallMode)
        ClearLabel()
    end
    if wallButton then
        local walling = wallMode and (editKind == "walls" or editKind == "zonelines")
        wallButton:SetText(walling and "|cffff5544Walls|r" or "Walls")
        frame.zoneLineCheck:SetShown(walling and true or false)
        frame.zoneLineCheck:SetChecked(editKind == "zonelines")
    end
    if frame and frame.roadButton then
        frame.roadButton:SetText((wallMode and editKind == "roads") and "|cff99ff0dRoads|r" or "Roads")
    end
    DrawMap()
end
ns.WindowWallMode = SetWallMode

-- The editing tools shown or hidden (Options, Route editing).
function ns.SetEditing(on)
    ns.db.editing = on and true or false
    if not on and wallMode then SetWallMode(false) end
    ns.Fire("settings")
end

-- The route's lines on whatever map is shown: the walking path to the next
-- stop, any flight, and the legs between stops, carried across zone lines
-- (RouteDraw.lua). Redrawn every tick, as the player moves.
local function DrawRouteLines()
    for _, l in ipairs(lines) do l:Hide() end
    if not hasLines then return end
    ns.DrawRouteOn(canvas, view.map, CW(), CH(), Line, 2.5)
end

-- The player on the shown map, and the route's lines from them.
local following                -- busy moving to the next map
local function DrawPlayer()
    local px, py = ns.PlayerOn(view.map)
    local inside = px and px >= 0 and px <= 1 and py >= 0 and py <= 1
    if follow and not following then
        -- crossed onto another map: open it and carry on following
        local here = ns.PlayerMap()
        if here and here ~= view.map then
            following = true
            CenterOnMe()
            following = nil
            return
        end
    end
    if follow and inside then
        offX, offY = px * CW() - MAP_W / 2, py * CH() - MAP_H / 2
        PlaceCanvas()
    end
    playerDot:SetShown(inside and true or false)
    if inside then
        playerDot:ClearAllPoints()
        playerDot:SetPoint("CENTER", canvas, "TOPLEFT", px * CW(), -py * CH())
        local ok, facing = pcall(GetPlayerFacing)
        if ok and ns.Num(facing) and playerDot.SetRotation then pcall(playerDot.SetRotation, playerDot, facing) end
    end
    DrawRouteLines()
    if wallMode and circleCenter then DrawWalls() end
end

-- One pin: an area of the shown zone, or a stop of a route elsewhere.
local function SetPin(p, zone, node, x, y, done, order)
    p.zone, p.node, p.done, p.order = zone, node, done, order
    local size = done and 10 or (order == 1 and 22 or 16)
    p:SetSize(size, size)
    p:ClearAllPoints()
    p:SetPoint("CENTER", canvas, "TOPLEFT", x * CW(), -y * CH())
    if done then
        p.dot:SetVertexColor(0.3, 1, 0.3, 0.55)
        p.num:SetText("")
    elseif order == 1 then
        p.dot:SetVertexColor(0.3, 1, 0.35, 1)
        p.num:SetText(GREEN .. "1|r")
    else
        p.dot:SetVertexColor(1, node.rough and 0.5 or 0.9, node.rough and 0.4 or 0.3, 1)
        p.num:SetText(order or "")
    end
end

-- The outlines of the shown zone's areas (Areas.lua): the next stop's
-- bright, the rest still covered in gold, uncovered ones faint. A route
-- heads for their edges. The areaBorders option hides them all, except
-- while drawing walls or roads.
local areaLines = {}
local AREA_COLOR = { 1, 0.82, 0.1, 0.45 }
local NEXT_AREA_COLOR = { 0.3, 1, 0.35, 0.9 }
local DONE_AREA_COLOR = { 0.85, 0.9, 1, 0.3 }
local function DrawAreas()
    for _, l in ipairs(areaLines) do l:Hide() end
    if not (hasLines and view.kind == "zone") then return end
    -- while drawing walls or roads every border shows, whatever the options
    if ns.db.areaBorders == false and not wallMode then return end
    local showDone = wallMode or ns.db.doneAreaBorders ~= false
    local zone = view.zone
    local state = ns.ZoneState(zone).state
    local stop = ns.route and ns.route.zone == zone and ns.CurrentStop()
    local n = 0
    for i, node in ipairs(zone.nodes) do
        local area = ns.AreaOf(node)
        if area and (showDone or state[i] ~= true) then
            local c = (stop and stop.node == node) and NEXT_AREA_COLOR
                or state[i] == true and DONE_AREA_COLOR or AREA_COLOR
            for _, r in ipairs(area.rings) do
                local m = #r
                for k = 1, m - 1, 2 do
                    local k2 = k + 2 <= m and k + 2 or 1
                    n = n + 1
                    local l = Pool(areaLines, n, function()
                        local line = canvas:CreateLine(nil, "ARTWORK")
                        line:SetThickness(1.5)
                        return line
                    end)
                    l:SetStartPoint("TOPLEFT", canvas, r[k] * CW(), -r[k + 1] * CH())
                    l:SetEndPoint("TOPLEFT", canvas, r[k2] * CW(), -r[k2 + 1] * CH())
                    l:SetColorTexture(c[1], c[2], c[3], c[4])
                end
            end
        end
    end
end

-- The shown zone's areas. Returns how many pins it used.
local function DrawZone(zone)
    local state = ns.ZoneState(zone).state
    local order = {}
    if ns.route and ns.route.zone == zone then
        for i, stop in ipairs(ns.route.stops) do order[stop.node] = { i = i, x = stop.x, y = stop.y } end
    end
    -- an area with an outline has no marker: the outline is drawn instead,
    -- and says its name under the cursor
    local used = 0
    for i, node in ipairs(zone.nodes) do
        if not ns.AreaOf(node) then
            local o = order[node]
            local pt = ns.NodeMarker(node)
            used = used + 1
            SetPin(Pin(used), zone, node, o and o.x or pt[1], o and o.y or pt[2], state[i] == true, o and o.i)
        end
    end
    if ns.route and ns.route.zone == zone then
        for i, stop in ipairs(ns.route.stops) do
            if stop.node.fp then
                used = used + 1
                local p = Pin(used)
                SetPin(p, zone, stop.node, stop.x, stop.y, false, i)
                if i ~= 1 then p.dot:SetVertexColor(0.4, 0.75, 1, 1) end
            end
        end
    end
    return used
end

-- On any other map, the route's stops, numbered, wherever they fall on it.
local function DrawRouteStops(used)
    if not ns.route or (view.kind == "zone" and view.zone == ns.route.zone) then return end
    for _, s in ipairs(ns.RouteStopsOn(view.map)) do
        used = used + 1
        SetPin(Pin(used), ns.route.zone, s.node, s.x, s.y, false, s.i)
    end
end

-- Continents and Azeroth carry no labels but one: "I'm here!" on the zone
-- you're in, when it's on the shown map.
local function DrawHere()
    local zone = ns.CurrentZone()
    if not zone then return end
    local x, y = MiddleOn(zone.map)
    if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
        PlaceBadge(Badge(1), GOLD .. "I'm here!|r", x, y)
    end
end

DrawMap = function()
    PlaceCanvas()
    for _, p in ipairs(pins) do p:Hide() end
    for _, b in ipairs(badges) do b:Hide() end
    for _, l in ipairs(lines) do l:Hide() end
    highlight:Hide()
    hovered = nil
    pcall(DrawArt, view.map, view.zone)
    local used = 0
    if view.kind == "zone" then used = DrawZone(view.zone)
    elseif view.kind == "continent" or view.kind == "world" then DrawHere() end
    DrawRouteStops(used)
    DrawAreas()
    DrawPlayer()
    -- in wall mode the markers stay in sight but let clicks through to the
    -- map, where they draw walls
    for _, p in ipairs(pins) do p:EnableMouse(not wallMode) end
    DrawWalls()
    zoomIn:SetEnabled(zoom < ZOOM_MAX)
    zoomOut:SetEnabled(zoom > 1.001 or view.kind ~= "world")
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
    if view.kind == "map" then parts[3] = { view.name } end
    -- The strip has room for the Me and zoom buttons at its right, and while
    -- editing the Roads and Walls ones; the trail gets the rest, and only the
    -- last part (the shown map) is ever cut short.
    local editing = ns.Editing()
    for _, b in ipairs({ wallButton, frame.roadButton }) do
        b:SetShown(editing)
    end
    local x, room = 0, editing and MAP_W - 206 or MAP_W - 98
    for i, b in ipairs(trail) do
        local part = parts[i]
        if part then
            local last = i == #parts
            b.text:SetWidth(0)
            b.text:SetText((last and "|cffffffff" or GOLD) .. part[1] .. "|r")
            local w = (ns.Num(b.text:GetStringWidth()) or 60) + 6
            if last then w = math.min(w, math.max(40, room - x)) end
            b.text:SetWidth(w - 6)
            b:SetWidth(w)
            b:ClearAllPoints()
            b:SetPoint("LEFT", strip, "LEFT", x, 0)
            b.sep:SetShown(not last)
            x = x + w + (last and 0 or 16)
            b.go = not last and part[2] or nil
            b:EnableMouse(b.go and true or false)
            b:Show()
        else
            b:Hide()
        end
    end
end

-- The gray line at the bottom: how to work the map that is shown.
local HINTS = {
    world = "Click a continent to open it. Scroll or use + and - to zoom.",
    continent = "Click a zone to open it. Scroll to zoom, drag to pan. Right-click: Azeroth.",
    zone = "Click an area to head there next. Scroll to zoom, drag to pan. Right-click: back.",
    map = "Scroll to zoom, drag to pan. Right-click: back.",
}

local function RefreshInfo()
    routeButton:Hide()
    skipButton:Hide()
    local done = frame.doneCheck
    done:SetShown(view.kind == "zone" and ns.Editing())
    if view.kind == "zone" then done:SetChecked(ns.ZoneMarkedDone(view.zone)) end
    nextInfo:SetText("")
    hint:SetText(HINTS[view.kind] or "")
    if view.kind == "world" then
        local ad, at, zd, zt = ns.Totals()
        zoneTitle:SetText("Azeroth")
        zoneInfo:SetText(string.format("%d of %d areas, %d of %d zones explored.", ad, at, zd, zt))
        return
    end
    if view.kind == "continent" then
        local ad, at, zd, zt = ns.Totals(continent)
        zoneTitle:SetText(CONTINENT_NAME[continent])
        zoneInfo:SetText(string.format("%d of %d areas, %d of %d zones explored.", ad, at, zd, zt))
        nextInfo:SetText(GRAY .. "Pick a zone on the map or in the list to see its areas and route.|r")
        return
    end
    if view.kind == "map" then
        zoneTitle:SetText(view.name)
        zoneInfo:SetText(GRAY .. "No areas to explore on this map.|r")
        return
    end
    local zone = view.zone
    local d, t = ns.ZoneCounts(zone)
    zoneTitle:SetText(ZoneName(zone))
    local routed = ns.ZoneRouted(zone)
    if d == t then
        zoneInfo:SetText(GREEN .. "Fully explored. All " .. t .. " areas uncovered.|r")
    elseif routed then
        zoneInfo:SetText(string.format("%d of %d areas uncovered. Route: %d stop%s, about %s.", d, t,
            #ns.route.stops, #ns.route.stops == 1 and "" or "s", ns.Yards(ns.route.yards)))
    else
        zoneInfo:SetText(string.format("%d of %d areas uncovered. %s%d to find.|r", d, t, GOLD, t - d))
    end
    if routed then
        nextInfo:SetText(ns.NextStopText() or "")
    elseif d < t then
        nextInfo:SetText(GRAY .. "Start the route for the shortest way through the areas left.|r")
    end
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
    -- shorter in Map only, where the header is narrow
    local fmt = ns.db.mapOnly and "%d / %d areas, %d / %d zones" or "Explorer: %d / %d areas, %d / %d zones"
    overallBar.text:SetText(string.format(fmt, ad, at, zd, zt))
    for _, box in ipairs(optionBoxes) do box:SetChecked(box.get()) end
    RefreshList()
    DrawMap()
    RefreshTrail()
    RefreshInfo()
end
ns.RefreshWindow = Refresh

-- The settings, in a panel that drops down from the Options button.
local OPTIONS = {
    { section = "Routes" },
    { label = "Route me automatically", desc = "Start a zone's route as you enter it.",
      tip = "Entering a zone with areas still to uncover starts its route and tells you where to run. "
          .. "Leaving the zone ends that route.",
      get = function() return ns.db.autoRoute end,
      set = function(on) ns.SetAutoRoute(on) end },
    { label = "Fly automatically", desc = "Take the planned flight when the map opens.",
      tip = "When the route plans a flight, take it as soon as you open the flight master's map. "
          .. "Off, a button by the flight map takes it in one click.",
      get = function() return ns.db.autoFly end,
      set = function(on) ns.db.autoFly = on ns.Fire("settings") end },
    { section = "Route editing", mapper = true },
    { label = "Edit walls and roads", mapper = true, desc = "Make routes better.",
      tip = "Shows the Walls and Roads buttons over the map. Walls keep routes off ground "
          .. "you can't really cross, zone lines keep them inside a zone, and roads pull them onto paths.",
      get = function() return ns.db.editing end,
      set = function(on) ns.SetEditing(on) end },
    { section = "Display" },
    { label = "World map markers", desc = "The route's stops and a route bar on the world map.",
      tip = "A bar saying how many areas are left, to start the route, and the route's stops, numbered, while it runs.",
      get = function() return ns.db.mapPins end,
      set = function(on) ns.db.mapPins = on ns.Fire("settings") end },
    { label = "Covered areas on the world map", desc = "Areas still to uncover, drawn in gray.",
      tip = "The game's world map shows a zone's covered areas in gray, as this window does, "
          .. "so the whole zone shows and what's left stands out.",
      get = function() return ns.db.worldMapGray ~= false end,
      set = function(on) ns.db.worldMapGray = on ns.Fire("settings") end },
    { label = "Area borders on the map", desc = "Each area's outline, from the terrain.",
      tip = "Areas still covered in gold, the next stop's in green, uncovered ones faintly. "
          .. "Hovering over an area shows its name either way.",
      get = function() return ns.db.areaBorders ~= false end,
      set = function(on) ns.db.areaBorders = on ns.Fire("settings") end },
    { label = "Uncovered area borders", desc = "Outlines of areas already uncovered.",
      tip = "Off, only the areas still to uncover keep their outlines.",
      get = function() return ns.db.doneAreaBorders ~= false end,
      set = function(on) ns.db.doneAreaBorders = on ns.Fire("settings") end },
    { label = "Open instead of the world map", desc = "The world map key opens this window.",
      tip = "Your world map key (M unless you changed it) opens Compass Forever instead. "
          .. "The world map still opens from the minimap, the quest log and its other buttons.",
      get = function() return ns.db.replaceWorldMap end,
      set = function(on) ns.db.replaceWorldMap = on ns.ApplyMapKey() end },
    { label = "Route on the minimap", desc = "The route's lines and stops around you.",
      tip = "The same lines as the world map, drawn on the minimap at its zoom, with a dot on each stop in reach.",
      get = function() return ns.db.minimapRoute ~= false end,
      set = function(on) ns.db.minimapRoute = on ns.Fire("settings") end },
    { label = "Fanfare", desc = "Music when a zone is fully explored.",
      tip = "While it plays, a Stop music button stops it.",
      get = function() return ns.db.fanfare ~= false end,
      set = function(on) ns.db.fanfare = on end },
    { label = "On-screen messages", desc = "Big text for new routes and uncovered areas.",
      get = function() return ns.db.banner end,
      set = function(on) ns.db.banner = on end },
    { label = "Minimap button", desc = "Click it to open this window.",
      tip = "Right-click it to start or stop the route through the zone you're in.",
      get = function() return not ns.db.minimap.hide end,
      set = function(on) ns.SetMinimapShown(on) end },
}

local function BuildOptions()
    options = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    options:SetFrameLevel(frame:GetFrameLevel() + 30)
    options:EnableMouse(true)
    if options.SetBackdrop then
        options:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 14,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        options:SetBackdropColor(0.06, 0.05, 0.04, 0.97)
        options:SetBackdropBorderColor(0.8, 0.65, 0.3)
    end
    options:SetPoint("TOPRIGHT", optionsButton, "BOTTOMRIGHT", 0, -4)
    optionBoxes = {}
    local y = -12
    local mapper = ns.CanEdit()
    for _, opt in ipairs(OPTIONS) do
        if opt.mapper and not mapper then
            -- route editing: the author's characters only (Core.lua)
        elseif opt.section then
            local head = Label(options, "GameFontNormal", 250)
            head:SetPoint("TOPLEFT", 14, y - (y == -12 and 0 or 6))
            head:SetText(opt.section)
            y = y - (y == -12 and 20 or 26)
        else
            local box = Check(options, opt.label, opt.desc, opt.tip or opt.desc, opt.set)
            box:SetPoint("TOPLEFT", 12, y)
            box.get = opt.get
            optionBoxes[#optionBoxes + 1] = box
            y = y - 38
        end
    end
    options:SetSize(290, -y + 6)
    options:Hide()
    options:SetScript("OnShow", function() optionsButton:LockHighlight() end)
    options:SetScript("OnHide", function() optionsButton:UnlockHighlight() end)
end

local function Build()
    if frame then return end
    frame = CreateFrame("Frame", "CompassForeverFrame", UIParent, "BackdropTemplate")
    frame:SetSize(W, H)
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
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

    -- The header: name, the Explorer bar, Options and close; a rule under it.
    local title = Label(frame, "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", PAD + 4, -20)
    title:SetText(ns.title)
    frame.headerTitle = title
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
    optionsButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    optionsButton:SetSize(96, 22)
    optionsButton:SetPoint("TOPRIGHT", -40, -16)
    optionsButton:SetText("Options")
    optionsButton:SetScript("OnClick", function() options:SetShown(not options:IsShown()) end)
    frame.mapOnlyButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.mapOnlyButton:SetSize(84, 22)
    frame.mapOnlyButton:SetPoint("RIGHT", optionsButton, "LEFT", -6, 0)
    frame.mapOnlyButton:SetScript("OnClick", function() ns.SetMapOnly(not ns.db.mapOnly) end)
    Tip(frame.mapOnlyButton, "Map only", "Hide the zone list and everything under the map, or bring them back.")
    overallBar = Bar(frame, 300, 16)
    overallBar:SetPoint("RIGHT", frame.mapOnlyButton, "LEFT", -16, 0)
    local rule = frame:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(0.8, 0.65, 0.3, 0.35)
    rule:SetPoint("TOPLEFT", PAD, -46)
    rule:SetPoint("TOPRIGHT", -PAD, -46)
    rule:SetHeight(1)

    -- The left side: a tab for each continent over its zones.
    frame.leftSide = CreateFrame("Frame", nil, frame)
    frame.leftSide:SetAllPoints()
    contButtons = {}
    for i, c in ipairs({ 0, 1 }) do
        local b = CreateFrame("Button", nil, frame.leftSide, "UIPanelButtonTemplate")
        b:SetSize(LIST_W / 2 - 2, 22)
        b:SetPoint("TOPLEFT", PAD + (i - 1) * (LIST_W / 2 + 2), -54)
        b:SetText(CONTINENT_NAME[c])
        b.continent = c
        b:SetScript("OnClick", function()
            if scroll.SetVerticalScroll then scroll:SetVerticalScroll(0) end
            ShowContinentView(c)
        end)
        contButtons[i] = b
    end
    local listInset = Inset(frame.leftSide)
    listInset:SetPoint("TOPLEFT", PAD, TOP)
    listInset:SetPoint("BOTTOMLEFT", PAD, PAD)
    listInset:SetWidth(LIST_W)
    scroll = CreateFrame("ScrollFrame", "CompassForeverZoneList", listInset, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -28, 6)
    listChild = CreateFrame("Frame", nil, scroll)
    listChild:SetSize(ROW_W, 1)
    scroll:SetScrollChild(listChild)

    -- The right side: the trail and zoom buttons, then the map.
    strip = CreateFrame("Frame", nil, frame)
    strip:SetPoint("TOPLEFT", MAP_X + 4, -54)
    strip:SetSize(MAP_W, 22)
    trail = {}
    for i = 1, 3 do
        local b = CreateFrame("Button", nil, strip)
        b:SetHeight(22)
        b.text = Label(b, "GameFontNormal")
        b.text:SetPoint("LEFT", 3, 0)
        b.sep = Label(b, "GameFontDisable")
        b.sep:SetPoint("LEFT", b, "RIGHT", 4, 0)
        b.sep:SetText(">")
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 0.82, 0, 0.15)
        b:SetScript("OnClick", function(self) if self.go then self.go() end end)
        trail[i] = b
    end
    zoomIn = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
    zoomIn:SetSize(24, 22)
    zoomIn:SetPoint("RIGHT", strip, "RIGHT", 0, 0)
    zoomIn:SetText("+")
    zoomIn:SetScript("OnClick", function() OnWheel(nil, 1) end)
    Tip(zoomIn, "Zoom in", "Or scroll up over the map.")
    zoomOut = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
    zoomOut:SetSize(24, 22)
    zoomOut:SetPoint("RIGHT", zoomIn, "LEFT", -4, 0)
    zoomOut:SetText("-")
    zoomOut:SetScript("OnClick", function() OnWheel(nil, -1) end)
    Tip(zoomOut, "Zoom out", "At full size, goes up to the continent or Azeroth. Or scroll down over the map.")
    local meButton = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
    meButton:SetSize(34, 22)
    meButton:SetPoint("RIGHT", zoomOut, "LEFT", -4, 0)
    meButton:SetText("Me")
    frame.meButton = meButton
    meButton:SetScript("OnClick", function()
        if follow then SetFollow(false) else CenterOnMe() end
    end)
    Tip(meButton, "Center on me", "Opens the map you're on, zoomed in, and keeps you in the middle as you move "
        .. "(onto the next map too). Click again, drag the map or open another to stop.")
    wallButton = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
    wallButton:SetSize(48, 22)
    wallButton:SetPoint("RIGHT", meButton, "LEFT", -4, 0)
    wallButton:SetText("Walls")
    wallButton:SetScript("OnClick", function()
        SetWallMode(not (wallMode and (editKind == "walls" or editKind == "zonelines")), "walls")
    end)
    Tip(wallButton, "Draw walls",
        "On a zone's map: left-click to add corners of a wall, right-click to finish it. "
        .. "Shift-click a circle's middle, then Shift-click its edge. "
        .. "Right-click a wall's segment to remove just that segment, Shift-right-click to remove "
        .. "the whole wall; right-click a circle to remove it. Routes never cross a wall or enter a circle. "
        .. "Tick Zone line (on the map) to draw zone lines instead. "
        .. "Ctrl-click one segment of a wall to make just that segment a zone line (or back). "
        .. "Click Walls again when done.")
    frame.roadButton = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
    frame.roadButton:SetSize(48, 22)
    frame.roadButton:SetPoint("RIGHT", wallButton, "LEFT", -4, 0)
    frame.roadButton:SetText("Roads")
    frame.roadButton:SetScript("OnClick", function() SetWallMode(not (wallMode and editKind == "roads"), "roads") end)
    Tip(frame.roadButton, "Draw roads",
        "On a zone's map: left-click to add corners of a road, right-click to finish it. "
        .. "Right-click a road's segment to remove just that segment, Shift-right-click to remove "
        .. "the whole road. Paths keep to roads until they have to leave them. "
        .. "Click Roads again when done.")

    local border = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    frame.mapBorder = border
    border:SetPoint("TOPLEFT", MAP_X, TOP)
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
    mapBox:SetScript("OnMouseDown", OnMapDown)
    mapBox:SetScript("OnMouseUp", OnMapClick)
    mapBox:EnableMouseWheel(true)
    mapBox:SetScript("OnMouseWheel", OnWheel)
    canvas = CreateFrame("Frame", nil, mapBox)
    canvas:SetPoint("TOPLEFT")
    canvas:SetSize(MAP_W, MAP_H)
    local paper = mapBox:CreateTexture(nil, "BACKGROUND", nil, -8)
    paper:SetAllPoints()
    paper:SetColorTexture(0.12, 0.1, 0.07, 1)
    baseTiles = ns.TexturePool(canvas, "BACKGROUND", 0)
    grayArt = ns.TexturePool(canvas, "BORDER", 0)
    colorArt = ns.TexturePool(canvas, "BORDER", 1)
    highlight = canvas:CreateTexture(nil, "ARTWORK", nil, 1)
    highlight:SetBlendMode("ADD")
    highlight:SetAlpha(0.6)
    highlight:Hide()
    hasLines = type(canvas.CreateLine) == "function"
    playerDot = canvas:CreateTexture(nil, "OVERLAY")
    playerDot:SetTexture("Interface\\Minimap\\MinimapArrow")
    playerDot:SetSize(24, 24)
    playerDot:Hide()

    -- On the map's corner, for a zone: tick when its walls, roads and zone
    -- lines are all laid out, ready to be built into the addon.
    local done = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    frame.doneCheck = done
    done:SetSize(24, 24)
    done:SetPoint("TOPLEFT", border, "TOPLEFT", 6, -6)
    done:SetFrameLevel(mapBox:GetFrameLevel() + 20)
    local doneBg = done:CreateTexture(nil, "BACKGROUND")
    doneBg:SetPoint("TOPLEFT", -2, 2)
    doneBg:SetSize(176, 28)
    doneBg:SetColorTexture(0, 0, 0, 0.55)
    local doneText = done:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    doneText:SetPoint("LEFT", done, "RIGHT", 2, 0)
    doneText:SetText("Done mapping this zone")
    done:SetScript("OnClick", function(self)
        if view.zone then ns.SetZoneMarkedDone(view.zone, self:GetChecked()) end
        Refresh()
    end)
    Tip(done, "Done mapping",
        "Tick when this zone's walls, roads and zone lines are all laid out: it gets a * in the list, "
        .. "ready to be built into the addon. Zones already built in show in purple.")

    -- On the map's other corner, in Walls mode: draw zone lines instead,
    -- walls only for paths that stay in the zone.
    frame.zoneLineCheck = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    frame.zoneLineCheck:SetSize(24, 24)
    frame.zoneLineCheck:SetPoint("TOPRIGHT", border, "TOPRIGHT", -84, -6)
    frame.zoneLineCheck:SetFrameLevel(mapBox:GetFrameLevel() + 20)
    local zlBg = frame.zoneLineCheck:CreateTexture(nil, "BACKGROUND")
    zlBg:SetPoint("TOPLEFT", -2, 2)
    zlBg:SetSize(104, 28)
    zlBg:SetColorTexture(0, 0, 0, 0.55)
    local zlText = frame.zoneLineCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    zlText:SetPoint("LEFT", frame.zoneLineCheck, "RIGHT", 2, 0)
    zlText:SetText("|cffcc73ffZone line|r")
    frame.zoneLineCheck:SetScript("OnClick", function(self)
        SetWallMode(true, self:GetChecked() and "zonelines" or "walls")
    end)
    frame.zoneLineCheck:Hide()
    Tip(frame.zoneLineCheck, "Zone line",
        "Draws zone lines (purple) instead of walls: the waypoints inside this zone never cross one, "
        .. "but a path coming from or going to another zone may. Use them along the zone's edge "
        .. "where the route must stay in. Ctrl-click a wall's segment to turn it into one.")

    -- Top left, right of the Done mapping box, while drawing: clear every
    -- line of the kind being drawn in this zone.
    frame.clearButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.clearButton:SetSize(110, 22)
    frame.clearButton:SetPoint("LEFT", doneBg, "RIGHT", 6, 0)
    frame.clearButton:SetFrameLevel(mapBox:GetFrameLevel() + 20)
    frame.clearButton:SetScript("OnClick", function() ClearLines(editKind) end)
    frame.clearButton:Hide()
    Tip(frame.clearButton, "Clear",
        "Removes every one of your walls (or zone lines, or roads: whichever you're drawing) in this zone. "
        .. "Click twice to be sure. Lines built into the addon aren't yours to clear.")

    -- Under the map: what it shows on the left, the route buttons on the
    -- right, and how to work it along the bottom.
    frame.belowMap = CreateFrame("Frame", nil, frame)
    frame.belowMap:SetAllPoints()
    zoneTitle = Label(frame.belowMap, "GameFontNormalLarge", TEXT_W)
    zoneTitle:SetPoint("TOPLEFT", border, "BOTTOMLEFT", 4, -10)
    zoneInfo = Para(frame.belowMap, "GameFontHighlight", TEXT_W, 2)
    zoneInfo:SetPoint("TOPLEFT", zoneTitle, "BOTTOMLEFT", 0, -6)
    nextInfo = Para(frame.belowMap, "GameFontHighlight", TEXT_W, 2)
    nextInfo:SetPoint("TOPLEFT", zoneInfo, "BOTTOMLEFT", 0, -4)
    hint = Label(frame.belowMap, "GameFontDisableSmall", MAP_W)
    hint:SetPoint("BOTTOMLEFT", MAP_X + 4, PAD + 2)

    routeButton = CreateFrame("Button", nil, frame.belowMap, "UIPanelButtonTemplate")
    routeButton:SetSize(BUTTON_W, 26)
    routeButton:SetPoint("TOPRIGHT", border, "BOTTOMRIGHT", -4, -10)
    routeButton:SetScript("OnClick", function()
        if ns.ZoneRouted(view.zone) then ns.StopRoute() else ns.StartRoute(view.zone) end
    end)
    skipButton = CreateFrame("Button", nil, frame.belowMap, "UIPanelButtonTemplate")
    skipButton:SetSize(BUTTON_W, 26)
    skipButton:SetPoint("TOPRIGHT", routeButton, "BOTTOMRIGHT", 0, -6)
    skipButton:SetText("Skip this stop")
    skipButton:SetScript("OnClick", function() ns.SkipStop() end)
    Tip(skipButton, "Skip this stop", "Leaves it for the end of the route.")
    BuildOptions()
    ns.SetMapOnly(ns.db.mapOnly)

    local elapsed = 0
    frame:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + (ns.Num(dt) or 0)
        if elapsed < 0.1 then return end
        elapsed = 0
        pcall(DrawPlayer)
        pcall(Hover)
    end)
    ns.TimeUpdates(frame, "window")
    frame:SetScript("OnShow", function()
        ns.InvalidateProgress()
        Refresh()
    end)
    frame:SetScript("OnHide", function() options:Hide() end)
    -- The corner grip: pulling it scales the whole window, so it keeps its
    -- shape; its top left stays where it is.
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -6, 6)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function(self)
        local cx = GetCursorPosition()
        local eff = frame:GetEffectiveScale()
        self.start = { cx = cx, scale = frame:GetScale(), width = frame:GetWidth() * eff,
                       left = frame:GetLeft() * eff, top = frame:GetTop() * eff }
        self:SetScript("OnUpdate", function()
            local st = self.start
            local x = GetCursorPosition()
            local scale = st.scale * math.max(0.3, (st.width + x - st.cx) / st.width)
            scale = math.max(0.6, math.min(2, scale))
            frame:SetScale(scale)
            local newEff = frame:GetEffectiveScale()
            frame:ClearAllPoints()
            frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", st.left / newEff, st.top / newEff)
        end)
    end)
    grip:SetScript("OnMouseUp", function(self)
        self:SetScript("OnUpdate", nil)
        ns.db.windowScale = frame:GetScale()
        ns.SavePoint(frame, ns.db.window)
    end)
    Tip(grip, "Resize", "Drag to make the window bigger or smaller.")

    frame:SetScale(ns.db.windowScale or 1)
    ns.RestorePoint(frame, ns.db.window, "CENTER", "CENTER", 0, 0)
end

-- Map only: the window shrinks to its header and map; the zone list and
-- everything under the map are hidden and the map moves left.
function ns.SetMapOnly(on)
    ns.db.mapOnly = on and true or false
    if not frame then return end
    local only = ns.db.mapOnly
    frame.leftSide:SetShown(not only)
    frame.belowMap:SetShown(not only)
    local x = only and PAD or MAP_X
    frame.mapBorder:ClearAllPoints()
    frame.mapBorder:SetPoint("TOPLEFT", x, TOP)
    strip:ClearAllPoints()
    strip:SetPoint("TOPLEFT", x + 4, -54)
    if only then
        frame:SetSize(MAP_W + 8 + 2 * PAD, -TOP + MAP_H + 8 + PAD)
    else
        frame:SetSize(W, H)
    end
    -- the bar fills what the header has left between the title and the
    -- buttons, so its text never runs into them
    overallBar:ClearAllPoints()
    if only then
        overallBar:SetPoint("LEFT", frame.headerTitle, "RIGHT", 12, 0)
        overallBar:SetPoint("RIGHT", frame.mapOnlyButton, "LEFT", -12, 0)
    else
        overallBar:SetPoint("RIGHT", frame.mapOnlyButton, "LEFT", -16, 0)
        overallBar:SetWidth(300)
    end
    frame.mapOnlyButton:SetText(only and "Full view" or "Map only")
    if frame:IsShown() and Refresh then Refresh() end
end

-- The world map key (M unless rebound) opens this window instead, when
-- set: an override binding on each key bound to the world map, out of
-- combat only (bindings can't change in combat).
local mapKey = CreateFrame("Button", "CompassForeverMapKey", UIParent)
mapKey:SetScript("OnClick", function() ns.ToggleWindow() end)
local keyPending
function ns.ApplyMapKey()
    if InCombatLockdown() then
        keyPending = true
        return
    end
    keyPending = nil
    ClearOverrideBindings(mapKey)
    if ns.db and ns.db.replaceWorldMap then
        for _, key in ipairs({ GetBindingKey("TOGGLEWORLDMAP") }) do
            SetOverrideBindingClick(mapKey, true, key, "CompassForeverMapKey")
        end
    end
end
mapKey:RegisterEvent("UPDATE_BINDINGS")
mapKey:RegisterEvent("PLAYER_REGEN_ENABLED")
mapKey:SetScript("OnEvent", function(_, event)
    if event == "UPDATE_BINDINGS" or keyPending then ns.ApplyMapKey() end
end)
ns.On("login", function() ns.ApplyMapKey() end)

-- Open on `zone`, or on the route's zone, the zone you are in, or your
-- continent's map.
function ns.ShowZone(zone)
    Build()
    frame:Show()
    if not zone and not ns.route then
        -- a city or any other map you're on opens as it is
        local here = ns.PlayerMap()
        if here and not ns.ZoneByMap(here) and not ContinentOfMap(here) and here ~= WORLD then
            ShowMapView(here)
            return
        end
    end
    zone = zone or (ns.route and ns.route.zone) or ns.CurrentZone()
    if zone then ShowZoneView(zone) else ShowContinentView(continent) end
end

function ns.ToggleWindow()
    if frame and frame:IsShown() then frame:Hide() else ns.ShowZone() end
end

-- For the tests: what the map shows, and a click on it.
function ns.WindowView() return view end
function ns.WindowZoom() return zoom, offX, offY end
function ns.WindowFrame() return frame end
ns.WindowWheel = OnWheel
ns.WindowZoomOut = ZoomOut
ns.WindowOpen = function(target)
    if target.zone then ShowZoneView(target.zone) else ShowContinentView(target.continent) end
end
ns.WindowTarget = Target
ns.WindowAreaAt = AreaAt
ns.WindowWallClick = function(button, x, y) WallClick(button, x, y) end
ns.WindowCenterOnMe = function() CenterOnMe() end

-- Through ns.Fire, which reports an error instead of hiding it.
ns.On("progress", function() Refresh() end)
ns.On("route", function() Refresh() end)
ns.On("settings", function() Refresh() end)
ns.On("path", function() if frame and frame:IsShown() then pcall(DrawPlayer) end end)
ns.On("travel", function() Refresh() end)
