-- Compass Forever: Pathing.lua
-- Walking around what can't be walked.
--
-- Data/Terrain.lua gives each zone a grid of points 8.3 yards apart and,
-- for every pair of neighbours, whether the step between them can be walked
-- (no steeper than 50 degrees up or 75 down, not lava; deep water is swum),
-- and which points are on a road: steps along roads cost less, so routes
-- take a road when it's not much longer.
-- Two uses:
--
--   ns.WalkCost(zone, a, b): the walking cost between two standing points,
--   worked out ahead of time for every pair (the route planner's distances).
--
--   ns.Steer / ns.PathBetween: a path from where the player is to a stop
--   (or between two points), found in the game with A* over the whole
--   continent. Every zone's grid is cut from one grid of points per
--   continent, so they line up at the borders and are stitched together:
--   a path runs from wherever the player is, across zone lines, to the
--   stop. The search runs a slice each frame, so a long one never stalls
--   the game; until it is done the arrow points straight.
--
-- A step that breaks a rule costs PENALTY times its length instead of being
-- forbidden: bridges and buildings aren't terrain, so a gorge with a bridge
-- over it looks like a cliff, and must stay crossable when nothing else is.

local _, ns = ...

local PENALTY = 25
local ROAD = 0.7              -- a step along a road costs this share of one off it
local DRAWN_ROAD = 0.25       -- a step along a road drawn by hand: paths keep to it
local SLICE = 1500            -- points looked at per frame (about 3 ms)

local HEX = {}
for i = 0, 15 do HEX[string.byte(string.format("%x", i))] = i end

-------------------------------------------------------------------------------
-- The grid
-------------------------------------------------------------------------------

local grids = {}

-- A zone's grid, decoded the first time it is asked for.
function ns.Grid(zone)
    local g = grids[zone.ach]
    if g ~= nil then return g or nil end
    local t = ns.TERRAIN and ns.TERRAIN[zone.ach]
    if not t then
        grids[zone.ach] = false
        return nil
    end
    local cells = t.cells:gsub("%%(%x)(%d+)%.", function(c, n) return c:rep(tonumber(n)) end)
    local roads = t.roads and t.roads:gsub("%%(%d)(%d+)%.", function(c, n) return c:rep(tonumber(n)) end) or nil
    g = { x0 = t.x0, y0 = t.y0, cw = t.cw, ch = t.ch, nx = t.nx, ny = t.ny, yd = t.yd, cells = cells,
          roads = roads, gx = t.gx, gy = t.gy }
    grids[zone.ach] = g
    return g
end

local function Bits(g, i, j)
    return HEX[g.cells:byte(j * g.nx + i + 1)] or 0
end

local function Has(v, bit) return v % (bit * 2) >= bit end

-- Can you walk one orthogonal step from square (i, j)? nil off the grid.
local function Can(g, i, j, di, dj)
    local ti, tj = i + di, j + dj
    if ti < 0 or tj < 0 or ti >= g.nx or tj >= g.ny then return nil end
    if di == 1 then return Has(Bits(g, i, j), 1) end
    if di == -1 then return Has(Bits(g, ti, j), 2) end
    if dj == 1 then return Has(Bits(g, i, j), 4) end
    return Has(Bits(g, i, tj), 8)
end
ns.CanStep = Can

-- The grid point nearest a map point, kept on the grid.
function ns.Square(g, x, y)
    local i = math.floor((x - g.x0) / g.cw + 0.5)
    local j = math.floor((y - g.y0) / g.ch + 0.5)
    return math.max(0, math.min(g.nx - 1, i)), math.max(0, math.min(g.ny - 1, j))
end

-- A grid point, as map fractions.
local function Middle(g, i, j)
    return g.x0 + i * g.cw, g.y0 + j * g.ch
end

-------------------------------------------------------------------------------
-- Walking cost between standing points (worked out ahead of time)
-------------------------------------------------------------------------------

local matrices = {}

-- Each node's first point's number among the zone's points, in data order.
local function Index(zone)
    if zone.pointIndex then return zone.pointIndex end
    local n, index = 0, {}
    for _, node in ipairs(zone.nodes) do
        index[node] = n
        n = n + #node.points / 2
    end
    zone.pointIndex, zone.pointCount = index, n
    return index
end

-- Point k (1-based) of `node`: its number among the zone's points.
function ns.PointID(zone, node, k)
    local base = Index(zone)[node]
    return base and (base + k) or nil
end

-- Walking cost in yards from point a to point b (their numbers), or nil.
function ns.WalkCost(zone, a, b)
    local t = ns.TERRAIN and ns.TERRAIN[zone.ach]
    if not (t and t.dist and a and b) then return nil end
    Index(zone)
    local n = zone.pointCount
    local m = matrices[zone.ach]
    if not m then
        m = {}
        matrices[zone.ach] = m
    end
    local key = (a - 1) * n + b
    local v = m[key]
    if v == nil then
        local pos = (key - 1) * 3 + 1
        v = tonumber(t.dist:sub(pos, pos + 2), 36) or false
        m[key] = v
    end
    return v or nil
end

-------------------------------------------------------------------------------
-- A path, in the game (A* a slice per frame)
-------------------------------------------------------------------------------

local function Heap()
    local h = { n = 0, keys = {}, vals = {} }
    function h:push(key, val)
        local n = self.n + 1
        self.n = n
        local keys, vals = self.keys, self.vals
        keys[n], vals[n] = key, val
        while n > 1 do
            local p = math.floor(n / 2)
            if keys[p] <= keys[n] then break end
            keys[p], keys[n] = keys[n], keys[p]
            vals[p], vals[n] = vals[n], vals[p]
            n = p
        end
    end
    function h:pop()
        local keys, vals = self.keys, self.vals
        local topK, topV = keys[1], vals[1]
        local n = self.n
        keys[1], vals[1] = keys[n], vals[n]
        keys[n], vals[n] = nil, nil
        n = n - 1
        self.n = n
        local i = 1
        while true do
            local l, r, s = i * 2, i * 2 + 1, i
            if l <= n and keys[l] < keys[s] then s = l end
            if r <= n and keys[r] < keys[s] then s = r end
            if s == i then break end
            keys[s], keys[i] = keys[i], keys[s]
            vals[s], vals[i] = vals[i], vals[s]
            i = s
        end
        return topK, topV
    end
    return h
end

local STEPS = {
    { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
    { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 },
}
local SQRT2 = math.sqrt(2)

local ONE = string.byte("1")

-- Is grid point (i, j) on a road?
local function OnRoad(g, i, j)
    return g.roads ~= nil and g.roads:byte(j * g.nx + i + 1) == ONE
end
ns.OnRoad = OnRoad

-- Thin a path to the few waypoints that matter: any point within TRACK
-- yards of the straight line between its neighbours goes
-- (Ramer-Douglas-Peucker). The path still bends round what it must, but is
-- drawn and followed as a handful of straight runs. A run that would cut
-- through a wall (crosses(a, b)) keeps its corner however close.
local TRACK = 20

local function Simplify(path, xs, ys, crosses)
    if #path < 3 then return path end
    local keep = { [1] = true, [#path] = true }
    local function Dist(p, a, b)
        local ax, ay = a.x * xs, a.y * ys
        local dx, dy = b.x * xs - ax, b.y * ys - ay
        local px, py = p.x * xs - ax, p.y * ys - ay
        local len2 = dx * dx + dy * dy
        if len2 == 0 then return math.sqrt(px * px + py * py) end
        local t = math.max(0, math.min(1, (px * dx + py * dy) / len2))
        local cx, cy = px - t * dx, py - t * dy
        return math.sqrt(cx * cx + cy * cy)
    end
    local stack = { { 1, #path } }
    while #stack > 0 do
        local span = table.remove(stack)
        local i, j = span[1], span[2]
        local far, at = 0, nil
        for k = i + 1, j - 1 do
            local d = Dist(path[k], path[i], path[j])
            if d > far then far, at = d, k end
        end
        if at and (far > TRACK or (crosses and crosses(path[i], path[j]))) then
            keep[at] = true
            stack[#stack + 1] = { i, at }
            stack[#stack + 1] = { at, j }
        end
    end
    local out = {}
    for k = 1, #path do
        if keep[k] then out[#out + 1] = path[k] end
    end
    return out
end

-- A coroutine that finds the path and yields every SLICE points. A space
-- says how to step: Node(x, y) and Pos(i, j) between map points and grid
-- points, Can(i, j, di, dj) for one orthogonal step (nil off the grid),
-- Road(i, j), yd (yards between points), xs, ys (yards per map fraction),
-- hasRoads. Returns the path as map points (thinned to its turning points),
-- from (fx, fy) to (tx, ty), and its cost.
local function Search(sp, fx, fy, tx, ty)
    local si, sj = sp:Node(fx, fy)
    local ti, tj = sp:Node(tx, ty)
    local W = 65536
    local start, goal = sj * W + si, tj * W + ti
    local best, came = { [start] = 0 }, {}
    local open = Heap()
    local yd = sp.yd
    -- With roads drawn by hand any step may cost as little as one along them,
    -- so the estimate of what's left has to assume that much.
    local hf = sp.DrawnRoad and DRAWN_ROAD or sp.hasRoads and 0.85 or 1
    local function H(i, j)
        local di, dj = i - ti, j - tj
        -- A little over the cheapest the rest could cost (all road): the
        -- search runs 1.6 times faster for paths at most 0.7 per cent
        -- longer than the very best (measured over 115 legs).
        return yd * math.sqrt(di * di + dj * dj) * hf
    end
    local function Step(i, j, di, dj)
        local cost
        if di == 0 or dj == 0 then
            local ok = sp:Can(i, j, di, dj)
            if ok == nil then return nil end
            cost = (ok == true and 1 or ok == false and PENALTY or ok) * yd
        else
            -- Either way round: across then along, or along then across.
            local a1, a2 = sp:Can(i, j, di, 0), nil
            local b1, b2 = sp:Can(i, j, 0, dj), nil
            if a1 == nil and b1 == nil then return nil end
            if a1 ~= nil then a2 = sp:Can(i + di, j, 0, dj) end
            if b1 ~= nil then b2 = sp:Can(i, j + dj, di, 0) end
            if a2 == nil and b2 == nil then return nil end
            local way1 = a1 == true and a2 == true
            local way2 = b1 == true and b2 == true
            cost = yd * SQRT2 * ((way1 or way2) and 1 or PENALTY)
        end
        -- along a drawn road: cheap, whatever the terrain says (it's a way
        -- through); along a terrain road: cheaper
        if sp.DrawnRoad and sp:DrawnRoad(i, j) and sp:DrawnRoad(i + di, j + dj) then
            return yd * ((di == 0 or dj == 0) and 1 or SQRT2) * DRAWN_ROAD
        end
        if sp.hasRoads and sp:Road(i, j) and sp:Road(i + di, j + dj) then cost = cost * ROAD end
        return cost
    end
    open:push(H(si, sj), start)
    local done, seen = {}, 0
    while open.n > 0 do
        local _, cur = open:pop()
        if cur == goal then break end
        if not done[cur] then
            done[cur] = true
            seen = seen + 1
            if seen % SLICE == 0 then coroutine.yield() end
            local i, j = cur % W, math.floor(cur / W)
            local base = best[cur]
            for _, st in ipairs(STEPS) do
                local cost = Step(i, j, st[1], st[2])
                if cost then
                    local nxt = (j + st[2]) * W + (i + st[1])
                    local c = base + cost
                    if not done[nxt] and (best[nxt] == nil or c < best[nxt]) then
                        best[nxt] = c
                        came[nxt] = cur
                        open:push(c + H(i + st[1], j + st[2]), nxt)
                    end
                end
            end
        end
    end
    if best[goal] == nil then return nil end
    -- Walk back, then keep only the points where the direction turns.
    local chain = {}
    local cur = goal
    while cur do
        table.insert(chain, 1, cur)
        cur = came[cur]
    end
    local path = { { x = fx, y = fy } }
    local lastDi, lastDj
    for k = 2, #chain - 1 do
        local a, b = chain[k], chain[k + 1]
        local di, dj = (b % W) - (a % W), math.floor(b / W) - math.floor(a / W)
        if di ~= lastDi or dj ~= lastDj then
            local x, y = sp:Pos(a % W, math.floor(a / W))
            path[#path + 1] = { x = x, y = y }
            lastDi, lastDj = di, dj
        end
    end
    path[#path + 1] = { x = tx, y = ty }
    return Simplify(path, sp.xs, sp.ys, sp.Crosses), best[goal]
end

-- One zone's grid as a space (its map's fractions).
local function ZoneSpace(g)
    return {
        yd = g.yd, xs = g.yd / g.cw, ys = g.yd / g.ch, hasRoads = g.roads ~= nil,
        Node = function(_, x, y) return ns.Square(g, x, y) end,
        Pos = function(_, i, j) return Middle(g, i, j) end,
        Can = function(_, i, j, di, dj) return Can(g, i, j, di, dj) end,
        Road = function(_, i, j) return OnRoad(g, i, j) end,
    }
end

-------------------------------------------------------------------------------
-- The continent: every zone's grid stitched together
-------------------------------------------------------------------------------
-- Point (i, j) of the continent's grid is point (i - g.gx, j - g.gy) of any
-- zone grid g that covers it. A step is read from a grid that covers both
-- its ends; where none does (the seam of two maps that don't overlap) it
-- counts as hard going (UNKNOWN times its length), and off every map it
-- can't be taken.

local TILE = 1600 / 3
local NODE = TILE / 64
local UNKNOWN = 5
local continents = {}

local function ContinentGrids(c)
    local list = continents[c]
    if list then return list end
    list = {}
    for _, zone in ipairs(ns.ZONES) do
        if zone.continent == c then
            local g = ns.Grid(zone)
            if g and g.gx then list[#list + 1] = g end
        end
    end
    continents[c] = list
    return list
end

local function Covers(g, i, j)
    local li, lj = i - g.gx, j - g.gy
    return li >= 0 and lj >= 0 and li < g.nx and lj < g.ny
end

-------------------------------------------------------------------------------
-- Walls
-------------------------------------------------------------------------------
-- Lines drawn on a zone's map (in the window's wall mode, or shipped in
-- Data/Walls.lua) where the terrain says you can walk but you can't: no
-- path crosses one. Paths use both the shipped walls and the player's own
-- (CompassForeverDB.walls); only the player's own are drawn and edited.
-- Each is a flat list of that zone's map fractions, x1, y1, x2, y2, ... or a circle,
-- { circle = { x, y, yards } }, that no path enters.
--
-- They are kept per continent as the steps of its grid they cut: "i:j:x"
-- for the step from (i, j) to (i + 1, j), "i:j:y" for (i, j) to (i, j + 1).

local wallSteps, wallLines = {}, {}
local zoneLineSteps = {}      -- per zone: its zone lines' { cut, segs }
local roadPoints = {}

-- Roads drawn by hand on a zone's map (the window's road mode, or shipped
-- in Data/Roads.lua): paths keep to them until they have to leave for
-- where they're going. Same form as walls: lists of map fractions.
-- A zone's lines of one kind for the paths: the shipped ones (never drawn)
-- and the player's own (drawn, and the ones edited).
local function Both(shipped, mine)
    if not (shipped and #shipped > 0) then return mine or {} end
    if not (mine and #mine > 0) then return shipped end
    local all = {}
    for _, l in ipairs(shipped) do all[#all + 1] = l end
    for _, l in ipairs(mine) do all[#all + 1] = l end
    return all
end

-- The player's own walls or roads in a zone (CompassForeverDB), or nil.
function ns.OwnLines(zone, kind)
    local t = ns.db and ns.db[kind]
    return t and t[zone.ach] or nil
end

function ns.ZoneRoads(zone)
    return Both(ns.ROADS and ns.ROADS[zone.ach], ns.OwnLines(zone, "roads"))
end

function ns.ZoneWalls(zone)
    return Both(ns.WALLS and ns.WALLS[zone.ach], ns.OwnLines(zone, "walls"))
end

function ns.ZoneLines(zone)
    return Both(ns.ZONELINES and ns.ZONELINES[zone.ach], ns.OwnLines(zone, "zonelines"))
end

-- The zone whose zone lines a path from the player to a point of `zone`
-- keeps to: that zone while the player is in it, else none.
function ns.LocalZone(zone)
    if zone and ns.CurrentZone and ns.CurrentZone() == zone then return zone end
    return nil
end

-- Forget the cut steps and every path found, after a wall changes.
function ns.WallsChanged()
    wallSteps, wallLines, roadPoints = {}, {}, {}
    zoneLineSteps = {}
    if ns.ForgetPaths then ns.ForgetPaths() end
    ns.Fire("path")
end

-- Does segment p-q cross segment a-b (any one set of units)?
local function Crosses(px, py, qx, qy, ax, ay, bx, by)
    local function Side(ox, oy, dx, dy, x, y) return dx * (y - oy) - dy * (x - ox) end
    local d1 = Side(ax, ay, bx - ax, by - ay, px, py)
    local d2 = Side(ax, ay, bx - ax, by - ay, qx, qy)
    local d3 = Side(px, py, qx - px, qy - py, ax, ay)
    local d4 = Side(px, py, qx - px, qy - py, bx, by)
    return (d1 > 0) ~= (d2 > 0) and (d3 > 0) ~= (d4 > 0)
end

-- Continent map fractions as continent grid units (not rounded).
local function GridUnits(cont, x, y)
    local wy = cont.maxY - x * cont.w
    local wx = cont.maxX - y * cont.h
    return (32 * TILE - wy) / NODE, (32 * TILE - wx) / NODE
end

-- One wall's steps cut (into `cut`) and its lines on the continent map
-- (into `segs`).
local function AddWall(cont, zone, wall, cut, segs)
    local circle = wall.circle
    if circle then
        -- every step to or from a point inside is cut
        local cx, cy = ns.ZoneToContinentPoint(zone, circle[1], circle[2])
        if cx then
            local gi, gj = GridUnits(cont, cx, cy)
            local rg = circle[3] / NODE
            for i = math.floor(gi - rg), math.ceil(gi + rg) do
                for j = math.floor(gj - rg), math.ceil(gj + rg) do
                    if (i - gi) ^ 2 + (j - gj) ^ 2 <= rg * rg then
                        cut[i .. ":" .. j .. ":x"] = true
                        cut[(i - 1) .. ":" .. j .. ":x"] = true
                        cut[i .. ":" .. j .. ":y"] = true
                        cut[i .. ":" .. (j - 1) .. ":y"] = true
                    end
                end
            end
            segs[#segs + 1] = { circle = true, cx, cy, circle[3] / cont.w, circle[3] / cont.h }
        end
    else
        local pts = {}
        local fr = {}
        for k = 1, #wall - 1, 2 do
            local cx, cy = ns.ZoneToContinentPoint(zone, wall[k], wall[k + 1])
            if cx then
                local gi, gj = GridUnits(cont, cx, cy)
                pts[#pts + 1], pts[#pts + 2] = gi, gj
                fr[#fr + 1], fr[#fr + 2] = cx, cy
            end
        end
        for k = 1, #fr - 3, 2 do
            segs[#segs + 1] = { fr[k], fr[k + 1], fr[k + 2], fr[k + 3] }
        end
        for k = 1, #pts - 3, 2 do
            local ax, ay, bx, by = pts[k], pts[k + 1], pts[k + 2], pts[k + 3]
            -- every step near the line, tested against it
            local len = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
            local n = math.max(1, math.ceil(len * 2))
            for s = 0, n do
                local x, y = ax + (bx - ax) * s / n, ay + (by - ay) * s / n
                for i = math.floor(x) - 1, math.floor(x) + 1 do
                    for j = math.floor(y) - 1, math.floor(y) + 1 do
                        if Crosses(i, j, i + 1, j, ax, ay, bx, by) then cut[i .. ":" .. j .. ":x"] = true end
                        if Crosses(i, j, i, j + 1, ax, ay, bx, by) then cut[i .. ":" .. j .. ":y"] = true end
                    end
                end
            end
        end
    end
end

local function WallSteps(c)
    local cut = wallSteps[c]
    if cut then return cut end
    cut = {}
    wallSteps[c] = cut
    local segs = {}
    wallLines[c] = segs
    local cont = ns.CONTINENT_YARDS and ns.CONTINENT_YARDS[c]
    if not (cont and cont.maxX and ns.ZoneToContinentPoint) then return cut end
    for _, zone in ipairs(ns.ZONES) do
        if zone.continent == c then
            for _, wall in ipairs(ns.ZoneWalls(zone)) do AddWall(cont, zone, wall, cut, segs) end
        end
    end
    return cut
end

-- A zone's zone lines: walls only for paths that stay in the zone (stop to
-- stop, or from you while you're in it); a path from another zone crosses
-- them. { cut, segs } as WallSteps, per zone.
local function ZoneLineSteps(zone)
    local z = zoneLineSteps[zone.ach]
    if z then return z end
    z = { cut = {}, segs = {} }
    zoneLineSteps[zone.ach] = z
    local cont = ns.CONTINENT_YARDS and ns.CONTINENT_YARDS[zone.continent]
    if cont and cont.maxX and ns.ZoneToContinentPoint then
        for _, line in ipairs(ns.ZoneLines(zone)) do AddWall(cont, zone, line, z.cut, z.segs) end
    end
    return z
end

-- The continent grid points under the drawn roads ("i:j"), a few yards
-- either side so a path can stay on.
local function RoadPoints(c)
    local on = roadPoints[c]
    if on then return on end
    on = {}
    roadPoints[c] = on
    local cont = ns.CONTINENT_YARDS and ns.CONTINENT_YARDS[c]
    if not (cont and cont.maxX and ns.ZoneToContinentPoint) then return on end
    for _, zone in ipairs(ns.ZONES) do
        if zone.continent == c then
            for _, road in ipairs(ns.ZoneRoads(zone)) do
                local pts = {}
                for k = 1, #road - 1, 2 do
                    local cx, cy = ns.ZoneToContinentPoint(zone, road[k], road[k + 1])
                    if cx then
                        local gi, gj = GridUnits(cont, cx, cy)
                        pts[#pts + 1], pts[#pts + 2] = gi, gj
                    end
                end
                for k = 1, #pts - 3, 2 do
                    local ax, ay, bx, by = pts[k], pts[k + 1], pts[k + 2], pts[k + 3]
                    local n = math.max(1, math.ceil(math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2) * 2))
                    for s = 0, n do
                        local i = math.floor(ax + (bx - ax) * s / n + 0.5)
                        local j = math.floor(ay + (by - ay) * s / n + 0.5)
                        on[i .. ":" .. j] = true
                        on[(i + 1) .. ":" .. j] = true
                        on[(i - 1) .. ":" .. j] = true
                        on[i .. ":" .. (j + 1)] = true
                        on[i .. ":" .. (j - 1)] = true
                    end
                end
            end
        end
    end
    return on
end

-- Is the orthogonal step from continent point (i, j) cut by a wall?
local function Walled(cut, i, j, di, dj)
    if di == 1 then return cut[i .. ":" .. j .. ":x"] end
    if di == -1 then return cut[(i - 1) .. ":" .. j .. ":x"] end
    if dj == 1 then return cut[i .. ":" .. j .. ":y"] end
    return cut[i .. ":" .. (j - 1) .. ":y"]
end

-- Does a straight run a-b (points with x, y) cross any of `segs`?
-- Does segment a-b pass through the ellipse at (cx, cy) with radii rx, ry
-- (a circle in yards, in map fractions)?
local function Enters(ax, ay, bx, by, cx, cy, rx, ry)
    ax, ay, bx, by = (ax - cx) / rx, (ay - cy) / ry, (bx - cx) / rx, (by - cy) / ry
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    local t = len2 > 0 and math.max(0, math.min(1, -(ax * dx + ay * dy) / len2)) or 0
    local px, py = ax + t * dx, ay + t * dy
    return px * px + py * py < 1
end

local function CrossesAny(segs, a, b)
    for _, w in ipairs(segs) do
        if w.circle then
            if Enters(a.x, a.y, b.x, b.y, w[1], w[2], w[3], w[4]) then return true end
        elseif Crosses(a.x, a.y, b.x, b.y, w[1], w[2], w[3], w[4]) then
            return true
        end
    end
    return false
end

-- One zone's grid as a space, its continent's walls in the way.
local function WalledZoneSpace(zone, g)
    local sp = ZoneSpace(g)
    local own = {}
    local all = {}
    for _, wall in ipairs(ns.ZoneWalls(zone)) do all[#all + 1] = wall end
    for _, wall in ipairs(ns.ZoneLines(zone)) do all[#all + 1] = wall end
    for _, wall in ipairs(all) do
        local c = wall.circle
        if c then
            own[#own + 1] = { circle = true, c[1], c[2], c[3] / zone.w, c[3] / zone.h }
        else
            for k = 1, #wall - 3, 2 do own[#own + 1] = { wall[k], wall[k + 1], wall[k + 2], wall[k + 3] } end
        end
    end
    if #own > 0 then sp.Crosses = function(a, b) return CrossesAny(own, a, b) end end
    if not g.gx then return sp end
    local road = RoadPoints(zone.continent)
    if next(road) then
        sp.DrawnRoad = function(_, i, j) return road[(i + g.gx) .. ":" .. (j + g.gy)] end
    end
    local cut = WallSteps(zone.continent)
    local zcut = ZoneLineSteps(zone).cut
    local can = sp.Can
    sp.Can = function(self, i, j, di, dj)
        if Walled(cut, i + g.gx, j + g.gy, di, dj) or Walled(zcut, i + g.gx, j + g.gy, di, dj) then return nil end
        return can(self, i, j, di, dj)
    end
    return sp
end

function ns.ContinentSpace(c, localZone)
    local cont = ns.CONTINENT_YARDS and ns.CONTINENT_YARDS[c]
    if not (cont and cont.maxX) then return nil end
    local grids = ContinentGrids(c)
    if #grids == 0 then return nil end
    local last = grids[1]
    local function Find(i, j, i2, j2)
        if Covers(last, i, j) and Covers(last, i2, j2) then return last end
        for _, g in ipairs(grids) do
            if Covers(g, i, j) and Covers(g, i2, j2) then
                last = g
                return g
            end
        end
        return nil
    end
    local function Any(i, j)
        if Covers(last, i, j) then return last end
        for _, g in ipairs(grids) do
            if Covers(g, i, j) then return g end
        end
        return nil
    end
    local hasRoads = false
    for _, g in ipairs(grids) do if g.roads then hasRoads = true end end
    local cut = WallSteps(c)
    local segs = wallLines[c] or {}
    local zcut
    if localZone then
        local z = ZoneLineSteps(localZone)
        if next(z.cut) then zcut = z.cut end
        if #z.segs > 0 then
            local both = {}
            for _, w in ipairs(segs) do both[#both + 1] = w end
            for _, w in ipairs(z.segs) do both[#both + 1] = w end
            segs = both
        end
    end
    local road = RoadPoints(c)
    return {
        yd = NODE, xs = cont.w, ys = cont.h, hasRoads = hasRoads, cont = cont,
        Crosses = #segs > 0 and function(a, b) return CrossesAny(segs, a, b) end or nil,
        DrawnRoad = next(road) and function(_, i, j) return road[i .. ":" .. j] end or nil,
        -- Continent map fractions <-> continent grid points, through world
        -- yards (x east = -world Y, y south = -world X).
        Node = function(_, x, y)
            local wy = cont.maxY - x * cont.w
            local wx = cont.maxX - y * cont.h
            return math.floor((32 * TILE - wy) / NODE + 0.5), math.floor((32 * TILE - wx) / NODE + 0.5)
        end,
        Pos = function(_, i, j)
            local wy = 32 * TILE - i * NODE
            local wx = 32 * TILE - j * NODE
            return (cont.maxY - wy) / cont.w, (cont.maxX - wx) / cont.h
        end,
        Can = function(_, i, j, di, dj)
            if Walled(cut, i, j, di, dj) then return nil end
            if zcut and Walled(zcut, i, j, di, dj) then return nil end
            local g = Find(i, j, i + di, j + dj)
            if g then return Can(g, i - g.gx, j - g.gy, di, dj) end
            if Any(i, j) or Any(i + di, j + dj) then return UNKNOWN end
            return nil
        end,
        Road = function(_, i, j)
            local g = Any(i, j)
            return g ~= nil and OnRoad(g, i - g.gx, j - g.gy)
        end,
    }
end

-- Where a zone's map sits on its continent's map, from the grids: left,
-- right, top, bottom as fractions. nil without terrain.
function ns.ZoneRectOnContinent(zone)
    local g = ns.Grid(zone)
    local cont = ns.CONTINENT_YARDS and ns.CONTINENT_YARDS[zone.continent]
    if not (g and g.gx and cont and cont.maxX) then return nil end
    local function X(fx)
        local wy = 32 * TILE - (g.gx + (fx - g.x0) / g.cw) * NODE
        return (cont.maxY - wy) / cont.w
    end
    local function Y(fy)
        local wx = 32 * TILE - (g.gy + (fy - g.y0) / g.ch) * NODE
        return (cont.maxX - wx) / cont.h
    end
    return { l = X(0), r = X(1), t = Y(0), b = Y(1) }
end

-- Searches still running, worked on a slice per frame.
local jobs = {}
local driver = CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnUpdate", function(self)
    local job = jobs[1]
    if not job then
        self:Hide()
        return
    end
    local ok, path, cost = coroutine.resume(job.co)
    if not ok then
        table.remove(jobs, 1)
        if not ns.pathErrorShown then
            ns.pathErrorShown = true
            ns.Print("|cffff5555path:|r", path)
        end
        return
    end
    if coroutine.status(job.co) == "dead" then
        table.remove(jobs, 1)
        job.done(path, cost)
    end
end)

-- Find a walking path in `space` from (fx, fy) to (tx, ty); `done(path,
-- cost)` is called when found. A newer request with the same `key` replaces
-- one still running.
local function Request(space, fx, fy, tx, ty, key, done)
    for i = #jobs, 1, -1 do
        if jobs[i].key == key then table.remove(jobs, i) end
    end
    local job = {
        key = key,
        co = coroutine.create(function() return Search(space, fx, fy, tx, ty) end),
        done = done,
    }
    -- The arrow's path goes first: the drawn legs between later stops can
    -- wait.
    if key == "steer" then table.insert(jobs, 1, job) else jobs[#jobs + 1] = job end
    driver:Show()
end

function ns.RequestPath(zone, fx, fy, tx, ty, key, done)
    local g = ns.Grid(zone)
    if not g then
        done(nil)
        return
    end
    Request(WalledZoneSpace(zone, g), fx, fy, tx, ty, key, done)
end

function ns.PathJobs() return #jobs end

-- For the tests: a continent search run to the end at once.
function ns.FindContinentPathNow(c, fx, fy, tx, ty, localZone)
    local sp = ns.ContinentSpace(c, localZone)
    if not sp then return nil end
    local co = coroutine.create(function() return Search(sp, fx, fy, tx, ty) end)
    while true do
        local ok, path, cost = coroutine.resume(co)
        if not ok then error(path) end
        if coroutine.status(co) == "dead" then return path, cost end
    end
end

-- For the tests: the search run to the end at once.
function ns.FindPathNow(zone, fx, fy, tx, ty)
    local g = ns.Grid(zone)
    if not g then return nil end
    local sp = WalledZoneSpace(zone, g)
    local co = coroutine.create(function() return Search(sp, fx, fy, tx, ty) end)
    while true do
        local ok, path, cost = coroutine.resume(co)
        if not ok then error(path) end
        if coroutine.status(co) == "dead" then return path, cost end
    end
end

-------------------------------------------------------------------------------
-- Steering: where the arrow points while walking to a stop
-------------------------------------------------------------------------------
-- The path to the current stop is asked for once, when the stop changes, and
-- again if the player wanders well off it. The arrow aims a little way ahead
-- along the path, so it bends around a cliff instead of pointing through it.

local AHEAD = 40             -- yards along the path to aim at
local OFF_PATH = 60          -- this far from the path asks for a new one
local ASK_AGAIN = 3          -- seconds between asks

local steer = {}

local function Now()
    local ok, t = pcall(GetTime)
    return ok and t or 0
end

-- The player's spot projected on the path: segment, point and how far off.
local function Project(path, zone, px, py)
    local best, bk, bx, by
    for k = 1, #path - 1 do
        local a, b = path[k], path[k + 1]
        local ax, ay = a.x * zone.w, a.y * zone.h
        local dx, dy = b.x * zone.w - ax, b.y * zone.h - ay
        local qx, qy = px * zone.w - ax, py * zone.h - ay
        local len2 = dx * dx + dy * dy
        local t = len2 > 0 and math.max(0, math.min(1, (qx * dx + qy * dy) / len2)) or 0
        local cx, cy = ax + t * dx, ay + t * dy
        local d = math.sqrt((px * zone.w - cx) ^ 2 + (py * zone.h - cy) ^ 2)
        if not best or d < best then best, bk, bx, by = d, k, cx / zone.w, cy / zone.h end
    end
    return bk, bx, by, best
end

local function Seg(zone, a, b)
    return math.sqrt(((a.x - b.x) * zone.w) ^ 2 + ((a.y - b.y) * zone.h) ^ 2)
end

-- Where to aim, as fractions of the continent's map, and the yards left
-- along the path; nil while there is no path yet (the arrow then points
-- straight). `c` is the continent (0 or 1); `stop`, px and py are on its
-- map.
function ns.Steer(c, stop, px, py, localZone)
    local sp = ns.ContinentSpace(c, localZone)
    if not sp then return nil end
    local cont = sp.cont
    local key = string.format("%d:%.5f:%.5f:%d", c, stop.x, stop.y, localZone and localZone.ach or 0)
    local now = Now()
    if steer.key ~= key then
        steer.key, steer.path, steer.asked = key, nil, nil
    end
    local function Ask()
        steer.asked = now
        Request(sp, px, py, stop.x, stop.y, "steer", function(path)
            if steer.key == key then
                steer.path = path
                steer.found = now
                ns.Fire("path")
            end
        end)
    end
    if not steer.asked then Ask() end
    local path = steer.path
    if not path or #path < 2 then return nil end
    local k, cx, cy, off = Project(path, cont, px, py)
    if off > OFF_PATH and now - steer.asked > ASK_AGAIN then Ask() end
    -- From the projection, AHEAD yards along.
    local left, aimX, aimY = AHEAD, path[#path].x, path[#path].y
    local here = { x = cx, y = cy }
    local remaining = off
    local found = false
    for i = k + 1, #path do
        local d = Seg(cont, here, path[i])
        remaining = remaining + d
        if not found then
            if d >= left then
                local t = left / d
                aimX, aimY = here.x + (path[i].x - here.x) * t, here.y + (path[i].y - here.y) * t
                found = true
            else
                left = left - d
            end
        end
        here = path[i]
    end
    return aimX, aimY, remaining, path, k, cx, cy
end

-- What /cf probe says about the arrow's path.
function ns.SteerStatus()
    return steer.key, steer.path and #steer.path or nil, steer.asked, #jobs
end

-------------------------------------------------------------------------------
-- Paths between two fixed points (a landing and a stop, two stops)
-------------------------------------------------------------------------------
-- On the continent's map. Found once, in the background, and kept; nil
-- until found (draw it straight until then). "path" fires when one arrives.

local between = {}

-- After a wall changes: every path is looked for again.
function ns.ForgetPaths()
    between = {}
    steer.key, steer.path, steer.asked = nil, nil, nil
end

function ns.PathBetween(c, ax, ay, bx, by, localZone)
    local sp = ns.ContinentSpace(c, localZone)
    if not sp then return nil end
    local key = string.format("%d:%.5f:%.5f:%.5f:%.5f:%d", c, ax, ay, bx, by, localZone and localZone.ach or 0)
    local p = between[key]
    if p == nil then
        between[key] = false
        Request(sp, ax, ay, bx, by, "between:" .. key, function(path)
            between[key] = path or "none"
            ns.Fire("path")
        end)
        return nil
    end
    return type(p) == "table" and p or nil
end
