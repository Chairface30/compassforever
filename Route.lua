-- Compass Forever: Route.lua
-- The shortest walk through a zone's map areas that are still covered.
--
-- Every area comes with a few standing points (Data/Exploration.lua, picked
-- from the terrain: well inside the area and on flat ground). The route starts
-- where the player stands and visits one point per area:
--
--   1. nearest first: from here, always to the closest point of an area not
--      yet on the route;
--   2. then improved until nothing helps: reverse any stretch that gets
--      shorter for it (2-opt), move any one stop to where it costs least, and
--      let each stop take whichever of its points sits best between its
--      neighbours.
--
-- A zone has at most a couple of dozen areas, so this takes no time and is
-- simply redone whenever an area is uncovered or the player picks a zone.

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

-- Plan a route through `nodes` on `zone`, starting at (sx, sy) or, with no
-- start, wherever makes the walk shortest. Returns { { node, x, y } ... } and
-- its length in yards.
--
-- Legs between standing points cost what walking them costs around cliffs
-- and mountains (Pathing.lua, worked out ahead of time); a leg from the
-- player, or between points the terrain data doesn't cover, is a straight
-- line. Walking costs differ a little each way (down is easier than up), so
-- the planner uses the average of the two: its moves assume a leg costs the
-- same both ways.
function ns.PlanRoute(zone, nodes, sx, sy)
    local w, h = zone.w, zone.h
    local function Straight(a, b)
        local dx, dy = (a.x - b.x) * w, (a.y - b.y) * h
        return math.sqrt(dx * dx + dy * dy)
    end
    local function D(a, b)
        -- over the waypoint graph, walls and roads included, once worked out
        if a.node and b.node and ns.PlanCost then
            local c = ns.PlanCost(zone, a.x, a.y, b.x, b.y)
            if c then return c end
        end
        if a.id and b.id then
            local ab, ba = ns.WalkCost(zone, a.id, b.id), ns.WalkCost(zone, b.id, a.id)
            if ab and ba then return (ab + ba) / 2 end
        end
        return Straight(a, b)
    end
    local n = #nodes
    if n == 0 then return {}, 0 end
    local start = sx and { x = sx, y = sy } or nil
    local pts = {}
    for i, node in ipairs(nodes) do
        pts[i] = {}
        for k, p in ipairs(Points(node)) do
            -- an edge point has no terrain costs worked out (the graph's
            -- cover it)
            local own = ns.AreaOf and ns.AreaOf(node)
            pts[i][k] = { x = p[1], y = p[2], node = true,
                          id = not own and ns.PointID and ns.PointID(zone, node, k) or nil }
        end
    end

    -- 1. Nearest first, from the start (or from a given first node).
    local function Greedy(from, firstNode)
        local used, order, pick = {}, {}, {}
        local cur = from
        if firstNode then
            used[firstNode] = true
            order[1], pick[1] = firstNode, 1
            cur = pts[firstNode][1]
        end
        while #order < n do
            local best, bestK, bestD
            for i = 1, n do
                if not used[i] then
                    for k, p in ipairs(pts[i]) do
                        local d = cur and D(cur, p) or 0
                        if not bestD or d < bestD then best, bestK, bestD = i, k, d end
                    end
                end
            end
            used[best] = true
            order[#order + 1], pick[#pick + 1] = best, bestK
            cur = pts[best][bestK]
        end
        return order, pick
    end

    local function P(order, pick, i)
        return pts[order[i]][pick[i]]
    end

    local function Length(order, pick)
        local total, cur = 0, start
        for i = 1, #order do
            local p = P(order, pick, i)
            if cur then total = total + D(cur, p) end
            cur = p
        end
        return total
    end

    -- Each stop takes the point that sits best between its neighbours.
    local function Reselect(order, pick)
        local m = #order
        local moved = false
        for i = 1, m do
            local prev = i > 1 and P(order, pick, i - 1) or start
            local nxt = i < m and P(order, pick, i + 1) or nil
            local bestK, bestC = pick[i], nil
            for k, p in ipairs(pts[order[i]]) do
                local c = (prev and D(prev, p) or 0) + (nxt and D(p, nxt) or 0)
                if not bestC or c < bestC - 0.01 then bestK, bestC = k, c end
            end
            if bestK ~= pick[i] then pick[i], moved = bestK, true end
        end
        return moved
    end

    -- 2. Improve until no move helps. Each move is costed by the few legs it
    -- changes, not by re-measuring the walk. Position 0 is the start.
    local function Improve(order, pick)
        local m = #order
        local function Pos(i)
            if i == 0 then return start end
            if i < 1 or i > m then return nil end
            return P(order, pick, i)
        end
        local function E(i, j)
            local a, b = Pos(i), Pos(j)
            if not (a and b) then return 0 end
            return D(a, b)
        end

        local function Step()
            -- 2-opt: reverse positions i..j.
            for i = 1, m - 1 do
                for j = i + 1, m do
                    local delta = E(i - 1, j) + E(i, j + 1) - E(i - 1, i) - E(j, j + 1)
                    if delta < -0.5 then
                        for a = 0, math.floor((j - i - 1) / 2) do
                            order[i + a], order[j - a] = order[j - a], order[i + a]
                            pick[i + a], pick[j - a] = pick[j - a], pick[i + a]
                        end
                        return true
                    end
                end
            end
            -- Move the run i..e (any length) to between j and j+1, either way
            -- round.
            for len = 1, m - 1 do
                for i = 1, m - len + 1 do
                    local e = i + len - 1
                    local gain = E(i - 1, i) + E(e, e + 1) - E(i - 1, e + 1)
                    for j = 0, m do
                        if j < i - 1 or j > e then
                            for flip = 0, 1 do
                                local first, last = i, e
                                if flip == 1 then first, last = e, i end
                                if not (flip == 1 and len == 1) then
                                    local cost = E(j, first) + E(last, j + 1) - E(j, j + 1)
                                    if cost - gain < -0.5 then
                                        local segO, segK, o2, k2 = {}, {}, {}, {}
                                        for a = i, e do segO[#segO + 1], segK[#segK + 1] = order[a], pick[a] end
                                        if flip == 1 then
                                            for a = 1, math.floor(len / 2) do
                                                segO[a], segO[len - a + 1] = segO[len - a + 1], segO[a]
                                                segK[a], segK[len - a + 1] = segK[len - a + 1], segK[a]
                                            end
                                        end
                                        if j == 0 then
                                            for b = 1, len do o2[#o2 + 1], k2[#k2 + 1] = segO[b], segK[b] end
                                        end
                                        for a = 1, m do
                                            if a < i or a > e then o2[#o2 + 1], k2[#k2 + 1] = order[a], pick[a] end
                                            if a == j then
                                                for b = 1, len do o2[#o2 + 1], k2[#k2 + 1] = segO[b], segK[b] end
                                            end
                                        end
                                        for a = 1, m do order[a], pick[a] = o2[a], k2[a] end
                                        return true
                                    end
                                end
                            end
                        end
                    end
                end
            end
            return false
        end

        for _ = 1, 2000 do
            Reselect(order, pick)
            if not Step() then break end
        end
        Reselect(order, pick)
        return order, pick, Length(order, pick)
    end

    -- 3. Few enough areas to be sure: the exact shortest walk through the
    -- chosen points (Held-Karp), then each stop's point chosen again for its
    -- new neighbours, until that changes nothing.
    local EXACT = 11
    local function Exact(order, pick)
        local m = #order
        for _ = 1, 4 do
            local P2 = {}
            for i = 1, m do P2[i] = P(order, pick, i) end
            local full = 2 ^ m - 1
            local dp, from, bit = {}, {}, {}
            for i = 1, m do bit[i] = 2 ^ (i - 1) end
            for i = 1, m do
                dp[bit[i]] = dp[bit[i]] or {}
                from[bit[i]] = from[bit[i]] or {}
                dp[bit[i]][i] = start and D(start, P2[i]) or 0
            end
            for mask = 1, full do
                local row = dp[mask]
                if row then
                    for j = 1, m do
                        local c = row[j]
                        if c then
                            for k = 1, m do
                                if math.floor(mask / bit[k]) % 2 == 0 then
                                    local nm = mask + bit[k]
                                    local nc = c + D(P2[j], P2[k])
                                    dp[nm] = dp[nm] or {}
                                    from[nm] = from[nm] or {}
                                    if not dp[nm][k] or nc < dp[nm][k] then
                                        dp[nm][k], from[nm][k] = nc, j
                                    end
                                end
                            end
                        end
                    end
                end
            end
            local last, best
            for j = 1, m do
                if dp[full][j] and (not best or dp[full][j] < best) then last, best = j, dp[full][j] end
            end
            local seq, mask = {}, full
            while last do
                table.insert(seq, 1, last)
                local prev = from[mask] and from[mask][last]
                mask = mask - bit[last]
                last = prev
            end
            local o2, k2 = {}, {}
            for i, idx in ipairs(seq) do o2[i], k2[i] = order[idx], pick[idx] end
            order, pick = o2, k2
            if not Reselect(order, pick) then break end
        end
        return order, pick, Length(order, pick)
    end

    -- Several starts, keeping the shortest: from the player, greedy, and
    -- with each of the few closest areas forced first (one wrong first step
    -- can lock the greedy walk into a long detour the moves do not undo).
    local bestOrder, bestPick, bestLen
    local function Try(o, k)
        local o2, k2, len = Improve(o, k)
        if n <= EXACT then o2, k2, len = Exact(o2, k2) end
        if not bestLen or len < bestLen - 0.5 then bestOrder, bestPick, bestLen = o2, k2, len end
    end
    if start then
        Try(Greedy(start))
        if n > EXACT then
            local near = {}
            for i = 1, n do
                local d
                for _, p in ipairs(pts[i]) do
                    local dd = D(start, p)
                    if not d or dd < d then d = dd end
                end
                near[i] = { i = i, d = d }
            end
            table.sort(near, function(a, b) return a.d < b.d end)
            for r = 2, math.min(n, 5) do Try(Greedy(start, near[r].i)) end
        end
    elseif n <= EXACT then
        Try(Greedy(nil, 1))
    else
        for first = 1, n do Try(Greedy(nil, first)) end
    end

    local stops = {}
    for i, idx in ipairs(bestOrder) do
        local p = pts[idx][bestPick[i]]
        stops[i] = { node = nodes[idx], x = p.x, y = p.y }
    end
    return stops, bestLen
end

-------------------------------------------------------------------------------
-- The active route
-------------------------------------------------------------------------------

-- (Re)plan the route through `zone` from where the player is now.
-- opts:
--   quiet   = no chat line;
--   first   = a node to visit first (picked on a map), the rest planned on
--             from there;
--   auto    = started on entering the zone; it ends when the player leaves;
--   skipped = overlay ID -> order skipped: those stay at the end.
-- A flight master the character hasn't discovered, in the zone being
-- explored, is always a stop: learning it now saves a walk every time after.
-- From outside the zone, the route may start where a flight lands instead of
-- where you stand, when that saves at least this much (yards of running).
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

local StartTrip, AdvanceTrip

function ns.StartRoute(zone, opts)
    opts = opts or {}
    -- the player's own pick: with "Zones on the way" on, a trip through the
    -- zones between here and there; any trip under way gives way to it
    if not opts.quiet and not opts.leg then
        ns.trip = nil
        if ns.db.onTheWay and StartTrip(zone) then return ns.route end
    end
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
    local flights = ns.FlightStops and ns.FlightStops(zone) or {}
    local first, now, later, extra = nil, {}, {}, {}
    for _, node in ipairs(remaining) do
        if node == opts.first then first = node
        elseif skipped[node.overlay] then later[#later + 1] = node
        else now[#now + 1] = node end
    end
    for _, node in ipairs(flights) do
        if node == opts.first then first = node
        elseif not skipped[node.overlay] then extra[#extra + 1] = node end
    end
    table.sort(later, function(a, b) return skipped[a.overlay] < skipped[b.overlay] end)

    local px, py = ns.PlayerOn(zone.map)
    if not px then
        -- not placed on the zone's map (another zone, far off): through the
        -- continent's, so the walk there still counts
        local c = ns.CONTINENT_YARDS and ns.CONTINENT_YARDS[zone.continent]
        local cx, cy
        if c then cx, cy = ns.PlayerOn(c.map) end
        local r = cx and ns.MapRect and ns.MapRect(zone.map, c.map)
        if r then px, py = (cx - r.l) / (r.r - r.l), (cy - r.t) / (r.b - r.t) end
    end
    local function Plan(list, sx, sy)
        if not first then return ns.PlanRoute(zone, list, sx, sy) end
        -- The chosen area first: its point nearest the player, then the rest
        -- planned on from there.
        local best, bestD
        for _, p in ipairs(ns.NodePoints(first)) do
            local d = sx and ((p[1] - sx) * zone.w) ^ 2 + ((p[2] - sy) * zone.h) ^ 2 or 0
            if not bestD or d < bestD then best, bestD = p, d end
        end
        local stops = { { node = first, x = best[1], y = best[2] } }
        local rest, len = ns.PlanRoute(zone, list, best[1], best[2])
        for _, stop in ipairs(rest) do stops[#stops + 1] = stop end
        return stops, len + (sx and math.sqrt(bestD) or 0)
    end
    local list = {}
    for _, node in ipairs(now) do list[#list + 1] = node end
    for _, node in ipairs(extra) do list[#list + 1] = node end
    local stops, yards = Plan(list, px, py)
    -- From outside the zone: the route from each known flight point in reach
    -- of it, plus the time to get there by air (Travel.lua), against walking
    -- in. The flight itself is then planned for the first stop as usual.
    local landing
    if not first and ns.FlightLandings and ns.CurrentZone() ~= zone then
        for _, l in ipairs(ns.FlightLandings(zone)) do
            local s2, y2 = Plan(list, l.x, l.y)
            if y2 + l.yards < yards - LANDING_SAVES then stops, yards, landing = s2, y2 + l.yards, l end
        end
    end
    for _, node in ipairs(later) do
        local p = ns.NodePoints(node)[1]
        stops[#stops + 1] = { node = node, x = p[1], y = p[2] }
    end
    ns.route = { zone = zone, stops = stops, yards = yards, skipped = skipped, auto = opts.auto or false,
                 landing = landing }
    if not opts.quiet then
        if landing then
            ns.Print(string.format("%s: %d area%s left, starting where you land at %s.", zone.name,
                #remaining, #remaining == 1 and "" or "s", landing.name))
        else
            ns.Print(string.format("%s: %d area%s left, about %s on foot.", zone.name,
                #remaining, #remaining == 1 and "" or "s", ns.Yards(yards)))
        end
    end
    ns.Fire("route")
    return ns.route
end

-- A click on an area's marker: a route to that one area alone. Start route
-- gives the whole zone's.
function ns.RouteVia(zone, node, leg)
    if not leg then
        ns.trip = nil
        if ns.db.onTheWay and StartTrip(zone, node) then return end
    end
    SingleRoute(zone, node, false)
end

-- A zone's full route is running (not a one-area route).
function ns.ZoneRouted(zone)
    local r = ns.route
    if ns.trip and ns.trip.target == zone and not ns.trip.node then return true end
    return r and r.zone == zone and not r.single and true or false
end

function ns.StopRoute()
    ns.route = nil
    ns.trip = nil
    ns.Fire("route")
end

-- At the stop of a one-area route: the route is done.
function ns.SingleReached()
    local r = ns.route
    if not (r and r.single) then return end
    ns.route = nil
    ns.Fire("route")
    AdvanceTrip()
end

function ns.CurrentStop()
    local r = ns.route
    if not r or not r.stops[1] then return nil end
    return r.stops[1], 1
end

-- Leave the current stop for later (an area that will not take, or one the
-- player wants to do another day): it goes to the end of the route and stays
-- there through every replan.
local skipCount = 0
function ns.SkipStop()
    local r = ns.route
    local stop = ns.CurrentStop()
    if not stop or #r.stops < 2 then return end
    skipCount = skipCount + 1
    r.skipped[stop.node.overlay] = skipCount
    table.remove(r.stops, 1)
    r.stops[#r.stops + 1] = stop
    ns.Fire("route")
end

function ns.Yards(yards)
    if yards >= 1000 then return string.format("%.1fk yd", yards / 1000) end
    return string.format("%d yd", math.floor(yards + 0.5))
end

-- After any progress: replan from here, so a stop uncovered by walking
-- through it on the way somewhere else drops out and the rest re-orders.
-- "uncovered" tells the banner what was found and what is next.
ns.On("progress", function()
    local r = ns.route
    if not r then return end
    if r.single then
        -- a one-area route ends when its area is uncovered
        local node = r.single
        if r.wasCovered and not Covered(r.zone, node) and not node.fp then
            ns.route = nil
            ns.Fire("route")
            ns.Fire("uncovered", r.zone, { node })
            AdvanceTrip()
        else
            SingleRoute(r.zone, node, true, r.wasCovered)
        end
        return
    end
    local before = {}
    for _, stop in ipairs(r.stops) do before[#before + 1] = stop.node end
    ns.StartRoute(r.zone, { quiet = true, skipped = r.skipped, auto = r.auto })
    local still = {}
    for _, stop in ipairs(ns.route and ns.route.stops or {}) do still[stop.node] = true end
    -- A flight master's stop also drops out when it's no longer worth the
    -- walk; only one now known was actually learned.
    local known = ns.KnownFlights and ns.KnownFlights() or {}
    local found = {}
    for _, node in ipairs(before) do
        if not still[node] and (not node.fp or known[node.fp]) then found[#found + 1] = node end
    end
    if #found > 0 then ns.Fire("uncovered", r.zone, found) end
    -- a zone on the way done: on to the next
    if not ns.route then AdvanceTrip() end
end)

-------------------------------------------------------------------------------
-- Zones on the way
-------------------------------------------------------------------------------

-- With "Zones on the way" on (db.onTheWay), a route to another zone of your
-- continent first clears every zone with areas left that you'd pass through
-- going there, in the order you reach them, each with its own zone route
-- (so everything above works as it does for one zone); the zone you picked
-- comes last. ns.trip = { target, node, legs = { zone ... } }: the zones
-- still to come after the one being routed.
--
-- On the way: the straight line from you to the target's nearest area left
-- (or the one picked), looked at every STEP yards; a zone is on it where the
-- line crosses one of its areas' outlines.
local STEP = 120
ns.trip = nil

local function ZonesOnTheWay(target, node)
    local c = ns.CONTINENT_YARDS and ns.CONTINENT_YARDS[target.continent]
    if not c or ns.PlayerContinent() ~= target.continent then return {} end
    local px, py = ns.PlayerOn(c.map)
    if not px then return {} end
    -- where you're going: the picked area, or the target's nearest left
    local tx, ty, bestD
    local nodes = node and { node } or ns.ZoneRemaining(target)
    for _, n in ipairs(nodes) do
        for _, p in ipairs(ns.NodePoints(n)) do
            local cx, cy = ns.ZoneToContinentPoint(target, p[1], p[2])
            if cx then
                local d = ((cx - px) * c.w) ^ 2 + ((cy - py) * c.h) ^ 2
                if not bestD or d < bestD then tx, ty, bestD = cx, cy, d end
            end
        end
    end
    if not tx then return {} end
    -- the zones with areas left, and where each sits on the continent
    local cands = {}
    for _, z in ipairs(ns.ZONES) do
        if z ~= target and z.continent == target.continent and #ns.ZoneRemaining(z) > 0 then
            local r = ns.MapRect(z.map, c.map)
            if r then cands[#cands + 1] = { zone = z, r = r } end
        end
    end
    local steps = math.max(1, math.ceil(math.sqrt(bestD) / STEP))
    local found, order = {}, {}
    for i = 0, steps do
        local cx, cy = px + (tx - px) * i / steps, py + (ty - py) * i / steps
        for _, cand in ipairs(cands) do
            local z, r = cand.zone, cand.r
            if not found[z] and cx >= r.l and cx <= r.r and cy >= r.t and cy <= r.b then
                local zx, zy = (cx - r.l) / (r.r - r.l), (cy - r.t) / (r.b - r.t)
                for _, n in ipairs(z.nodes) do
                    if ns.InArea(n, zx, zy) then
                        found[z] = true
                        order[#order + 1] = z
                        break
                    end
                end
            end
        end
    end
    return order
end
ns.ZonesOnTheWay = ZonesOnTheWay

-- Route the next zone of the trip, skipping any finished meanwhile; the
-- target last, as picked (its whole route, or the one area).
AdvanceTrip = function()
    local trip = ns.trip
    if not trip then return end
    while #trip.legs > 0 do
        local zone = table.remove(trip.legs, 1)
        local last = #trip.legs == 0
        if last and trip.node then
            ns.trip = nil
            ns.RouteVia(zone, trip.node, true)
            return
        end
        if last then ns.trip = nil end
        if ns.StartRoute(zone, { quiet = true, leg = true }) then
            local d, t = ns.ZoneCounts(zone)
            ns.Print(string.format("%s %s: %d area%s left.", last and "Now" or "On the way,", zone.name,
                t - d, t - d == 1 and "" or "s"))
            return
        end
    end
    ns.trip = nil
end

-- A trip to `zone` (or the one area `node` of it), when there's a zone on
-- the way; false when there isn't, for an ordinary route.
StartTrip = function(zone, node)
    local way = ZonesOnTheWay(zone, node)
    if #way == 0 then return false end
    local legs, names = {}, {}
    for _, z in ipairs(way) do legs[#legs + 1] = z names[#names + 1] = z.name end
    legs[#legs + 1] = zone
    ns.trip = { target = zone, node = node, legs = legs }
    ns.Print(string.format("On the way to %s: %s, then %s.", node and node.name or zone.name,
        table.concat(names, ", "), zone.name))
    AdvanceTrip()
    return ns.route ~= nil
end
