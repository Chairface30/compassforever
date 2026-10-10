-- Compass Forever: RouteDraw.lua
-- The route as lines on any map: the zone it is in, the zone next door, the
-- continent, or Azeroth. A route that crosses a zone line carries on across
-- it.
--
-- The route is put together once on its continent's map. Walking is drawn
-- along the walking paths (Pathing.lua) once they are found, straight until
-- then; a flight is drawn straight from flight point to flight point.
-- and then turned into the fractions of whatever map is shown, from where
-- that map sits on the continent (C_Map.GetMapRectOnMap). Lines that run off
-- the shown map are cut off by its frame.

local _, ns = ...

local rects = {}

-- Where `mapID` sits on `onMap`: left, right, top, bottom as fractions.
function ns.MapRect(mapID, onMap)
    local key = mapID .. ":" .. onMap
    local r = rects[key]
    if r == nil then
        local ok, left, right, top, bottom = ns.Ask(ns.API("C_Map", "GetMapRectOnMap"), mapID, onMap)
        left, right, top, bottom = ok and ns.Num(left), ok and ns.Num(right), ok and ns.Num(top), ok and ns.Num(bottom)
        if left and right and top and bottom and right > left and bottom > top then
            r = { l = left, r = right, t = top, b = bottom }
        else
            r = false
        end
        rects[key] = r
    end
    return r or nil
end

local function ContinentMap(zone)
    local c = ns.CONTINENT_YARDS and ns.CONTINENT_YARDS[zone.continent]
    return c and c.map
end

-- A point of a zone's map, on its continent's map.
local function ZoneToContinent(zone, x, y, cont)
    local r = ns.MapRect(zone.map, cont)
    if not r then return nil end
    return r.l + x * (r.r - r.l), r.t + y * (r.b - r.t)
end

-- A continent point on a zone's map, if it falls on it.
local function ContinentToZone(zone, x, y, cont)
    local r = ns.MapRect(zone.map, cont)
    if not r then return nil end
    local zx, zy = (x - r.l) / (r.r - r.l), (y - r.t) / (r.b - r.t)
    if zx < 0 or zx > 1 or zy < 0 or zy > 1 then return nil end
    return zx, zy
end
ns.ContinentToZone = ContinentToZone

-- Add a zone path's points (after the first) to a continent point list.
local function AddPath(pts, zone, path, from, cont)
    for i = from or 2, #path do
        local x, y = ZoneToContinent(zone, path[i].x, path[i].y, cont)
        if x then pts[#pts + 1], pts[#pts + 2] = x, y end
    end
end

-- From the player to a point of the continent map: along the walking path
-- in the zone the player is in when both are on its map, else straight.
-- Points as a flat list, starting with the player.
local function WalkFromPlayer(cont, px, py, tx, ty)
    local pts = { px, py }
    local here = ns.CurrentZone()
    if here then
        local hcont = ns.CONTINENT_YARDS and ns.CONTINENT_YARDS[here.continent]
        local gx, gy = hcont and hcont.map == cont and ContinentToZone(here, tx, ty, cont)
        local zx, zy = ns.PlayerOn(here.map)
        if gx and zx and zx >= 0 and zx <= 1 and zy >= 0 and zy <= 1 and ns.Steer then
            local _, _, _, path, k, cx, cy = ns.Steer(here, { x = gx, y = gy }, zx, zy)
            if path then
                local x, y = ZoneToContinent(here, cx, cy, cont)
                pts[#pts + 1], pts[#pts + 2] = x, y
                AddPath(pts, here, path, k + 1, cont)
                return pts
            end
        end
    end
    pts[#pts + 1], pts[#pts + 2] = tx, ty
    return pts
end

-- Between two points of a zone: along the walking path once found.
local function WalkBetween(zone, ax, ay, bx, by, cont, pts)
    local path = ns.PathBetween and ns.PathBetween(zone, ax, ay, bx, by)
    if path then
        AddPath(pts, zone, path, 2, cont)
    else
        local x, y = ZoneToContinent(zone, bx, by, cont)
        if x then pts[#pts + 1], pts[#pts + 2] = x, y end
    end
end

-- The route, on its continent's map: { cont = mapID, parts = { { kind, pts } } }
-- with pts a flat list x1, y1, x2, y2, ...
--   walk  - from you to the next stop (or to the flight master), along the
--           walking path once found;
--   fly   - the flight, straight from flight point to flight point, then the
--           walk from the landing along the map;
--   route - stop to stop, along the walking paths between them.
function ns.RouteGeometry()
    local route = ns.route
    local stop = ns.CurrentStop()
    if not (route and stop) then return nil end
    local zone = route.zone
    local cont = ContinentMap(zone)
    if not cont then return nil end
    local parts = {}
    local px, py = ns.PlayerOn(cont)

    local sx, sy = ZoneToContinent(zone, stop.x, stop.y, cont)
    if not sx then return nil end

    if ns.travel and ns.travel.from and ns.travel.to then
        local f, t = ns.travel.from, ns.travel.to
        if px then parts[#parts + 1] = { kind = "walk", pts = WalkFromPlayer(cont, px, py, f.x, f.y) } end
        parts[#parts + 1] = { kind = "fly", pts = { f.x, f.y, t.x, t.y } }
        local landing = { t.x, t.y }
        local lx, ly = ContinentToZone(zone, t.x, t.y, cont)
        if lx then
            WalkBetween(zone, lx, ly, stop.x, stop.y, cont, landing)
        else
            landing[3], landing[4] = sx, sy
        end
        parts[#parts + 1] = { kind = "walk", pts = landing }
    elseif px then
        -- The walking path, while the player is in the route's zone.
        local zx, zy = ns.PlayerOn(zone.map)
        local inside = zx and zx >= 0 and zx <= 1 and zy >= 0 and zy <= 1
        local pts = { px, py }
        if inside and ns.Steer then
            local _, _, _, path, k, cx, cy = ns.Steer(zone, stop, zx, zy)
            if path then
                local x, y = ZoneToContinent(zone, cx, cy, cont)
                pts[#pts + 1], pts[#pts + 2] = x, y
                AddPath(pts, zone, path, k + 1, cont)
            end
        end
        if #pts == 2 then pts[3], pts[4] = sx, sy end
        parts[#parts + 1] = { kind = "walk", pts = pts }
    end

    local rest = { sx, sy }
    for i = 2, #route.stops do
        local a, b = route.stops[i - 1], route.stops[i]
        WalkBetween(zone, a.x, a.y, b.x, b.y, cont, rest)
    end
    if #rest >= 4 then parts[#parts + 1] = { kind = "route", pts = rest } end
    return { cont = cont, parts = parts }
end

-- A function turning continent fractions into `mapID`'s fractions, or nil
-- when that map isn't on the continent (or is Azeroth, holding it).
function ns.ContinentToMap(cont, mapID)
    if mapID == cont then return function(x, y) return x, y end end
    local inner = ns.MapRect(mapID, cont)
    if inner then
        local w, h = inner.r - inner.l, inner.b - inner.t
        return function(x, y) return (x - inner.l) / w, (y - inner.t) / h end
    end
    local outer = ns.MapRect(cont, mapID)
    if outer then
        local w, h = outer.r - outer.l, outer.b - outer.t
        return function(x, y) return outer.l + x * w, outer.t + y * h end
    end
    return nil
end

local COLORS = {
    walk = { 0.3, 1, 0.35, 0.9 },
    route = { 1, 0.82, 0.1, 0.75 },
    fly = { 0.4, 0.75, 1, 0.9 },
}

-- Draw the route on `canvas` (width x height of its own units), showing map
-- `mapID`. lineFor(i) hands out the i-th line. Returns how many were used.
function ns.DrawRouteOn(canvas, mapID, width, height, lineFor, thickness)
    local geo = ns.RouteGeometry()
    if not geo then return 0 end
    local conv = ns.ContinentToMap(geo.cont, mapID)
    if not conv then return 0 end
    local n = 0
    for _, part in ipairs(geo.parts) do
        local c = COLORS[part.kind]
        local pts = part.pts
        local ax, ay = conv(pts[1], pts[2])
        for i = 3, #pts, 2 do
            local bx, by = conv(pts[i], pts[i + 1])
            n = n + 1
            local l = lineFor(n)
            l:SetThickness(thickness or 2)
            l:SetStartPoint("TOPLEFT", canvas, ax * width, -ay * height)
            l:SetEndPoint("TOPLEFT", canvas, bx * width, -by * height)
            l:SetColorTexture(c[1], c[2], c[3], c[4])
            ax, ay = bx, by
        end
    end
    return n
end

-- The route's stops on `mapID`: each one's number, node and fractions.
function ns.RouteStopsOn(mapID)
    local route = ns.route
    if not route then return {} end
    local cont = ContinentMap(route.zone)
    local conv = cont and ns.ContinentToMap(cont, mapID)
    if not conv then return {} end
    local out = {}
    for i, s in ipairs(route.stops) do
        local cx, cy = ZoneToContinent(route.zone, s.x, s.y, cont)
        if cx then
            local x, y = conv(cx, cy)
            out[#out + 1] = { i = i, node = s.node, x = x, y = y }
        end
    end
    return out
end
