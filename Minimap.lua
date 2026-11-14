-- Compass Forever: Minimap.lua
-- The minimap button (LibDBIcon), also a launcher for any LibDataBroker bar.
-- Click opens the window; right-click starts or stops this zone's route.
--
-- Its icon is the compass arrow (Textures/arrow.tga, 64 turns, as Arrow.lua),
-- turning to point at the route's next stop, or with no route at the nearest
-- area still covered in the zone you're in; gold and upright with nothing to
-- point at. It is turned through the data object's iconCoords and colour, so
-- LibDBIcon keeps drawing it.

local _, ns = ...

local NAME = "CompassForever"
local ICON = "Interface\\AddOns\\" .. ns.addonName .. "\\Textures\\arrow"
local GRID, FRAMES = 8, 64
local TWO_PI = 2 * math.pi

local function Tooltip(tip)
    tip:AddLine(ns.title, 0.4, 0.8, 1)
    local ad, at, zd, zt = ns.Totals()
    tip:AddLine(string.format("Explored: %d/%d areas, %d/%d zones", ad, at, zd, zt), 1, 1, 1)
    local zone = ns.CurrentZone()
    if zone then
        local d, t = ns.ZoneCounts(zone)
        tip:AddLine(string.format("%s: %d/%d", zone.name, d, t), 0.8, 0.8, 0.8)
    end
    tip:AddLine("Automatic routes: " .. (ns.db.autoRoute and "on" or "off"), 0.8, 0.8, 0.8)
    local stop = ns.CurrentStop()
    if stop then
        local left = #ns.ZoneRemaining(ns.route.zone)
        tip:AddLine(string.format("Route: %s, %d area%s left", ns.route.zone.name, left, left == 1 and "" or "s"),
            1, 0.82, 0)
    end
    tip:AddLine(" ")
    tip:AddLine("Click: open", 0.7, 0.7, 0.7)
    tip:AddLine("Right-click: " .. (stop and "stop the route" or "route through this zone"), 0.7, 0.7, 0.7)
end

function ns.SetupMinimap()
    local stub = _G.LibStub
    local ldb = stub and stub("LibDataBroker-1.1", true)
    local icon = stub and stub("LibDBIcon-1.0", true)
    if not (ldb and icon) or ns.launcher then return end
    ns.launcher = ldb:NewDataObject(NAME, {
        type = "launcher",
        text = ns.title,
        icon = ICON,
        OnClick = function(_, button)
            if button == "RightButton" then
                if ns.route then ns.StopRoute() else SlashCmdList.COMPASSFOREVER("route") end
            else
                ns.ToggleWindow()
            end
        end,
        OnTooltipShow = Tooltip,
    })
    icon:Register(NAME, ns.launcher, ns.db.minimap)
    ns.ApplyMinimapSize()
    ns.TurnMinimapArrow()
end

-- One and a half times the usual size, unless "Large minimap button" is off.
-- (A scaled button would sit farther out, off the minimap's edge.) The usual
-- size is for addons that gather minimap buttons into a bar, where a bigger
-- one covers its neighbour. Such addons may also set the button's size
-- themselves (MinimapButtonBag makes every button 31 across), so the ring,
-- background and arrow follow whatever size the button has, from the size
-- and spot LibDBIcon gave each, and always line up.
local GROW = 1.5
local PARTS = { "border", "background", "icon" }
local base                               -- what LibDBIcon gave it, kept once

local function FitParts(button)
    if not base then return end
    local w, h = button:GetSize()
    local gx, gy = (w or base.w) / base.w, (h or base.h) / base.h
    for _, key in ipairs(PARTS) do
        local region, was = button[key], base.parts[key]
        if region and was then
            region:SetSize(was[1] * gx, was[2] * gy)
            local point, rel, relPoint, x, y = was[3], was[4], was[5], was[6], was[7]
            if point then
                region:ClearAllPoints()
                region:SetPoint(point, rel, relPoint, (x or 0) * gx, (y or 0) * gy)
            end
        end
    end
end

function ns.ApplyMinimapSize()
    local stub = _G.LibStub
    local icon = stub and stub("LibDBIcon-1.0", true)
    local button = icon and icon.GetMinimapButton and icon:GetMinimapButton(NAME)
    if not button then return end
    if not base then
        local w, h = button:GetSize()
        base = { w = w, h = h, parts = {} }
        for _, key in ipairs(PARTS) do
            local region = button[key]
            if region then
                local rw, rh = region:GetSize()
                base.parts[key] = { rw, rh, region:GetPoint(1) }
            end
        end
        button:HookScript("OnSizeChanged", FitParts)
    end
    local grow = ns.db.minimapLarge ~= false and GROW or 1
    button:SetSize(base.w * grow, base.h * grow)
    FitParts(button)
end

-- Where the arrow points, as a bearing (radians counter-clockwise from
-- north): the route's next stop, else the nearest area still covered here.
local function Target()
    if ns.travel and ns.TravelVector then
        local bearing = ns.TravelVector()
        if bearing then return bearing end
    end
    local zone, stop = nil, nil
    if ns.NavTarget then zone, stop = ns.NavTarget() end
    if stop then
        local bearing = ns.StopVector(zone, stop)
        if bearing then return bearing end
    end
    local zone = ns.CurrentZone()
    if not zone then return nil end
    local px, py = ns.PlayerOn(zone.map)
    if not px then return nil end
    local best, bestD
    for _, node in ipairs(ns.ZoneRemaining(zone)) do
        for _, p in ipairs(ns.NodePoints(node)) do
            local east, north = (p[1] - px) * zone.w, -(p[2] - py) * zone.h
            local d = east * east + north * north
            if not bestD or d < bestD then
                best, bestD = math.atan2(-east, north), d
            end
        end
    end
    return best
end

local shown = {}
local function Show(cell, r, g, b)
    if shown.cell == cell and shown.r == r and shown.g == g then return end
    shown.cell, shown.r, shown.g = cell, r, g
    local col, row = cell % GRID, math.floor(cell / GRID)
    local launcher = ns.launcher
    launcher.iconCoords = { col / GRID, (col + 1) / GRID, row / GRID, (row + 1) / GRID }
    launcher.iconR, launcher.iconG, launcher.iconB = r, g, b
end

function ns.TurnMinimapArrow()
    if not ns.launcher then return end
    if ns.InFlight and ns.InFlight() then return end     -- held until you land
    local bearing = Target()
    if not bearing then
        Show(0, 1, 0.82, 0.1)          -- nothing to point at: gold, upright
        return
    end
    local ok, facing = pcall(_G.GetPlayerFacing)
    facing = ok and ns.Num(facing) or 0
    local turn = ((bearing - facing) % TWO_PI) / TWO_PI
    local cell = math.floor(turn * FRAMES + 0.5) % FRAMES
    if ns.CurrentStop() then Show(cell, 0.3, 1, 0.35) else Show(cell, 1, 0.82, 0.1) end
end

local ticker = CreateFrame("Frame")
local elapsed = 0
ticker:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + (ns.Num(dt) or 0)
    if elapsed < 0.1 then return end
    elapsed = 0
    if ns.launcher and not (ns.db and ns.db.minimap and ns.db.minimap.hide) then
        pcall(ns.TurnMinimapArrow)
    end
end)
ns.TimeUpdates(ticker, "minimap button")

function ns.SetMinimapShown(on)
    ns.db.minimap.hide = not on or nil
    local stub = _G.LibStub
    local icon = stub and stub("LibDBIcon-1.0", true)
    if not (icon and ns.launcher) then return end
    if on then icon:Show(NAME) else icon:Hide(NAME) end
    ns.Fire("settings")
end
