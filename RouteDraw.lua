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
    if r == nil and ns.ZoneRectOnContinent then
        local zone = ns.ZoneByMap(mapID)
        local cont = zone and ns.CONTINENT_YARDS and ns.CONTINENT_YARDS[zone.continent]
        if cont and cont.map == onMap then
            r = ns.ZoneRectOnContinent(zone)
            if r then rects[key] = r end
        end
    end
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

-- A zone point on its continent's map (nil without a known placement).
function ns.ZoneToContinentPoint(zone, x, y)
    local cont = ContinentMap(zone)
    if not cont then return nil end
    return ZoneToContinent(zone, x, y, cont)
end

-- Add a path's points from `from` on to a flat point list.
local function AddPath(pts, path, from)
    for i = from, #path do
        pts[#pts + 1], pts[#pts + 2] = path[i].x, path[i].y
    end
end

-- From the player to a point, both on continent `c`'s map: along the
-- walking path once found (across zone lines), straight until then.
local function WalkFromPlayer(c, px, py, tx, ty, localZone)
    local pts = { px, py }
    if ns.Steer then
        local _, _, _, path, k, cx, cy = ns.Steer(c, { x = tx, y = ty }, px, py, localZone)
        if path then
            pts[#pts + 1], pts[#pts + 2] = cx, cy
            AddPath(pts, path, k + 1)
            return pts
        end
    end
    pts[#pts + 1], pts[#pts + 2] = tx, ty
    return pts
end

-- Between two points on continent `c`'s map: along the walking path once
-- found, appended to `pts` (which already ends at the first point).
local function WalkBetween(c, ax, ay, bx, by, pts, localZone)
    local path = ns.PathBetween and ns.PathBetween(c, ax, ay, bx, by, localZone)
    if path then
        AddPath(pts, path, 2)
    else
        pts[#pts + 1], pts[#pts + 2] = bx, by
    end
end

-- The route, on its continent's map: { cont = mapID, parts = { { kind, pts } } }
-- with pts a flat list x1, y1, x2, y2, ...
--   walk  - from you to the next stop (or to the flight master), along the
--           walking path once found, across zone lines;
--   fly   - the flight, straight from flight point to flight point, then the
--           walk from the landing along the map;
--   route - stop to stop, along the walking paths between them.
--   corpse - while a ghost, from you to your corpse, ahead of everything
--           (the route's stops still drawn, if on the same continent).
function ns.RouteGeometry()
    local corpse = ns.Corpse and ns.Corpse()
    local route = ns.route
    local stop = ns.CurrentStop()
    local zone = route and stop and route.zone
    -- on the other continent: the way to the dock across, nothing after
    local cross = zone and ns.Crossing and ns.Crossing(zone, stop)
    if cross then zone, stop = cross.zone, cross.stop end
    local cont = zone and ContinentMap(zone)
    local c = zone and zone.continent
    local parts = {}
    if corpse then
        parts[1] = { kind = "corpse", pts = WalkFromPlayer(corpse.c, corpse.px, corpse.py, corpse.x, corpse.y) }
        if cont ~= corpse.cont then return { cont = corpse.cont, c = corpse.c, parts = parts } end
    end
    if not cont then return nil end
    local px, py = ns.PlayerOn(cont)
    -- in the zone, the walk keeps inside its zone lines
    local lz = ns.LocalZone and ns.LocalZone(zone)

    local sx, sy = ZoneToContinent(zone, stop.x, stop.y, cont)
    if not sx then return nil end

    if corpse then
        -- the walk to the next stop waits until you're alive
    elseif ns.travel and ns.travel.from and ns.travel.to then
        local f, t = ns.travel.from, ns.travel.to
        if px then parts[#parts + 1] = { kind = "walk", pts = WalkFromPlayer(c, px, py, f.x, f.y, lz) } end
        parts[#parts + 1] = { kind = "fly", pts = { f.x, f.y, t.x, t.y } }
        local landing = { t.x, t.y }
        WalkBetween(c, t.x, t.y, sx, sy, landing)
        parts[#parts + 1] = { kind = "walk", pts = landing }
    elseif px then
        parts[#parts + 1] = { kind = "walk", pts = WalkFromPlayer(c, px, py, sx, sy, lz) }
    end

    if cross then return { cont = cont, c = c, parts = parts } end
    local rest = { sx, sy }
    local ax, ay = sx, sy
    for i = 2, #route.stops do
        local b = route.stops[i]
        local bx, by = ZoneToContinent(zone, b.x, b.y, cont)
        if bx then
            WalkBetween(c, ax, ay, bx, by, rest, zone)
            ax, ay = bx, by
        end
    end
    if #rest >= 4 then parts[#parts + 1] = { kind = "route", pts = rest } end
    return { cont = cont, c = c, parts = parts }
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
    corpse = { 0.9, 0.92, 1, 0.95 },
}
ns.ROUTE_COLORS = COLORS

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
