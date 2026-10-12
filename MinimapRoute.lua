-- Compass Forever: MinimapRoute.lua
-- The route drawn on the minimap as well: the same lines as the world map
-- and the window (RouteDraw.lua), around the player at the minimap's zoom,
-- turning with it when it rotates, cut off at its edge, with a dot on each
-- stop in reach.

local _, ns = ...

local TICK = 0.05          -- how often the lines follow the player
local GEOMETRY_TICK = 1    -- how often the route's shape is asked for again
local DOT = 7

-- Minimap view diameter in yards for each zoom level, outdoors and indoors,
-- for clients without C_Minimap.GetViewRadius.
local OUTDOOR = { 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3 }
local INDOOR = { 300, 240, 180, 120, 80, 50 }

local overlay, lines, dots
local geometry, geometryAge = nil, GEOMETRY_TICK
local elapsed = 0

-- Yards from the player to the minimap's edge.
local function ViewRadius()
    local api = ns.API("C_Minimap", "GetViewRadius")
    if api then
        local ok, r = ns.Ask(api)
        r = ok and ns.Num(r)
        if r and r > 0 then return r end
    end
    local zoom = (ns.Num(Minimap:GetZoom()) or 0) + 1
    local indoors = IsIndoors and IsIndoors()
    local sizes = indoors and INDOOR or OUTDOOR
    return (sizes[zoom] or sizes[1]) / 2
end

-- The part of segment a-b inside the minimap: a circle of radius r, or a
-- square of half-side r. nil when none of it is.
local function Clip(ax, ay, bx, by, r, square)
    local dx, dy = bx - ax, by - ay
    local t0, t1 = 0, 1
    if square then
        local p = { -dx, dx, -dy, dy }
        local q = { ax + r, r - ax, ay + r, r - ay }
        for i = 1, 4 do
            if p[i] == 0 then
                if q[i] < 0 then return nil end
            else
                local t = q[i] / p[i]
                if p[i] < 0 then
                    if t > t1 then return nil end
                    if t > t0 then t0 = t end
                else
                    if t < t0 then return nil end
                    if t < t1 then t1 = t end
                end
            end
        end
    else
        local a = dx * dx + dy * dy
        if a == 0 then return nil end
        local b = 2 * (ax * dx + ay * dy)
        local c = ax * ax + ay * ay - r * r
        local disc = b * b - 4 * a * c
        if disc <= 0 then return nil end
        local s = math.sqrt(disc)
        local e0, e1 = (-b - s) / (2 * a), (-b + s) / (2 * a)
        t0, t1 = math.max(0, e0), math.min(1, e1)
        if t0 >= t1 then return nil end
    end
    return ax + dx * t0, ay + dy * t0, ax + dx * t1, ay + dy * t1
end

local function Hide(from)
    for i = from, #lines do lines[i]:Hide() end
end

local function HideDots(from)
    for i = from, #dots do dots[i]:Hide() end
end

local function Draw()
    local corpse = ns.Corpse and ns.Corpse()
    if not (ns.db and ns.db.minimapRoute ~= false and (corpse or ns.route and ns.CurrentStop())) then
        Hide(1)
        HideDots(1)
        return
    end
    if geometryAge >= GEOMETRY_TICK or not geometry then
        geometry = ns.RouteGeometry()
        geometryAge = 0
    end
    local cont = geometry and ns.CONTINENT_YARDS and ns.CONTINENT_YARDS[geometry.c]
    local px, py
    if cont and geometry then
        px, py = ns.PlayerOn(geometry.cont)
    end
    if not (px and py) then
        Hide(1)
        HideDots(1)
        return
    end

    local half = overlay:GetWidth() / 2
    local square = GetMinimapShape and GetMinimapShape() == "SQUARE"
    local edge = half * (square and 0.98 or 0.96)
    local perYard = half / ViewRadius()
    -- turned so the way the player faces is up, when the minimap rotates
    local cosF, sinF = 1, 0
    if GetCVar("rotateMinimap") == "1" then
        local facing = ns.Num(GetPlayerFacing and GetPlayerFacing())
        if not facing then
            Hide(1)
            HideDots(1)
            return
        end
        cosF, sinF = math.cos(facing), math.sin(facing)
    end
    -- continent fractions to pixels from the minimap's middle (x right, y up)
    local function Screen(x, y)
        local east = (x - px) * cont.w * perYard
        local north = -(y - py) * cont.h * perYard
        return east * cosF + north * sinF, -east * sinF + north * cosF
    end

    local n = 0
    local colors = ns.ROUTE_COLORS
    for _, part in ipairs(geometry.parts) do
        local c = colors[part.kind]
        local pts = part.pts
        local ax, ay = Screen(pts[1], pts[2])
        for i = 3, #pts, 2 do
            local bx, by = Screen(pts[i], pts[i + 1])
            local x0, y0, x1, y1 = Clip(ax, ay, bx, by, edge, square)
            if x0 then
                n = n + 1
                local l = lines[n]
                if not l then
                    l = overlay:CreateLine(nil, "OVERLAY")
                    l:SetThickness(3)
                    lines[n] = l
                end
                l:SetStartPoint("CENTER", overlay, x0, y0)
                l:SetEndPoint("CENTER", overlay, x1, y1)
                l:SetColorTexture(c[1], c[2], c[3], c[4])
                l:Show()
            end
            ax, ay = bx, by
        end
    end
    Hide(n + 1)

    -- the stops in reach: gold, the next one larger
    local d = 0
    local _, current = ns.CurrentStop()
    local zone = ns.route and ns.route.zone
    local stops = zone and zone.continent == geometry.c and ns.route.stops or {}
    for i, stop in ipairs(stops) do
        local cx, cy = ns.ZoneToContinentPoint(zone, stop.x, stop.y)
        if cx then
            local sx, sy = Screen(cx, cy)
            local inside = square and (math.abs(sx) <= edge and math.abs(sy) <= edge) or (sx * sx + sy * sy <= edge * edge)
            if inside then
                d = d + 1
                local dot = dots[d]
                if not dot then
                    dot = overlay:CreateTexture(nil, "OVERLAY", nil, 7)
                    dot:SetTexture("Interface\\COMMON\\Indicator-Yellow")
                    dots[d] = dot
                end
                local size = (i == current) and DOT + 4 or DOT
                dot:SetSize(size, size)
                dot:ClearAllPoints()
                dot:SetPoint("CENTER", overlay, "CENTER", sx, sy)
                dot:Show()
            end
        end
    end
    HideDots(d + 1)
end

function ns.SetupMinimapRoute()
    if overlay or not Minimap then return end
    overlay = CreateFrame("Frame", nil, Minimap)
    overlay:SetAllPoints(Minimap)
    overlay:SetFrameLevel(Minimap:GetFrameLevel() + 5)
    lines, dots = {}, {}
    overlay:SetScript("OnUpdate", function(_, step)
        elapsed = elapsed + step
        geometryAge = geometryAge + step
        if elapsed < TICK then return end
        elapsed = 0
        Draw()
    end)
end

-- A new or changed route is drawn at once, its shape asked for again.
local function Redraw()
    geometry = nil
    if overlay then Draw() end
end
ns.On("route", Redraw)
ns.On("settings", Redraw)
ns.On("progress", Redraw)
