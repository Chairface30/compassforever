-- Compass Forever: Pathing.lua
-- Walking around what can't be walked.
--
-- Data/Terrain.lua gives each zone a grid of points 8.3 yards apart and,
-- for every pair of neighbours, whether the step between them can be walked
-- (no steeper than 50 degrees up or 75 down, not lava; deep water is swum),
-- and which points are on a road. Two uses:
--
--   ns.WalkCost(zone, a, b): the walking cost between two standing points,
--   worked out ahead of time for every pair (the route planner's distances).
--
--   ns.Steer / ns.PathBetween: a path from where the player is to a stop
--   (or between two points), across zone lines, found in the game over the
--   waypoint graph of Data/Graph.lua (built from the same terrain ahead of
--   time), with walls, zone lines and roads drawn by hand laid over it. A
--   search looks at a few hundred waypoints, a couple of milliseconds a
--   frame at most; until it is done the arrow points straight.

local _, ns = ...

local PENALTY = 25
local ROAD = 0.7              -- a step along a road costs this share of one off it
local DRAWN_ROAD = 0.25       -- along a road drawn by hand: paths keep to it
local RUN_YARDS = 7           -- yards a second on foot: what a portal's or boat's time costs

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
-- The map-only nodes (after the rest) count only if the terrain's costs
-- were worked out with them; built before they were added, they have none.
local function Index(zone)
    if zone.pointIndex then return zone.pointIndex end
    local all = 0
    for _, node in ipairs(zone.nodes) do all = all + #node.points / 2 end
    local t = ns.TERRAIN and ns.TERRAIN[zone.ach]
    local built = t and t.dist and math.floor(math.sqrt(#t.dist / 3) + 0.5)
    local withMapOnly = built == all
    local n, index = 0, {}
    for _, node in ipairs(zone.nodes) do
        if withMapOnly or not node.mapOnly then
            index[node] = n
            n = n + #node.points / 2
        end
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


local ONE = string.byte("1")

-- Is grid point (i, j) on a road?
local function OnRoad(g, i, j)
    return g.roads ~= nil and g.roads:byte(j * g.nx + i + 1) == ONE
end
ns.OnRoad = OnRoad

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
-- Walls, roads and zone lines drawn by hand
-------------------------------------------------------------------------------

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

-------------------------------------------------------------------------------
-- The waypoint graph (Data/Graph.lua)
-------------------------------------------------------------------------------
-- Per continent, a few thousand waypoints (a lattice every 200 yards over
-- walkable ground, points along the terrain's roads, every area's standing
-- points, flight masters and docks) and the walking links between near ones,
-- with their costs and bends, worked out ahead of time from the terrain
-- (tools/build_graph.py). A path is an A* search over that: a few hundred
-- waypoints looked at, not the terrain's millions of points.
--
-- Laid over it in the game, so they can change without a rebuild:
--   walls     - a link one crosses is gone; so is a way on or off the graph;
--   zone lines - a link one crosses is gone for paths that stay in its zone;
--   roads     - drawn by hand: waypoints every few yards along each, linked
--               to each other cheaply (DRAWN_ROAD of their length) and to the
--               graph nearby, so paths keep to them.
-- Getting on and off the graph: from the start and to the end, straight
-- runs to the near waypoints that the terrain lets you walk.

local CELL = 32              -- grid points per side of a lookup square (267 yards)
local ATTACH = 30            -- grid points around a start or end for waypoints to reach
local ATTACH_KEEP = 6
local ROAD_STEP = 5          -- grid points between waypoints along a drawn road
local ROAD_ATTACH = 16       -- grid points from a road waypoint to the graph's
local DIRECT = 36            -- grid points: closer than this, a straight walk may do
local BUDGET = 2             -- milliseconds of searching per frame

local graphs, overlays = {}, {}

-- A continent grid point (whole or not) as its map's fractions, and back.
local function GridPos(cont, i, j)
    return (cont.maxY - (32 * TILE - i * NODE)) / cont.w, (cont.maxX - (32 * TILE - j * NODE)) / cont.h
end

local function Square(i, j)
    return math.floor(i / CELL) * 65536 + math.floor(j / CELL)
end

-- Can one step be walked on the continent's grid? true, false, or nil off
-- every map. Between two maps that don't overlap, taken as walkable.
local function StepOK(c, i, j, di, dj)
    local list = ContinentGrids(c)
    for _, g in ipairs(list) do
        if Covers(g, i, j) and Covers(g, i + di, j + dj) then
            return Can(g, i - g.gx, j - g.gy, di, dj)
        end
    end
    for _, g in ipairs(list) do
        if Covers(g, i, j) or Covers(g, i + di, j + dj) then return true end
    end
    return nil
end

-- Can the straight run between two grid points be walked, step by step?
local function StraightOK(c, ai, aj, bi, bj)
    local i, j = math.floor(ai + 0.5), math.floor(aj + 0.5)
    local ti, tj = math.floor(bi + 0.5), math.floor(bj + 0.5)
    local n = 0
    while (i ~= ti or j ~= tj) and n < 200 do
        n = n + 1
        local di = ti > i and 1 or ti < i and -1 or 0
        local dj = tj > j and 1 or tj < j and -1 or 0
        -- step along whichever axis keeps nearer the line
        if di ~= 0 and dj ~= 0 then
            local ex = math.abs((bj - aj) * (i + di - ai) - (bi - ai) * (j - aj))
            local ey = math.abs((bj - aj) * (i - ai) - (bi - ai) * (j + dj - aj))
            if ex <= ey then dj = 0 else di = 0 end
        end
        if not StepOK(c, i, j, di, dj) then return false end
        i, j = i + di, j + dj
    end
    return true
end

-- The graph of continent c, read the first time (`pause` is called now and
-- then, so a search reading it can wait for the next frame).
local function Graph(c, pause)
    local g = graphs[c]
    if g ~= nil then return g or nil end
    local d = ns.GRAPH and ns.GRAPH[c]
    local cont = ns.CONTINENT_YARDS and ns.CONTINENT_YARDS[c]
    if not (d and cont and cont.maxX) then
        graphs[c] = false
        return nil
    end
    g = { cont = cont, x = {}, y = {}, i = {}, j = {}, ea = {}, eb = {}, ec = {}, adj = {}, poly = {}, near = {} }
    local n = #d.n / 6
    for k = 1, n do
        local p = (k - 1) * 6
        local i, j = tonumber(d.n:sub(p + 1, p + 3), 36), tonumber(d.n:sub(p + 4, p + 6), 36)
        g.i[k], g.j[k] = i, j
        g.x[k], g.y[k] = GridPos(cont, i, j)
        g.adj[k] = {}
        local sq = Square(i, j)
        local list = g.near[sq]
        if not list then
            list = {}
            g.near[sq] = list
        end
        list[#list + 1] = k
        if pause and k % 2000 == 0 then pause() end
    end
    g.n = n
    local m = #d.e / 9
    for e = 1, m do
        local p = (e - 1) * 9
        local a = tonumber(d.e:sub(p + 1, p + 3), 36) + 1
        local b = tonumber(d.e:sub(p + 4, p + 6), 36) + 1
        g.ea[e], g.eb[e], g.ec[e] = a, b, tonumber(d.e:sub(p + 7, p + 9), 36)
        local la, lb = g.adj[a], g.adj[b]
        la[#la + 1], lb[#lb + 1] = e, e
        if pause and e % 3000 == 0 then pause() end
    end
    g.m = m
    for k, s in pairs(d.p or {}) do
        local pts = {}
        for q = 0, #s / 6 - 1 do
            local i, j = tonumber(s:sub(q * 6 + 1, q * 6 + 3), 36), tonumber(s:sub(q * 6 + 4, q * 6 + 6), 36)
            local x, y = GridPos(cont, i, j)
            pts[#pts + 1] = { x = x, y = y, i = i, j = j }
        end
        g.poly[k + 1] = pts
    end
    graphs[c] = g
    return g
end

-- A link's points from waypoint a to b (its bends between).
local function LinkPoints(g, e)
    local pts = { { i = g.i[g.ea[e]], j = g.j[g.ea[e]] } }
    for _, p in ipairs(g.poly[e] or {}) do pts[#pts + 1] = p end
    pts[#pts + 1] = { i = g.i[g.eb[e]], j = g.j[g.eb[e]] }
    return pts
end

-- The lines laid over the graph (walls, zone lines, roads), in grid units,
-- each kept in the lookup squares it passes through.
local function Lines(c, kind, cont)
    local out = { list = {}, at = {} }
    for _, zone in ipairs(ns.ZONES) do
        if zone.continent == c then
            local lines = kind == "walls" and ns.ZoneWalls(zone) or kind == "zonelines" and ns.ZoneLines(zone)
                or ns.ZoneRoads(zone)
            for _, wall in ipairs(lines) do
                local item
                if wall.circle then
                    local cx, cy = ns.ZoneToContinentPoint(zone, wall.circle[1], wall.circle[2])
                    if cx then
                        local gi, gj = GridUnits(cont, cx, cy)
                        item = { circle = true, gi, gj, wall.circle[3] / NODE, ach = zone.ach }
                    end
                else
                    item = { ach = zone.ach }
                    for k = 1, #wall - 1, 2 do
                        local cx, cy = ns.ZoneToContinentPoint(zone, wall[k], wall[k + 1])
                        if cx then
                            local gi, gj = GridUnits(cont, cx, cy)
                            item[#item + 1], item[#item + 2] = gi, gj
                        end
                    end
                    if #item < 4 then item = nil end
                end
                if item then
                    out.list[#out.list + 1] = item
                    -- the squares its box covers (a circle's too)
                    local i0, j0, i1, j1
                    if item.circle then
                        i0, j0, i1, j1 = item[1] - item[3], item[2] - item[3], item[1] + item[3], item[2] + item[3]
                    else
                        i0, j0, i1, j1 = item[1], item[2], item[1], item[2]
                        for k = 3, #item - 1, 2 do
                            i0, i1 = math.min(i0, item[k]), math.max(i1, item[k])
                            j0, j1 = math.min(j0, item[k + 1]), math.max(j1, item[k + 1])
                        end
                    end
                    for si = math.floor(i0 / CELL), math.floor(i1 / CELL) do
                        for sj = math.floor(j0 / CELL), math.floor(j1 / CELL) do
                            local key = si * 65536 + sj
                            out.at[key] = out.at[key] or {}
                            table.insert(out.at[key], item)
                        end
                    end
                end
            end
        end
    end
    return out
end

-- Does the run p-q (grid units) cross a line of `set` (only zone `ach`'s,
-- when given)?
local function Hits(set, pi, pj, qi, qj, ach)
    local seen = {}
    for si = math.floor(math.min(pi, qi) / CELL), math.floor(math.max(pi, qi) / CELL) do
        for sj = math.floor(math.min(pj, qj) / CELL), math.floor(math.max(pj, qj) / CELL) do
            for _, w in ipairs(set.at[si * 65536 + sj] or {}) do
                if not seen[w] and (not ach or w.ach == ach) then
                    seen[w] = true
                    if w.circle then
                        if Enters(pi, pj, qi, qj, w[1], w[2], w[3], w[3]) then return true end
                    else
                        for k = 1, #w - 3, 2 do
                            if Crosses(pi, pj, qi, qj, w[k], w[k + 1], w[k + 2], w[k + 3]) then return true end
                        end
                    end
                end
            end
        end
    end
    return false
end

-- Does a run of points (with i, j) cross a line of `set`?
local function RunHits(set, pts, ach)
    for k = 1, #pts - 1 do
        if Hits(set, pts[k].i, pts[k].j, pts[k + 1].i, pts[k + 1].j, ach) then return true end
    end
    return false
end

-- What's laid over continent c's graph: links walls cut, links zone lines
-- cut (by zone), and the drawn roads' waypoints and links. Worked out again
-- after any line changes.
local Attach                 -- (below) a point's way on and off the graph

local function Overlay(c, pause)
    local ov = overlays[c]
    if ov then return ov end
    local g = Graph(c, pause)
    if not g then return nil end
    local cont = g.cont
    ov = { walls = Lines(c, "walls", cont), zonelines = Lines(c, "zonelines", cont), cut = {}, local_ = {},
           x = {}, y = {}, i = {}, j = {}, links = {}, near = {}, n = g.n }
    local walls, zl = ov.walls, ov.zonelines
    local zlZones = {}
    for _, w in ipairs(zl.list) do zlZones[w.ach] = true end
    if #walls.list > 0 or #zl.list > 0 then
        for e = 1, g.m do
            local pts = LinkPoints(g, e)
            if #walls.list > 0 and RunHits(walls, pts) then
                ov.cut[e] = true
            elseif #zl.list > 0 then
                for ach in pairs(zlZones) do
                    if RunHits(zl, pts, ach) then
                        ov.local_[e] = ov.local_[e] or {}
                        ov.local_[e][ach] = true
                    end
                end
            end
            if pause and e % 1500 == 0 then pause() end
        end
    end
    -- drawn roads: their own waypoints, linked along and to the graph
    local roads = Lines(c, "roads", cont)
    local function Add(i, j)
        local k = ov.n + 1
        ov.n = k
        ov.i[k], ov.j[k] = i, j
        ov.x[k], ov.y[k] = GridPos(cont, i, j)
        ov.links[k] = ov.links[k] or {}
        local sq = Square(i, j)
        ov.near[sq] = ov.near[sq] or {}
        table.insert(ov.near[sq], k)
        return k
    end
    local function Link(a, b, cost)
        ov.links[a] = ov.links[a] or {}
        ov.links[b] = ov.links[b] or {}
        table.insert(ov.links[a], { b, cost })
        table.insert(ov.links[b], { a, cost })
    end
    local roadNodes = {}
    for _, r in ipairs(roads.list) do
        if not r.circle then
            local prev
            for k = 1, #r - 3, 2 do
                local ai, aj, bi, bj = r[k], r[k + 1], r[k + 2], r[k + 3]
                local len = math.sqrt((bi - ai) ^ 2 + (bj - aj) ^ 2)
                local steps = math.max(1, math.ceil(len / ROAD_STEP))
                for s = (k == 1) and 0 or 1, steps do
                    local node = Add(ai + (bi - ai) * s / steps, aj + (bj - aj) * s / steps)
                    roadNodes[#roadNodes + 1] = node
                    if prev then
                        local d = math.sqrt((ov.i[node] - ov.i[prev]) ^ 2 + (ov.j[node] - ov.j[prev]) ^ 2)
                        Link(prev, node, d * NODE * DRAWN_ROAD)
                    end
                    prev = node
                end
            end
        end
    end
    ov.drawnRoads = #roadNodes > 0
    -- each road waypoint to the graph's near it (and to other roads' near it)
    for _, k in ipairs(roadNodes) do
        local i, j = ov.i[k], ov.j[k]
        for si = math.floor((i - ROAD_ATTACH) / CELL), math.floor((i + ROAD_ATTACH) / CELL) do
            for sj = math.floor((j - ROAD_ATTACH) / CELL), math.floor((j + ROAD_ATTACH) / CELL) do
                for _, w in ipairs(g.near[si * 65536 + sj] or {}) do
                    local d = math.sqrt((g.i[w] - i) ^ 2 + (g.j[w] - j) ^ 2)
                    if d <= ROAD_ATTACH and not Hits(walls, i, j, g.i[w], g.j[w])
                        and StraightOK(c, i, j, g.i[w], g.j[w]) then
                        Link(k, w, d * NODE)
                    end
                end
            end
        end
        if pause then pause() end
    end
    -- portals and boats within the continent (Crossing.lua): a waypoint at
    -- each end, joined at the cost of the time they take, each end reached
    -- from the graph as a path's start or end would be
    ov.ride = {}
    for _, l in ipairs(ns.LINKS or {}) do
        local za, zb = ns.ZoneByMap(l.a.map), ns.ZoneByMap(l.b.map)
        if za and zb and za.continent == c and zb.continent == c then
            local ends = {}
            for e, zone in pairs({ a = za, b = zb }) do
                local cx, cy = ns.ZoneToContinentPoint(zone, l[e].x, l[e].y)
                if cx then
                    local i, j = GridUnits(cont, cx, cy)
                    local k = Add(i, j)
                    for _, it in ipairs(Attach(c, g, ov, i, j, nil)) do
                        if it[1] ~= k then Link(k, it[1], it[2]) end
                    end
                    ends[e] = k
                end
            end
            if ends.a and ends.b then
                Link(ends.a, ends.b, l.seconds * RUN_YARDS)
                ov.ride[ends.a], ov.ride[ends.b] = { link = l, at = "a" }, { link = l, at = "b" }
            end
        end
    end
    overlays[c] = ov
    return ov
end

local function PosOf(g, ov, k)
    if k <= g.n then return g.i[k], g.j[k] end
    return ov.i[k], ov.j[k]
end

-- Waypoints (graph's and roads') near grid point (i, j), with the cost of
-- walking straight there: those the terrain allows and no wall (nor, for a
-- path kept in its zone, a zone line) is in the way of. If none is, the
-- nearest few at a high cost, so a path is still found.
Attach = function(c, g, ov, i, j, ach)
    local found, any = {}, {}
    for si = math.floor((i - ATTACH) / CELL), math.floor((i + ATTACH) / CELL) do
        for sj = math.floor((j - ATTACH) / CELL), math.floor((j + ATTACH) / CELL) do
            local key = si * 65536 + sj
            for pass = 1, 2 do
                for _, k in ipairs((pass == 1 and g.near or ov.near)[key] or {}) do
                    local ki, kj = PosOf(g, ov, k)
                    local d = math.sqrt((ki - i) ^ 2 + (kj - j) ^ 2)
                    if d <= ATTACH then any[#any + 1] = { k, d } end
                end
            end
        end
    end
    table.sort(any, function(a, b) return a[2] < b[2] end)
    for _, it in ipairs(any) do
        local ki, kj = PosOf(g, ov, it[1])
        if not Hits(ov.walls, i, j, ki, kj) and not (ach and Hits(ov.zonelines, i, j, ki, kj, ach))
            and StraightOK(c, i, j, ki, kj) then
            found[#found + 1] = { it[1], it[2] * NODE }
            if #found >= ATTACH_KEEP then break end
        end
    end
    if #found == 0 then
        for q = 1, math.min(3, #any) do found[#found + 1] = { any[q][1], any[q][2] * NODE * UNKNOWN } end
    end
    return found
end

-- The walking path on continent c from (fx, fy) to (tx, ty), its map's
-- fractions, over the graph: { { x, y } ... } and its cost in yards, or nil.
-- `localZone`: the zone whose zone lines it keeps inside. Run in a
-- coroutine: `pause` lets it wait for the next frame.
local function GraphPath(c, fx, fy, tx, ty, localZone, pause)
    local g = Graph(c, pause)
    if not g then return nil end
    local ov = Overlay(c, pause)
    local cont = g.cont
    local ach = localZone and localZone.ach
    local si, sj = GridUnits(cont, fx, fy)
    local ti, tj = GridUnits(cont, tx, ty)
    local START, GOAL = -1, -2
    local direct = math.sqrt((ti - si) ^ 2 + (tj - sj) ^ 2)
    if direct <= DIRECT and not Hits(ov.walls, si, sj, ti, tj) and not (ach and Hits(ov.zonelines, si, sj, ti, tj, ach))
        and StraightOK(c, si, sj, ti, tj) then
        return { { x = fx, y = fy }, { x = tx, y = ty } }, direct * NODE
    end
    local starts = Attach(c, g, ov, si, sj, ach)
    local goals = {}
    for _, it in ipairs(Attach(c, g, ov, ti, tj, ach)) do goals[it[1]] = it[2] end
    if #starts == 0 or not next(goals) then return nil end
    -- the cheapest any yard of the way can be: along a drawn road
    local hf = ov.drawnRoads and DRAWN_ROAD or ROAD
    local function H(k)
        local ki, kj = PosOf(g, ov, k)
        return math.sqrt((ki - ti) ^ 2 + (kj - tj) ^ 2) * NODE * hf
    end
    local best, came, via = {}, {}, {}
    local open = Heap()
    for _, it in ipairs(starts) do
        local k, cost = it[1], it[2]
        if not best[k] or cost < best[k] then
            best[k], came[k], via[k] = cost, START, nil
            open:push(cost + H(k), k)
        end
    end
    local done, bestGoal, goalCost = {}, nil, nil
    local looked = 0
    while open.n > 0 do
        local f, u = open:pop()
        if goalCost and f >= goalCost then break end
        if not done[u] then
            done[u] = true
            looked = looked + 1
            if pause and looked % 40 == 0 then pause() end
            local base = best[u]
            local gc = goals[u]
            if gc and (not goalCost or base + gc < goalCost) then goalCost, bestGoal = base + gc, u end
            local function Try(v, cost, e)
                local nc = base + cost
                if not done[v] and (not best[v] or nc < best[v]) then
                    best[v], came[v], via[v] = nc, u, e
                    open:push(nc + H(v), v)
                end
            end
            if u <= g.n then
                for _, e in ipairs(g.adj[u]) do
                    if not ov.cut[e] and not (ach and ov.local_[e] and ov.local_[e][ach]) then
                        Try(g.ea[e] == u and g.eb[e] or g.ea[e], g.ec[e], e)
                    end
                end
            end
            for _, l in ipairs(ov.links[u] or {}) do Try(l[1], l[2], nil) end
        end
    end
    if not bestGoal then return nil end
    -- back from the end, each link's bends in the way it was walked
    local chain = {}
    local k = bestGoal
    while k ~= START do
        table.insert(chain, 1, k)
        k = came[k]
    end
    local path = { { x = fx, y = fy } }
    for q, node in ipairs(chain) do
        local e = via[node]
        if e and g.poly[e] then
            local bends = g.poly[e]
            if g.ea[e] == node then
                for b = #bends, 1, -1 do path[#path + 1] = { x = bends[b].x, y = bends[b].y } end
            else
                for b = 1, #bends do path[#path + 1] = { x = bends[b].x, y = bends[b].y } end
            end
        end
        -- from one end of a portal or boat to the other: the point before is
        -- where to take it
        local from, to = ov.ride[chain[q - 1] or 0], ov.ride[node]
        if from and to and from.link == to.link and from.at ~= to.at then
            path[#path].ride = { kind = to.link.kind, to = to.link[to.at].place }
        end
        local ni, nj = PosOf(g, ov, node)
        local x, y = GridPos(cont, ni, nj)
        path[#path + 1] = { x = x, y = y }
    end
    path[#path + 1] = { x = tx, y = ty }
    return path, goalCost
end

-------------------------------------------------------------------------------
-- Searches in the background: a little each frame
-------------------------------------------------------------------------------

local jobs = {}

local function Clock()
    local f = _G.debugprofilestop
    return type(f) == "function" and f() or nil
end

local driver = CreateFrame("Frame")
driver:Hide()
local frameStart
-- Called from inside a search: if this frame's time is used up, wait.
local function Pause()
    local now = Clock()
    if not now or (frameStart and now - frameStart > BUDGET) then coroutine.yield() end
end
driver:SetScript("OnUpdate", function(self)
    frameStart = Clock()
    while true do
        local job = jobs[1]
        if not job then
            self:Hide()
            return
        end
        local ok, path, cost = coroutine.resume(job.co)
        if not ok then
            table.remove(jobs, 1)
            if not ns.pathErrorShown then
                ns.Print("|cffff5555path:|r", path)
                ns.pathErrorShown = true
            end
        elseif coroutine.status(job.co) == "dead" then
            table.remove(jobs, 1)
            job.done(path, cost)
        else
            return         -- out of time for this frame
        end
        local now = Clock()
        if not now or now - frameStart > BUDGET then return end
    end
end)
ns.TimeUpdates(driver, "path search")

-- Queue a job: the arrow's paths first, then the drawn legs, then the
-- planner's costs and reading ahead.
local function Queue(job, prio)
    job.prio = prio
    local at = #jobs + 1
    for i, other in ipairs(jobs) do
        if other.prio > prio then
            at = i
            break
        end
    end
    table.insert(jobs, at, job)
    driver:Show()
end

-- Find a path in the background; `done(path, cost)` when found. A newer
-- request with the same `key` replaces one still waiting.
local function Request(c, fx, fy, tx, ty, localZone, key, done)
    for i = #jobs, 1, -1 do
        if jobs[i].key == key then table.remove(jobs, i) end
    end
    Queue({
        key = key, done = done,
        co = coroutine.create(function() return GraphPath(c, fx, fy, tx, ty, localZone, Pause) end),
    }, key:sub(1, 5) == "steer" and 1 or 2)
end

function ns.PathJobs() return #jobs end

-- For the tests and tools: a search run to the end at once, on the
-- continent's map.
function ns.FindContinentPathNow(c, fx, fy, tx, ty, localZone)
    return GraphPath(c, fx, fy, tx, ty, localZone, nil)
end

-- The same between two points of a zone's map, the path on its map too.
function ns.FindPathNow(zone, fx, fy, tx, ty)
    local ax, ay = ns.ZoneToContinentPoint(zone, fx, fy)
    local bx, by = ns.ZoneToContinentPoint(zone, tx, ty)
    if not (ax and bx) then return nil end
    local path, cost = GraphPath(zone.continent, ax, ay, bx, by, zone, nil)
    if not path then return nil end
    local r = ns.ZoneRectOnContinent(zone)
    local out = {}
    for k, p in ipairs(path) do
        out[k] = { x = (p.x - r.l) / (r.r - r.l), y = (p.y - r.t) / (r.b - r.t) }
    end
    return out, cost
end

-------------------------------------------------------------------------------
-- The route planner's costs: every standing point of a zone to every other
-------------------------------------------------------------------------------
-- Over the graph, walls, roads and the zone's zone lines included, so the
-- order of the stops agrees with the paths drawn between them. Worked out in
-- the background the first time a zone is planned (and again after a line
-- changes); until then the planner uses the terrain's own costs.

local planCosts = {}

local function PointKey(x, y) return string.format("%.4f,%.4f", x, y) end

-- Cheapest cost from `sources` ({ [waypoint] = cost }) to every waypoint,
-- until all of `targets` ({ [waypoint] = true }) are settled.
local function Distances(g, ov, sources, targets, ach, pause)
    local best, done = {}, {}
    local open = Heap()
    for k, cost in pairs(sources) do
        best[k] = cost
        open:push(cost, k)
    end
    local left = 0
    for _ in pairs(targets) do left = left + 1 end
    local looked = 0
    while open.n > 0 and left > 0 do
        local d, u = open:pop()
        if not done[u] then
            done[u] = true
            if targets[u] then left = left - 1 end
            looked = looked + 1
            if pause and looked % 40 == 0 then pause() end
            local function Try(v, cost)
                local nc = d + cost
                if not done[v] and (not best[v] or nc < best[v]) then
                    best[v] = nc
                    open:push(nc, v)
                end
            end
            if u <= g.n then
                for _, e in ipairs(g.adj[u]) do
                    if not ov.cut[e] and not (ach and ov.local_[e] and ov.local_[e][ach]) then
                        Try(g.ea[e] == u and g.eb[e] or g.ea[e], g.ec[e])
                    end
                end
            end
            for _, l in ipairs(ov.links[u] or {}) do Try(l[1], l[2]) end
        end
    end
    return best
end

local function ZoneCosts(zone, pause)
    local c = zone.continent
    local g = Graph(c, pause)
    if not g then return nil end
    local ov = Overlay(c, pause)
    local cont = g.cont
    local pts = {}
    for _, node in ipairs(zone.nodes) do
        for _, p in ipairs(ns.NodePoints(node)) do
            local cx, cy = ns.ZoneToContinentPoint(zone, p[1], p[2])
            if cx then
                local i, j = GridUnits(cont, cx, cy)
                local links = {}
                for _, it in ipairs(Attach(c, g, ov, i, j, zone.ach)) do links[it[1]] = it[2] end
                pts[#pts + 1] = { key = PointKey(p[1], p[2]), links = links }
            end
        end
        if pause then pause() end
    end
    local cost = {}
    for _, a in ipairs(pts) do
        local targets = {}
        for _, b in ipairs(pts) do for k in pairs(b.links) do targets[k] = true end end
        local dist = Distances(g, ov, a.links, targets, zone.ach, pause)
        local row = {}
        for _, b in ipairs(pts) do
            local m
            for k, extra in pairs(b.links) do
                local d = dist[k]
                if d and (not m or d + extra < m) then m = d + extra end
            end
            if m then row[b.key] = m end
        end
        row[a.key] = 0
        cost[a.key] = row
    end
    return cost
end

-- The planner's cost between two points of a zone (its map's fractions),
-- or nil until worked out (it starts being worked out now).
function ns.PlanCost(zone, ax, ay, bx, by)
    local pc = planCosts[zone.ach]
    if not pc then
        pc = {}
        planCosts[zone.ach] = pc
        Queue({ key = "plan" .. zone.ach,
            co = coroutine.create(function() return ZoneCosts(zone, Pause) end),
            done = function(cost)
                if planCosts[zone.ach] ~= pc then return end
                pc.cost = cost or {}
                -- a route under way in this zone is planned again with them
                local r = ns.route
                if r and r.zone == zone and not r.single then
                    ns.StartRoute(zone, { quiet = true, skipped = r.skipped, auto = r.auto })
                end
            end }, 3)
        return nil
    end
    local row = pc.cost and pc.cost[PointKey(ax, ay)]
    return row and row[PointKey(bx, by)] or nil
end

-- For the tests: a zone's costs worked out at once.
function ns.PlanCostsNow(zone)
    local pc = { cost = ZoneCosts(zone, nil) or {} }
    planCosts[zone.ach] = pc
end

-- After a line changes: what's laid over the graphs is worked out again,
-- and every path is looked for again.
function ns.WallsChanged()
    overlays = {}
    jobs = {}
    planCosts = {}
    if ns.ForgetPaths then ns.ForgetPaths() end
    ns.Fire("path")
end

-- The graph and its overlay, read ahead (in the background) so the first
-- path doesn't wait for them.

function ns.WarmGraph(c)
    if graphs[c] ~= nil and overlays[c] then return end
    for _, job in ipairs(jobs) do if job.key == "warm" .. c then return end end
    Queue({ key = "warm" .. c, done = function() end,
        co = coroutine.create(function() Overlay(c, Pause) end) }, 3)
end

-------------------------------------------------------------------------------
-- Steering: where the arrow points while walking to a stop
-------------------------------------------------------------------------------
-- The path to the current stop is asked for once, when the stop changes, and
-- again if the player wanders well off it. The arrow aims a little way ahead
-- along the path, so it bends around a cliff instead of pointing through it.

local AHEAD = 40             -- yards along the path to aim at
local RIDE_NEAR = 40         -- this close to a portal or boat, the arrow says to take it
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
-- One path kept per target (the arrow, the minimap button and the drawn
-- lines can each aim somewhere else: a flight master, a dock, the stop), so
-- they never throw away each other's; targets unused for a while are let go.
local KEEP = 20              -- seconds a target unused is kept

function ns.Steer(c, stop, px, py, localZone)
    local cont = ns.CONTINENT_YARDS and ns.CONTINENT_YARDS[c]
    if not (cont and cont.maxX) then return nil end
    local key = string.format("%d:%.5f:%.5f:%d", c, stop.x, stop.y, localZone and localZone.ach or 0)
    local now = Now()
    local e = steer[key]
    if not e then
        e = {}
        steer[key] = e
        for k, other in pairs(steer) do
            if now - (other.used or now) > KEEP then steer[k] = nil end
        end
    end
    e.used = now
    steer.last = e
    local function Ask()
        e.asked = now
        Request(c, px, py, stop.x, stop.y, localZone, "steer:" .. key, function(path)
            if steer[key] == e then
                e.path = path
                ns.Fire("path")
            end
        end)
    end
    if not e.asked then Ask() end
    local path = e.path
    if not path or #path < 2 then return nil end
    local k, cx, cy, off = Project(path, cont, px, py)
    if off > OFF_PATH and now - e.asked > ASK_AGAIN then Ask() end
    -- From the projection, AHEAD yards along.
    local left, aimX, aimY = AHEAD, path[#path].x, path[#path].y
    local here = { x = cx, y = cy }
    local remaining = off
    local found = false
    -- a portal or boat to take, here or a few steps on (on it, or at it)
    e.ride = path[k].ride
    for i = k + 1, #path do
        local d = Seg(cont, here, path[i])
        remaining = remaining + d
        if path[i].ride and remaining <= RIDE_NEAR and not e.ride then e.ride = path[i].ride end
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

-- The portal or boat the arrow's path takes next, when it's close:
-- { kind, to }, or nil.
function ns.SteerRide()
    local e = steer.last
    return e and e.path and e.ride or nil
end

-- What /cf probe says about the arrow's path.
function ns.SteerStatus()
    local e = steer.last or {}
    return nil, e.path and #e.path or nil, e.asked, #jobs
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
    steer = {}
end

function ns.PathBetween(c, ax, ay, bx, by, localZone)
    local key = string.format("%d:%.5f:%.5f:%.5f:%.5f:%d", c, ax, ay, bx, by, localZone and localZone.ach or 0)
    local p = between[key]
    if p == nil then
        between[key] = false
        Request(c, ax, ay, bx, by, localZone, "between:" .. key, function(path)
            between[key] = path or "none"
            ns.Fire("path")
        end)
        return nil
    end
    return type(p) == "table" and p or nil
end

-- At login, the graph of the continent you're on is read in the background.
ns.On("login", function()
    local c = ns.PlayerContinent and ns.PlayerContinent()
    if c then ns.WarmGraph(c) end
end)
