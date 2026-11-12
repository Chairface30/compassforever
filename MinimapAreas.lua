-- Compass Forever: MinimapAreas.lua
-- The outlines of the areas of the zone you're in, on the minimap: the same
-- outlines and colours as the window's map (Areas.lua), around the player at
-- the minimap's zoom, turning with it when it rotates, cut off at its edge
-- (MinimapRoute.lua does the same for the route). Under the route's lines.

local _, ns = ...

local TICK = 0.05          -- how often the lines follow the player
local ZONE_TICK = 0.5      -- how often the zone you're in is asked for again

local overlay, lines
local zone, zoneAge = nil, ZONE_TICK
local elapsed = 0

-- Each outline turned into its continent's fractions once, with its bounds,
-- so the ones nowhere near the minimap are passed over: ring -> converted
-- ring, or false where the zone has no known spot on its continent.
local onContinent = setmetatable({}, { __mode = "k" })

local function Converted(z, r, contMap)
    local c = onContinent[r]
    if c ~= nil then return c or nil end
    local rect = ns.MapRect(z.map, contMap)
    if not rect then
        onContinent[r] = false
        return nil
    end
    local w, h = rect.r - rect.l, rect.b - rect.t
    c = {}
    local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
    for i = 1, #r - 1, 2 do
        local x, y = rect.l + r[i] * w, rect.t + r[i + 1] * h
        c[i], c[i + 1] = x, y
        if x < minX then minX = x end
        if x > maxX then maxX = x end
        if y < minY then minY = y end
        if y > maxY then maxY = y end
    end
    c.minX, c.maxX, c.minY, c.maxY = minX, maxX, minY, maxY
    onContinent[r] = c
    return c
end

local function Hide(from)
    for i = from, #lines do lines[i]:Hide() end
end

local function Draw()
    local cont = zone and ns.db and ns.db.minimapBorders ~= false
        and ns.CONTINENT_YARDS and ns.CONTINENT_YARDS[zone.continent]
    local px, py
    if cont then px, py = ns.PlayerOn(cont.map) end
    if not (px and py) then
        Hide(1)
        return
    end

    local half = overlay:GetWidth() / 2
    local square = GetMinimapShape and GetMinimapShape() == "SQUARE"
    local edge = half * (square and 0.98 or 0.96)
    local radius = ns.MinimapViewRadius()
    local perYard = half / radius
    -- turned so the way the player faces is up, when the minimap rotates
    local cosF, sinF = 1, 0
    if GetCVar("rotateMinimap") == "1" then
        local facing = ns.Num(GetPlayerFacing and GetPlayerFacing())
        if not facing then
            Hide(1)
            return
        end
        cosF, sinF = math.cos(facing), math.sin(facing)
    end
    local function Screen(x, y)
        local east = (x - px) * cont.w * perYard
        local north = -(y - py) * cont.h * perYard
        return east * cosF + north * sinF, -east * sinF + north * cosF
    end
    -- how far the minimap reaches, in continent fractions (its corners too)
    local reachX, reachY = radius * 1.5 / cont.w, radius * 1.5 / cont.h

    local n = 0
    ns.EachOutline(zone, ns.db.doneAreaBorders ~= false, function(r, c)
        local cr = Converted(zone, r, cont.map)
        if not cr or cr.maxX < px - reachX or cr.minX > px + reachX
            or cr.maxY < py - reachY or cr.minY > py + reachY then
            return
        end
        local m = #r
        local ax, ay = Screen(cr[m - 1], cr[m])
        for k = 1, m - 1, 2 do
            local bx, by = Screen(cr[k], cr[k + 1])
            local x0, y0, x1, y1 = ns.MinimapClip(ax, ay, bx, by, edge, square)
            if x0 then
                n = n + 1
                local l = lines[n]
                if not l then
                    l = overlay:CreateLine(nil, "ARTWORK")
                    l:SetThickness(1.5)
                    lines[n] = l
                end
                l:SetStartPoint("CENTER", overlay, x0, y0)
                l:SetEndPoint("CENTER", overlay, x1, y1)
                l:SetColorTexture(c[1], c[2], c[3], c[4])
                l:Show()
            end
            ax, ay = bx, by
        end
    end)
    Hide(n + 1)
end

function ns.SetupMinimapAreas()
    if overlay or not Minimap then return end
    local o = CreateFrame("Frame", nil, Minimap)
    if type(o.CreateLine) ~= "function" then return end
    o:SetAllPoints(Minimap)
    -- under the route's lines (MinimapRoute.lua, 5 above the minimap)
    o:SetFrameLevel(Minimap:GetFrameLevel() + 4)
    overlay, lines = o, {}
    o:SetScript("OnUpdate", function(_, step)
        elapsed = elapsed + step
        zoneAge = zoneAge + step
        if elapsed < TICK then return end
        elapsed = 0
        if zoneAge >= ZONE_TICK then
            zone = ns.CurrentZone()
            zoneAge = 0
        end
        Draw()
    end)
    ns.TimeUpdates(o, "minimap borders")
end

-- Drawn again at once when what shows (or its colour) changes.
local function Redraw()
    zoneAge = ZONE_TICK
    elapsed = TICK
end
ns.On("route", Redraw)
ns.On("settings", Redraw)
ns.On("progress", Redraw)
