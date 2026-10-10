-- Chair Legacy: Arrow.lua
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

local function Yards(yards)
    if yards >= 1000 then return string.format("%.1fk yd", yards / 1000) end
    return string.format("%d yd", math.floor(yards + 0.5))
end

-- Bearing (radians counter-clockwise from north, as GetPlayerFacing) and
-- distance in yards from the player to a stop. nil, "elsewhere" when the
-- player is on another continent.
function ns.StopVector(zone, stop)
    local px, py = ns.PlayerOn(zone.map)
    if not px then
        local here = ns.PlayerMap()
        if here then
            local _, why = ns.Translate(here, 0.5, 0.5, zone.map)
            return nil, why
        end
        return nil
    end
    local east = (stop.x - px) * zone.w
    local north = -(stop.y - py) * zone.h
    return math.atan2(-east, north), math.sqrt(east * east + north * north)
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

local function Update()
    local stop, index = ns.CurrentStop()
    if not stop then
        frame:Hide()
        return
    end
    local r = ns.route
    local zone = r.zone
    nameText:SetText(stop.node.name)
    stepText:SetText(string.format("%s: stop %d of %d", zone.name, index, #r.stops))

    local bearing, yards = ns.StopVector(zone, stop)
    if not bearing then
        arrowTex:Hide()
        distText:SetText(yards == "elsewhere" and "Go to " .. zone.name or "Can't place you here")
        return
    end
    arrowTex:Show()
    if yards <= CLOSE_YARDS then
        -- The area is uncovered on entering it, usually before this; if it
        -- has not been by now, the spot needs a look (or /legacy skip).
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
    distText:SetText(Yards(yards))
end

local function Build()
    if frame then return end
    frame = CreateFrame("Frame", "ChairLegacyArrow", UIParent)
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
    if ns.CurrentStop() then
        Build()
        ns.ApplyArrowScale()
        elapsed = TICK
        frame:Show()
    elseif frame then
        frame:Hide()
    end
end)
