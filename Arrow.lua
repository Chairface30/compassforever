-- Compass Forever: Arrow.lua
-- A large arrow pointing at the next stop of the exploration route, with the
-- distance, the area's name and how many stops are left.
--
-- The art is Textures\arrow.tga, the same 64 pre-rendered turns of a bevelled
-- arrow Chaircraft's waypoint arrow uses: cell i is the arrow turned i/64 of a
-- turn counter-clockwise from straight ahead.

local _, ns = ...

local TEXTURE = "Interface\\AddOns\\" .. ns.addonName .. "\\Textures\\arrow"
local GRID, FRAMES = 8, 64
local TICK = 0.05
local TWO_PI = 2 * math.pi
local CLOSE_YARDS = 12

local frame, arrowTex, distText, nameText, stepText
local elapsed = 0

-- "northwest" for a bearing (radians counter-clockwise from north).
local COMPASS = { "north", "northwest", "west", "southwest", "south", "southeast", "east", "northeast" }
function ns.Compass(bearing)
    local i = math.floor((bearing % TWO_PI) / (math.pi / 4) + 0.5) % 8
    return COMPASS[i + 1]
end

-- Bearing (radians counter-clockwise from north, as GetPlayerFacing) from
-- one map point to another, w x h yards in size, and the distance.
local function Bearing(fx, fy, tx, ty, w, h)
    local east = (tx - fx) * w
    local north = -(ty - fy) * h
    return math.atan2(-east, north), math.sqrt(east * east + north * north)
end

-- Bearing and distance in yards from the player to a stop. Where the
-- terrain is known, both follow the walking path around cliffs and
-- mountains, from wherever the player is on the continent (the bearing aims
-- a little way along it); until the path is found they are straight. nil, "elsewhere" when the
-- player is on another continent.
function ns.StopVector(zone, stop)
    -- Along the walking path on the continent, wherever the player is on it,
    -- and straight on the continent until that path is found.
    local cont = ns.CONTINENT_YARDS and ns.CONTINENT_YARDS[zone.continent]
    if cont and ns.ZoneToContinentPoint then
        local cx, cy = ns.PlayerOn(cont.map)
        local sx, sy = ns.ZoneToContinentPoint(zone, stop.x, stop.y)
        if cx and sx then
            if ns.Steer then
                local ax, ay, left = ns.Steer(zone.continent, { x = sx, y = sy }, cx, cy)
                if ax then return Bearing(cx, cy, ax, ay, cont.w, cont.h), left end
            end
            return Bearing(cx, cy, sx, sy, cont.w, cont.h)
        end
    end
    -- No continent placement: straight on the zone's own map.
    local px, py = ns.PlayerOn(zone.map)
    if not px then
        local here = ns.PlayerMap()
        if here then
            local _, why = ns.Translate(here, 0.5, 0.5, zone.map)
            return nil, why
        end
        return nil
    end
    return Bearing(px, py, stop.x, stop.y, zone.w, zone.h)
end

-- Bearing and distance to the flight master while a flight is planned.
local function TravelVector()
    local t = ns.TravelTarget and ns.TravelTarget()
    if not t then return nil end
    local px, py = ns.PlayerOn(t.map)
    if not px then return nil end
    -- Along the walking path on the continent.
    if ns.Steer and ns.travel and ns.travel.zone then
        local ax, ay, left = ns.Steer(ns.travel.zone.continent, { x = t.x, y = t.y }, px, py)
        if ax then return Bearing(px, py, ax, ay, t.w, t.h), left end
    end
    return Bearing(px, py, t.x, t.y, t.w, t.h)
end

local function Cell(relative)
    local turn = (relative % TWO_PI) / TWO_PI
    return math.floor(turn * FRAMES + 0.5) % FRAMES
end

-- Green when roughly ahead, through yellow to red when behind.
local function Color(relative)
    local off = math.abs(((relative + math.pi) % TWO_PI) - math.pi) / math.pi
    if off <= 0.25 then return 0.2, 1, 0.25 end
    if off <= 0.6 then
        local t = (off - 0.25) / 0.35
        return 0.2 + 0.8 * t, 1, 0.25 * (1 - t)
    end
    local t = math.min(1, (off - 0.6) / 0.4)
    return 1, 1 - 0.75 * t, 0
end

local function Point(relative)
    local cell = Cell(relative)
    local col, row = cell % GRID, math.floor(cell / GRID)
    arrowTex:SetTexCoord(col / GRID, (col + 1) / GRID, row / GRID, (row + 1) / GRID)
end

-- A ghost: to the corpse first, whatever the route.
local function CorpseUpdate(corpse)
    nameText:SetText("Your corpse")
    local stop = ns.CurrentStop()
    stepText:SetText(stop and ("then " .. stop.node.name) or "")
    local bearing, yards = ns.CorpseVector(corpse)
    arrowTex:Show()
    if yards <= CLOSE_YARDS then
        Point(0)
        arrowTex:SetVertexColor(0.85, 0.9, 1, 0.45)
        distText:SetText("Here")
        return
    end
    local ok, facing = pcall(_G.GetPlayerFacing)
    facing = ok and ns.Num(facing) or 0
    local relative = bearing - facing
    Point(relative)
    arrowTex:SetVertexColor(Color(relative))
    distText:SetText(ns.Yards(yards))
end

local function Update()
    local corpse = ns.Corpse and ns.Corpse()
    if corpse then return CorpseUpdate(corpse) end
    local stop, index = ns.CurrentStop()
    if not stop then
        frame:Hide()
        return
    end
    local r = ns.route
    local zone = r.zone
    nameText:SetText(stop.node.name)
    stepText:SetText(string.format("%s: stop %d of %d", zone.name, index, #r.stops))

    -- A flight planned: the flight master first.
    local bearing, yards
    if ns.travel then
        bearing, yards = TravelVector()
        if bearing then
            local from, to = ns.travel.from.name:match("^([^,]+)"), ns.travel.to.name:match("^([^,]+)")
            nameText:SetText("Flight master: " .. (from or ""))
            stepText:SetText("then fly to " .. (to or "") .. " for " .. stop.node.name)
            if yards <= CLOSE_YARDS * 2 then
                Point(0)
                arrowTex:Show()
                arrowTex:SetVertexColor(0.3, 0.8, 1, 0.6)
                distText:SetText("Fly to " .. (to or ""))
                return
            end
        end
    end
    if not bearing then bearing, yards = ns.StopVector(zone, stop) end
    if not bearing then
        arrowTex:Hide()
        distText:SetText(yards == "elsewhere" and "Go to " .. zone.name or "Can't place you here")
        return
    end
    arrowTex:Show()
    if yards <= CLOSE_YARDS and stop.single then
        -- a one-area route: reached
        ns.SingleReached()
        return
    end
    if yards <= CLOSE_YARDS then
        -- The area is uncovered on entering it, usually before this; if it
        -- has not been by now, the spot needs a look (or /cf skip).
        Point(0)
        arrowTex:SetVertexColor(0.2, 1, 0.25, 0.45)
        distText:SetText("Here")
        return
    end
    local ok, facing = pcall(_G.GetPlayerFacing)
    facing = ok and ns.Num(facing) or 0
    local relative = bearing - facing
    Point(relative)
    arrowTex:SetVertexColor(Color(relative))
    distText:SetText(ns.Yards(yards))
end

local function Build()
    if frame then return end
    frame = CreateFrame("Frame", "CompassForeverArrow", UIParent)
    frame:SetSize(110, 150)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        ns.SavePoint(self, ns.db.arrow)
    end)
    -- Right-click: leave this stop for the end of the route.
    frame:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then ns.SkipStop() end
    end)
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Exploration route", 1, 1, 1)
        GameTooltip:AddLine("Drag to move. Right-click to skip this stop.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)

    arrowTex = frame:CreateTexture(nil, "ARTWORK")
    arrowTex:SetTexture(TEXTURE)
    arrowTex:SetSize(100, 100)
    arrowTex:SetPoint("TOP")

    distText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    distText:SetPoint("TOP", arrowTex, "BOTTOM", 0, 4)
    distText:SetTextColor(1, 1, 1)
    nameText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameText:SetPoint("TOP", distText, "BOTTOM", 0, -2)
    stepText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    stepText:SetPoint("TOP", nameText, "BOTTOM", 0, -2)

    frame:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + (ns.Num(dt) or 0)
        if elapsed < TICK then return end
        elapsed = 0
        local ok, err = pcall(Update)
        if not ok and not ns.arrowError then
            ns.arrowError = true
            ns.Print("|cffff5555arrow:|r", err)
        end
    end)
    ns.RestorePoint(frame, ns.db.arrow, "TOP", "TOP", 0, -140)
end

function ns.ApplyArrowScale()
    if frame then frame:SetScale(math.max(0.5, math.min(2, ns.db.arrowScale or 1))) end
end

ns.On("route", function()
    if ns.CurrentStop() or (ns.Corpse and ns.Corpse()) then
        Build()
        ns.ApplyArrowScale()
        elapsed = TICK
        frame:Show()
    elseif frame then
        frame:Hide()
    end
end)
