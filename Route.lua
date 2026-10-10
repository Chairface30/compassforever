-- Chair Legacy: Route.lua
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

-- A node's standing points as fractions.
local function Points(node)
    local out = {}
    local p = node.points
    for i = 1, #p, 2 do out[#out + 1] = { p[i] / SCALE, p[i + 1] / SCALE } end
    return out
end
ns.NodePoints = Points

-- Plan a route through `nodes` on `zone`, starting at (sx, sy) or, with no
-- start, wherever makes the walk shortest. Returns { { node, x, y } ... } and
-- its length in yards.
function ns.PlanRoute(zone, nodes, sx, sy)
    local w, h = zone.w, zone.h
    local function D(ax, ay, bx, by)
        local dx, dy = (ax - bx) * w, (ay - by) * h
        return math.sqrt(dx * dx + dy * dy)
    end
    local n = #nodes
    if n == 0 then return {}, 0 end
    local pts = {}
    for i, node in ipairs(nodes) do pts[i] = Points(node) end

    -- 1. Nearest first, from the start (or from each node in turn when there
    -- is no start, keeping the shortest).
    local function Greedy(fromX, fromY, firstNode)
        local used, order, pick = {}, {}, {}
        local cx, cy = fromX, fromY
        if firstNode then
            used[firstNode] = true
            order[1], pick[1] = firstNode, 1
            cx, cy = pts[firstNode][1][1], pts[firstNode][1][2]
        end
        while #order < n do
            local best, bestK, bestD
            for i = 1, n do
                if not used[i] then
                    for k, p in ipairs(pts[i]) do
                        local d = D(cx, cy, p[1], p[2])
                        if not bestD or d < bestD then best, bestK, bestD = i, k, d end
                    end
                end
            end
            used[best] = true
            order[#order + 1], pick[#pick + 1] = best, bestK
            cx, cy = pts[best][bestK][1], pts[best][bestK][2]
        end
        return order, pick
    end

    local function P(order, pick, i)
        local p = pts[order[i]][pick[i]]
        return p[1], p[2]
    end

    local function Length(order, pick)
        local total, cx, cy = 0, sx, sy
        for i = 1, #order do
            local x, y = P(order, pick, i)
            if cx then total = total + D(cx, cy, x, y) end
            cx, cy = x, y
        end
        return total
    end

    -- 2. Improve until no move helps. Each move is costed by the few legs it
    -- changes, not by re-measuring the walk, so a 27-area zone still plans
    -- in a blink. Position 0 is the start, when there is one.
    local function Improve(order, pick)
        local m = #order
        local function Pos(i)
            if i == 0 then return sx, sy end
            if i < 1 or i > m then return nil end
            return P(order, pick, i)
        end
        local function E(i, j)
            local ax, ay = Pos(i)
            local bx, by = Pos(j)
            if not (ax and bx) then return 0 end
            return D(ax, ay, bx, by)
        end

        local function Reselect()
            for i = 1, m do
                local px, py = Pos(i - 1)
                local nx, ny = Pos(i + 1)
                local bestK, bestC = pick[i], nil
                for k, p in ipairs(pts[order[i]]) do
                    local c = (px and D(px, py, p[1], p[2]) or 0) + (nx and D(p[1], p[2], nx, ny) or 0)
                    if not bestC or c < bestC - 0.01 then bestK, bestC = k, c end
                end
                pick[i] = bestK
            end
        end

        -- One improving move, applied; false when there is none.
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
                                        for a = 1, m do
                                            if a < i or a > e then o2[#o2 + 1], k2[#k2 + 1] = order[a], pick[a] end
                                            if a == j then
                                                for b = 1, len do o2[#o2 + 1], k2[#k2 + 1] = segO[b], segK[b] end
                                            end
                                        end
                                        if j == 0 then
                                            for b = len, 1, -1 do
                                                table.insert(o2, 1, segO[b])
                                                table.insert(k2, 1, segK[b])
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
            Reselect()
            if not Step() then break end
        end
        Reselect()
        return order, pick, Length(order, pick)
    end

    -- 3. Few enough areas to be sure: the exact shortest walk through the
    -- chosen points (Held-Karp), then each stop's point chosen again for its
    -- new neighbours, until that changes nothing.
    local EXACT = 11
    local function Exact(order, pick)
        local m = #order
        for _ = 1, 4 do
            local px, py = {}, {}
            for i = 1, m do px[i], py[i] = P(order, pick, i) end
            local full = 2 ^ m - 1
            local dp, from = {}, {}
            local bit = {}
            for i = 1, m do bit[i] = 2 ^ (i - 1) end
            for i = 1, m do
                dp[bit[i]] = dp[bit[i]] or {}
                from[bit[i]] = from[bit[i]] or {}
                dp[bit[i]][i] = sx and D(sx, sy, px[i], py[i]) or 0
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
                                    local nc = c + D(px[j], py[j], px[k], py[k])
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
            -- Re-choose points; stop once none moves.
            local moved = false
            for i = 1, m do
                local ax, ay
                if i > 1 then ax, ay = P(order, pick, i - 1) else ax, ay = sx, sy end
                local bx, by
                if i < m then bx, by = P(order, pick, i + 1) end
                local bestK, bestC = pick[i], nil
                for k, p in ipairs(pts[order[i]]) do
                    local c = (ax and D(ax, ay, p[1], p[2]) or 0) + (bx and D(p[1], p[2], bx, by) or 0)
                    if not bestC or c < bestC - 0.01 then bestK, bestC = k, c end
                end
                if bestK ~= pick[i] then pick[i], moved = bestK, true end
            end
            if not moved then break end
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
    if sx then
        Try(Greedy(sx, sy))
        if n > EXACT then
            local near = {}
            for i = 1, n do
                local d
                for _, p in ipairs(pts[i]) do
                    local dd = D(sx, sy, p[1], p[2])
                    if not d or dd < d then d = dd end
                end
                near[i] = { i = i, d = d }
            end
            table.sort(near, function(a, b) return a.d < b.d end)
            for r = 2, math.min(n, 5) do Try(Greedy(sx, sy, near[r].i)) end
        end
    elseif n <= EXACT then
        Try(Greedy(nil, nil, 1))
    else
        for first = 1, n do Try(Greedy(nil, nil, first)) end
    end

    local stops = {}
    for i, idx in ipairs(bestOrder) do
        local p = pts[idx][bestPick[i]]
        stops[i] = { node = nodes[idx], x = p[1], y = p[2] }
    end
    return stops, bestLen
end

-------------------------------------------------------------------------------
-- The active route
-------------------------------------------------------------------------------

-- (Re)plan the route through `zone` from where the player is now. Stops the
-- player skipped (by overlay ID) stay at the end, in the order skipped.
function ns.StartRoute(zone, quiet, skipped)
    skipped = skipped or {}
    local remaining = ns.ZoneRemaining(zone)
    if #remaining == 0 then
        ns.route = nil
        if not quiet then ns.Print(zone.name .. ": every area is already uncovered.") end
        ns.Fire("route")
        return
    end
    local now, later = {}, {}
    for _, node in ipairs(remaining) do
        if skipped[node.overlay] then later[#later + 1] = node else now[#now + 1] = node end
    end
    table.sort(later, function(a, b) return skipped[a.overlay] < skipped[b.overlay] end)
    local sx, sy = ns.PlayerOn(zone.map)
    local stops, yards = ns.PlanRoute(zone, now, sx, sy)
    for _, node in ipairs(later) do
        local p = ns.NodePoints(node)[1]
        stops[#stops + 1] = { node = node, x = p[1], y = p[2] }
    end
    ns.route = { zone = zone, stops = stops, yards = yards, skipped = skipped }
    if not quiet then
        ns.Print(string.format("%s: %d area%s left, about %d yards on foot.", zone.name,
            #stops, #stops == 1 and "" or "s", math.floor(yards + 0.5)))
    end
    ns.Fire("route")
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
    ns.Print("Skipped " .. stop.node.name .. "; it is now the last stop.")
    ns.Fire("route")
end

-- After any progress: replan from here, so a stop uncovered by walking
-- through it on the way somewhere else drops out and the rest re-orders.
ns.On("progress", function()
    local r = ns.route
    if not r then return end
    local before = #r.stops
    ns.StartRoute(r.zone, true, r.skipped)
    if not ns.route then
        ns.Print("|cff55ff55" .. r.zone.name .. " is fully explored.|r")
    elseif #ns.route.stops < before then
        local stop = ns.CurrentStop()
        if stop then ns.Print("Next: " .. stop.node.name .. ".") end
    end
end)
