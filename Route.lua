-- Compass Forever: Route.lua
-- The way through a zone's map areas that are still covered, one area at a
-- time: the route heads for the nearest area to where it starts (you in the
-- zone, where you walk in, or a flight master you can fly to), and once that
-- one is uncovered, for the nearest from there, until the zone is done.
--
-- Every area comes with standing points (Data/Exploration.lua, picked from
-- the terrain, or the points just inside its edge from Areas.lua); "nearest"
-- is the nearest of those.

local _, ns = ...

ns.route = nil   -- { zone, stops = { { node, x, y } ... } }

-------------------------------------------------------------------------------
-- Where the player is, on a zone's map
-------------------------------------------------------------------------------

local function XY(vec)
    if type(vec) ~= "table" and type(vec) ~= "userdata" then return nil end
    local x, y
    if vec.GetXY then
        local ok, a, b = pcall(vec.GetXY, vec)
        if ok then x, y = a, b end
    end
    if x == nil then x, y = vec.x, vec.y end
    return ns.Num(x), ns.Num(y)
end

local function Vector(x, y)
    if type(_G.CreateVector2D) == "function" then
        local ok, vec = pcall(_G.CreateVector2D, x, y)
        if ok and vec then return vec end
    end
    return { x = x, y = y, GetXY = function(self) return self.x, self.y end }
end

function ns.PlayerMap()
    local ok, id = ns.Ask(ns.API("C_Map", "GetBestMapForUnit"), "player")
    return ok and ns.Num(id) or nil
end

local function WorldPos(mapID, x, y)
    local ok, continent, vec = ns.Ask(ns.API("C_Map", "GetWorldPosFromMapPos"), mapID, Vector(x, y))
    if not ok then return nil end
    local wx, wy = XY(vec)
    if not wx then return nil end
    return wx, wy, ns.Num(continent)
end

-- A point on one map, as fractions of another (through world coordinates;
-- the other map's corners are converted too, so no axis is assumed).
-- nil, "elsewhere" when the maps are on different continents.
function ns.Translate(fromMap, x, y, toMap)
    if fromMap == toMap then return x, y end
    local wx, wy, wc = WorldPos(fromMap, x, y)
    local ox, oy, oc = WorldPos(toMap, 0, 0)
    if wc and oc and wc ~= oc then return nil, "elsewhere" end
    local ex, ey = WorldPos(toMap, 1, 0)
    local sx, sy = WorldPos(toMap, 0, 1)
    if not (wx and ox and ex and sx) then return nil end
    local ax, ay, bx, by = ex - ox, ey - oy, sx - ox, sy - oy
    local det = ax * by - ay * bx
    if det == 0 then return nil end
    local px, py = wx - ox, wy - oy
    return (px * by - py * bx) / det, (ax * py - ay * px) / det
end

-- The player on `mapID`, as fractions of it (outside 0..1 when the player is
-- in the next zone over). nil when the client will not place the player.
function ns.PlayerOn(mapID)
    local ok, vec = ns.Ask(ns.API("C_Map", "GetPlayerMapPosition"), mapID, "player")
    if ok then
        local x, y = XY(vec)
        if x and y and (x ~= 0 or y ~= 0) then return x, y end
    end
    local here = ns.PlayerMap()
    if not here or here == mapID then return nil end
    ok, vec = ns.Ask(ns.API("C_Map", "GetPlayerMapPosition"), here, "player")
    if not ok then return nil end
    local x, y = XY(vec)
    if not x then return nil end
    return ns.Translate(here, x, y, mapID)
end

-------------------------------------------------------------------------------
-- Planning
-------------------------------------------------------------------------------

local SCALE = 10000

-- A node's standing points as fractions: the points just inside its edge
-- when its outline is known (Areas.lua: the route heads for whichever is
-- nearest on the way), else the ones picked from the terrain.
local function Points(node)
    local area = ns.AreaOf and ns.AreaOf(node)
    if area and #area.edge > 0 then return area.edge end
    local out = {}
    local p = node.points
    for i = 1, #p, 2 do out[#out + 1] = { p[i] / SCALE, p[i + 1] / SCALE } end
    return out
end
ns.NodePoints = Points

-- Where a node's marker sits when it isn't a route stop: the first point
-- picked from the terrain (well inside the area).
function ns.NodeMarker(node)
    return { node.points[1] / SCALE, node.points[2] / SCALE }
end

-- The point of `node` nearest (sx, sy), on `zone`'s map, and how far it is
-- in yards. From a standing point (fromPoint) along the walking paths once
-- they are worked out (Pathing.lua), else in a straight line.
local function Nearest(zone, node, sx, sy, fromPoint)
    local best, bestD
    for _, p in ipairs(Points(node)) do
        local d = fromPoint and ns.PlanCost and ns.PlanCost(zone, sx, sy, p[1], p[2])
        if not d then
            local dx, dy = (p[1] - sx) * zone.w, (p[2] - sy) * zone.h
            d = math.sqrt(dx * dx + dy * dy)
        end
        if not bestD or d < bestD then best, bestD = p, d end
    end
    return best, bestD
end

-- The next stop from (sx, sy): the nearest of `nodes`, as { node, x, y },
-- and how far it is. With no start known, the first of them.
function ns.NextStop(zone, nodes, sx, sy, fromPoint)
    local stop, cost
    for _, node in ipairs(nodes) do
        local p, d
        if sx then
            p, d = Nearest(zone, node, sx, sy, fromPoint)
        else
            p, d = Points(node)[1], 0
        end
        if p and (not cost or d < cost) then stop, cost = { node = node, x = p[1], y = p[2] }, d end
    end
    return stop, cost
end

-------------------------------------------------------------------------------
-- The active route
-------------------------------------------------------------------------------

-- Start the route through `zone`: its first stop, the nearest area to where
-- you start. opts:
--   quiet   = no chat line;
--   first   = the node to head for first (picked on a map);
--   auto    = started on entering the zone; it ends when the player leaves;
--   skipped = overlay ID -> order skipped: those come last.
-- A flight master the character hasn't discovered, in the zone being
-- explored, counts as a stop: learning it now saves a walk every time after.
-- From outside the zone, the route may start where a flight lands instead of
-- where you walk in, when that saves at least this much (yards of running).
local LANDING_SAVES = 210

-- One area only, from a click on its marker: the walk there and nothing
-- after, uncovered or not. It ends on reaching it (or uncovering it).
local function Covered(zone, node)
    for _, n in ipairs(ns.ZoneRemaining(zone)) do
        if n == node then return true end
    end
    return false
end

local function SingleRoute(zone, node, quiet, wasCovered)
    local sx, sy = ns.PlayerOn(zone.map)
    local best, bestD
    for _, p in ipairs(ns.NodePoints(node)) do
        local d = sx and ((p[1] - sx) * zone.w) ^ 2 + ((p[2] - sy) * zone.h) ^ 2 or 0
        if not bestD or d < bestD then best, bestD = p, d end
    end
    local yards = sx and math.sqrt(bestD) or 0
    ns.route = { zone = zone, stops = { { node = node, x = best[1], y = best[2], single = true } },
                 yards = yards, skipped = {}, auto = false, single = node }
    -- covered when picked: uncovering it is what ends the route
    if wasCovered == nil then wasCovered = Covered(zone, node) end
    ns.route.wasCovered = wasCovered
    if not quiet then
        ns.Print(string.format("Heading to %s, about %s on foot.", node.name, ns.Yards(yards)))
    end
    ns.Fire("route")
    return ns.route
end

-- What the route can head for next: the areas still covered and the zone's
-- flight masters not yet learned, leaving out what was skipped. When only
-- skipped ones are left, the one skipped first.
local function Candidates(zone, skipped)
    local list, later = {}, {}
    for _, node in ipairs(ns.ZoneRemaining(zone)) do
        if skipped[node.overlay] then later[#later + 1] = node else list[#list + 1] = node end
    end
    for _, node in ipairs(ns.FlightStops and ns.FlightStops(zone) or {}) do
        if skipped[node.overlay] then later[#later + 1] = node else list[#list + 1] = node end
    end
    if #list == 0 and #later > 0 then
        table.sort(later, function(a, b) return skipped[a.overlay] < skipped[b.overlay] end)
        list[1] = later[1]
    end
    return list
end

-- The player on the zone's map, or on its continent's map when the zone's
-- won't place them (far off), converted; nil when neither will.
local function PlayerOnZone(zone)
    local px, py = ns.PlayerOn(zone.map)
    if px then return px, py end
    local c = ns.CONTINENT_YARDS and ns.CONTINENT_YARDS[zone.continent]
    local cx, cy
    if c then cx, cy = ns.PlayerOn(c.map) end
    local r = cx and ns.MapRect and ns.MapRect(zone.map, c.map)
    if r then return (cx - r.l) / (r.r - r.l), (cy - r.t) / (r.b - r.t) end
    return nil
end

-- Every area still to do, so progress can tell what was just uncovered.
local function LeftSet(zone)
    local left = {}
    for _, node in ipairs(ns.ZoneRemaining(zone)) do left[node] = true end
    return left
end

function ns.StartRoute(zone, opts)
    opts = opts or {}
    -- a replan keeps a one-area route as it is (from where you are now)
    local r = ns.route
    if opts.quiet and r and r.single and r.zone == zone then return SingleRoute(zone, r.single, true, r.wasCovered) end
    local skipped = opts.skipped or {}
    local remaining = ns.ZoneRemaining(zone)
    if #remaining == 0 then
        local had = ns.route ~= nil
        ns.route = nil
        if not opts.quiet then ns.Print(zone.name .. " is already fully explored.") end
        if had or not opts.quiet then ns.Fire("route") end
        return nil
    end
    local px, py = PlayerOnZone(zone)
    local stop, yards, landing
    if opts.first then
        stop, yards = ns.NextStop(zone, { opts.first }, px, py)
    else
        local list = Candidates(zone, skipped)
        stop, yards = ns.NextStop(zone, list, px, py)
        -- From outside the zone: the nearest area to where a known flight
        -- lands, plus the flight (Travel.lua), against walking in.
        if ns.FlightLandings and ns.CurrentZone() ~= zone then
            for _, l in ipairs(ns.FlightLandings(zone)) do
                local s2, y2 = ns.NextStop(zone, list, l.x, l.y)
                if s2 and y2 + l.yards < (yards or 0) - LANDING_SAVES then
                    stop, yards, landing = s2, y2 + l.yards, l
                end
            end
        end
    end
    if not stop then return nil end
    ns.route = { zone = zone, stops = { stop }, yards = yards or 0, skipped = skipped,
                 auto = opts.auto or false, landing = landing, left = LeftSet(zone) }
    if not opts.quiet then
        if landing then
            ns.Print(string.format("%s: %d area%s left, starting where you land at %s.", zone.name,
                #remaining, #remaining == 1 and "" or "s", landing.name))
        else
            ns.Print(string.format("%s: %d area%s left, the nearest about %s on foot.", zone.name,
                #remaining, #remaining == 1 and "" or "s", ns.Yards(yards or 0)))
        end
    end
    ns.Fire("route")
    return ns.route
end

-- On from the stop just reached (or skipped): the nearest of what's left,
-- from where the player is (from the stop when they can't be placed).
local function Onward(r)
    local list = Candidates(r.zone, r.skipped)
    if #list == 0 then return nil end
    local px, py = PlayerOnZone(r.zone)
    local fromPoint = false
    local last = r.stops[1]
    if not px and last then px, py, fromPoint = last.x, last.y, true end
    return ns.NextStop(r.zone, list, px, py, fromPoint)
end

-- A click on an area's marker: a route to that one area alone. Start route
-- gives the whole zone's.
function ns.RouteVia(zone, node)
    SingleRoute(zone, node, false)
end

-- A zone's full route is running (not a one-area route).
function ns.ZoneRouted(zone)
    local r = ns.route
    return r and r.zone == zone and not r.single and true or false
end

function ns.StopRoute()
    ns.route = nil
    ns.Fire("route")
end

-- At the stop of a one-area route: the route is done.
function ns.SingleReached()
    local r = ns.route
    if not (r and r.single) then return end
    ns.route = nil
    ns.Fire("route")
end

function ns.CurrentStop()
    local r = ns.route
    if not r or not r.stops[1] then return nil end
    return r.stops[1], 1
end

-- Leave the current stop for later (an area that will not take, or one the
-- player wants to do another day): the route heads for the nearest other
-- one, and skipped ones come back only when nothing else is left.
local skipCount = 0
function ns.SkipStop()
    local r = ns.route
    local stop = ns.CurrentStop()
    if not stop or r.single then return end
    skipCount = skipCount + 1
    r.skipped[stop.node.overlay] = skipCount
    local nextStop, yards = Onward(r)
    if not nextStop or nextStop.node == stop.node then
        r.skipped[stop.node.overlay] = nil
        return
    end
    r.stops, r.yards = { nextStop }, yards
    ns.Fire("route")
end

function ns.Yards(yards)
    if yards >= 1000 then return string.format("%.1fk yd", yards / 1000) end
    return string.format("%d yd", math.floor(yards + 0.5))
end

-- After any progress: the route's stop is kept until it is uncovered (or,
-- for a flight master, learned); then the route heads for the nearest of
-- what's left from where you are. Areas uncovered on the way don't change
-- it. "uncovered" tells the banner what was found and what is next.
ns.On("progress", function()
    local r = ns.route
    if not r then return end
    -- on a flight: planned again on landing (Travel.lua)
    if ns.InFlight and ns.InFlight() then return end
    if r.single then
        -- a one-area route ends when its area is uncovered
        local node = r.single
        if r.wasCovered and not Covered(r.zone, node) and not node.fp then
            ns.route = nil
            ns.Fire("route")
            ns.Fire("uncovered", r.zone, { node })
        else
            SingleRoute(r.zone, node, true, r.wasCovered)
        end
        return
    end
    local left = LeftSet(r.zone)
    -- what was still to do last time and isn't now
    local found = {}
    for node in pairs(r.left or {}) do
        if not left[node] then found[#found + 1] = node end
    end
    r.left = left
    local stop = r.stops[1]
    local done = stop and not left[stop.node] or false
    if stop and stop.node.fp then
        local known = ns.KnownFlights and ns.KnownFlights() or {}
        done = known[stop.node.fp] and true or false
        if done then found[#found + 1] = stop.node end
    end
    if not next(left) then
        ns.route = nil
        ns.Fire("route")
    elseif done then
        local nextStop, yards = Onward(r)
        if nextStop then
            r.stops, r.yards = { nextStop }, yards
        else
            ns.route = nil
        end
        ns.Fire("route")
    end
    if #found > 0 then ns.Fire("uncovered", r.zone, found) end
end)
