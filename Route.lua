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

-- A node's standing points as fractions: one moved by hand (Spots.lua), or
-- the ones picked from the terrain.
local function Points(node)
    local moved = ns.MovedSpot and ns.MovedSpot(node)
    if moved then return { { moved[1], moved[2] } } end
    local out = {}
    local p = node.points
    for i = 1, #p, 2 do out[#out + 1] = { p[i] / SCALE, p[i + 1] / SCALE } end
    return out
end
ns.NodePoints = Points

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
            -- a moved spot has no walking costs worked out: straight lines
            local moved = ns.MovedSpot and ns.MovedSpot(node)
            pts[i][k] = { x = p[1], y = p[2], id = not moved and ns.PointID and ns.PointID(zone, node, k) or nil }
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
-- explored, joins the route as a stop when it costs at most this much more
-- walking: learning it now saves a trip later.
local FLIGHT_DETOUR = 800

function ns.StartRoute(zone, opts)
    opts = opts or {}
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

    local sx, sy = ns.PlayerOn(zone.map)
    local function Plan(list)
        if not first then return ns.PlanRoute(zone, list, sx, sy) end
        -- The chosen spot first: its point nearest the player, then the rest
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
    local stops, yards = Plan(now)
    if #extra > 0 then
        local with = {}
        for _, node in ipairs(now) do with[#with + 1] = node end
        for _, node in ipairs(extra) do with[#with + 1] = node end
        local s2, y2 = Plan(with)
        if y2 - yards <= FLIGHT_DETOUR * #extra then stops, yards = s2, y2 end
    end
    for _, node in ipairs(later) do
        local p = ns.NodePoints(node)[1]
        stops[#stops + 1] = { node = node, x = p[1], y = p[2] }
    end
    ns.route = { zone = zone, stops = stops, yards = yards, skipped = skipped, auto = opts.auto or false }
    if not opts.quiet then
        ns.Print(string.format("%s: %d area%s left, about %s on foot.", zone.name,
            #remaining, #remaining == 1 and "" or "s", ns.Yards(yards)))
    end
    ns.Fire("route")
    return ns.route
end

-- Head for `node` next, keeping the rest of the route (or starting one).
function ns.RouteVia(zone, node)
    local r = ns.route
    local opts = { first = node }
    if r and r.zone == zone then opts.skipped, opts.auto = r.skipped, r.auto end
    opts.skipped = opts.skipped or {}
    opts.skipped[node.overlay] = nil
    ns.StartRoute(zone, opts)
end

function ns.StopRoute()
    ns.route = nil
    ns.Fire("route")
end

function ns.CurrentStop()
    local r = ns.route
    if not r or not r.stops[1] then return nil end
    return r.stops[1], 1
end

-- Leave the current stop for later (a spot that will not take, or one the
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
end)
