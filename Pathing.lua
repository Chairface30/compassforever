-- Compass Forever: Pathing.lua
-- Walking around what can't be walked.
--
-- Data/Terrain.lua gives each zone a grid of points 8.3 yards apart and,
-- for every pair of neighbours, whether the step between them can be walked
-- (no steeper than 50 degrees up or 75 down, not lava; deep water is swum).
-- Two uses:
--
--   ns.WalkCost(zone, a, b): the walking cost between two standing points,
--   worked out ahead of time for every pair (the route planner's distances).
--
--   ns.RequestPath(...): a path from where the player is to a stop, found in
--   the game with A* over the grid. The search runs a slice each frame, so a
--   long one never stalls the game; until it is done the arrow points
--   straight.
--
-- A step that breaks a rule costs PENALTY times its length instead of being
-- forbidden: bridges and buildings aren't terrain, so a gorge with a bridge
-- over it looks like a cliff, and must stay crossable when nothing else is.

local _, ns = ...

local PENALTY = 25
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
    g = { x0 = t.x0, y0 = t.y0, cw = t.cw, ch = t.ch, nx = t.nx, ny = t.ny, yd = t.yd, cells = cells }
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

-- The cost of one step from (i, j), or nil off the grid.
local function StepCost(g, i, j, di, dj)
    if di == 0 or dj == 0 then
        local ok = Can(g, i, j, di, dj)
        if ok == nil then return nil end
        return ok and g.yd or g.yd * PENALTY
    end
    local ti, tj = i + di, j + dj
    if ti < 0 or tj < 0 or ti >= g.nx or tj >= g.ny then return nil end
    local way1 = Can(g, i, j, di, 0) and Can(g, i + di, j, 0, dj)
    local way2 = Can(g, i, j, 0, dj) and Can(g, i, j + dj, di, 0)
    return g.yd * SQRT2 * ((way1 or way2) and 1 or PENALTY)
end

-- A coroutine that finds the path and yields every SLICE squares. Returns
-- the path as map points (grid points, straight runs merged), from
-- (fx, fy) to (tx, ty), and its cost.
local function Search(g, fx, fy, tx, ty)
    local si, sj = ns.Square(g, fx, fy)
    local ti, tj = ns.Square(g, tx, ty)
    local nx = g.nx
    local start, goal = sj * nx + si, tj * nx + ti
    local best, came = { [start] = 0 }, {}
    local open = Heap()
    local function H(i, j)
        local di, dj = i - ti, j - tj
        return g.yd * math.sqrt(di * di + dj * dj)
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
            local i, j = cur % nx, math.floor(cur / nx)
            local base = best[cur]
            for _, s in ipairs(STEPS) do
                local cost = StepCost(g, i, j, s[1], s[2])
                if cost then
                    local nxt = (j + s[2]) * nx + (i + s[1])
                    local c = base + cost
                    if not done[nxt] and (best[nxt] == nil or c < best[nxt]) then
                        best[nxt] = c
                        came[nxt] = cur
                        open:push(c + H(i + s[1], j + s[2]), nxt)
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
        local di, dj = (b % nx) - (a % nx), math.floor(b / nx) - math.floor(a / nx)
        if di ~= lastDi or dj ~= lastDj then
            local x, y = Middle(g, a % nx, math.floor(a / nx))
            path[#path + 1] = { x = x, y = y }
            lastDi, lastDj = di, dj
        end
    end
    path[#path + 1] = { x = tx, y = ty }
    return path, best[goal]
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

-- Find a walking path on `zone` from (fx, fy) to (tx, ty); `done(path, cost)`
-- is called when found (path nil if the zone has no grid). A newer request
-- with the same `key` replaces one still running.
function ns.RequestPath(zone, fx, fy, tx, ty, key, done)
    local g = ns.Grid(zone)
    if not g then
        done(nil)
        return
    end
    for i = #jobs, 1, -1 do
        if jobs[i].key == key then table.remove(jobs, i) end
    end
    jobs[#jobs + 1] = {
        key = key,
        co = coroutine.create(function() return Search(g, fx, fy, tx, ty) end),
        done = done,
    }
    driver:Show()
end

-- For the tests: the search run to the end at once.
function ns.FindPathNow(zone, fx, fy, tx, ty)
    local g = ns.Grid(zone)
    if not g then return nil end
    local co = coroutine.create(function() return Search(g, fx, fy, tx, ty) end)
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

-- Where to aim, as map fractions, and the yards left along the path; nil
-- while there is no path yet (the arrow then points straight at the stop).
function ns.Steer(zone, stop, px, py)
    if not (zone.ach and ns.TERRAIN and ns.TERRAIN[zone.ach]) then return nil end
    local key = zone.ach .. ":" .. stop.x .. ":" .. stop.y
    local now = Now()
    if steer.key ~= key then
        steer.key, steer.path, steer.asked = key, nil, nil
    end
    local function Ask()
        steer.asked = now
        ns.RequestPath(zone, px, py, stop.x, stop.y, "steer", function(path)
            if steer.key == key then
                steer.path = path
                ns.Fire("path")
            end
        end)
    end
    if not steer.asked then Ask() end
    local path = steer.path
    if not path or #path < 2 then return nil end
    local k, cx, cy, off = Project(path, zone, px, py)
    if off > OFF_PATH and now - steer.asked > ASK_AGAIN then Ask() end
    -- From the projection, AHEAD yards along.
    local left, aimX, aimY = AHEAD, path[#path].x, path[#path].y
    local here = { x = cx, y = cy }
    local remaining = off
    local found = false
    for i = k + 1, #path do
        local d = Seg(zone, here, path[i])
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

-- The current walking path, for drawing: its points and where the player is
-- on it. nil until one is found.
function ns.SteerPath()
    return steer.path
end
