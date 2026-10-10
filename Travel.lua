-- Compass Forever: Travel.lua
-- Flying there when that is quicker than walking.
--
-- Which flight points a character knows can only be read while a flight map
-- is open, so every time one opens the known ones are remembered for that
-- character (CompassForeverDB.taxi). Until a flight map has been opened once
-- nothing is known, and routes stay on foot.
--
-- When the next stop is far, the quickest way there is worked out: walking
-- straight there, or walking to a known flight point, flying (through other
-- known points if need be) and walking from where you land. Flying wins only
-- if it saves a real amount of time. Then the arrow points at the flight
-- master first, and after landing the route carries on from there.
--
-- All distances here are on the continent's map (Data/Flights.lua puts every
-- flight point there), walking ones as the crow flies with an allowance for
-- the way not being straight.

local _, ns = ...

local WINDING = 1.3          -- walking is this much longer than a straight line
local TAKEOFF = 25           -- seconds to talk, mount up and land
local SAVE_SECONDS = 45      -- flying must save at least this
local SAVE_SHARE = 0.75      -- and take at most this share of the walk
local RUN = 7                -- yards a second on foot

ns.travel = nil              -- { from = node, to = node, fromID, toID, seconds, walk }

-------------------------------------------------------------------------------
-- Known flight points
-------------------------------------------------------------------------------

local function CharKey()
    local ok, name = ns.Ask(_G.UnitName, "player")
    local okR, realm = ns.Ask(_G.GetRealmName)
    return (ok and name or "?") .. "-" .. (okR and realm or "?")
end

local function Known()
    local db = ns.db
    db.taxi = db.taxi or {}
    local key = CharKey()
    db.taxi[key] = db.taxi[key] or {}
    return db.taxi[key]
end
ns.KnownFlights = Known

local nameIndex
local function ByName(name)
    if not nameIndex then
        nameIndex = {}
        for id, node in pairs(ns.FLIGHT_NODES or {}) do
            nameIndex[node.name:lower()] = id
            local short = node.name:match("^([^,]+)")
            if short and not nameIndex[short:lower()] then nameIndex[short:lower()] = id end
        end
    end
    name = name and name:lower()
    if not name then return nil end
    return nameIndex[name] or nameIndex[name:match("^([^,]+)") or ""]
end

-- Read the open flight map: every point the character can fly to, or is at.
local function ReadTaxiMap()
    local known, seen = Known(), 0
    local getAll = ns.API("C_TaxiMap", "GetAllTaxiNodes")
    local mapFn = ns.API(nil, "GetTaxiMapID")
    if getAll then
        local okM, mapID = ns.Ask(mapFn)
        local ok, nodes = ns.Ask(getAll, okM and mapID or nil)
        local states = _G.Enum and _G.Enum.FlightPathState or {}
        if ok and type(nodes) == "table" then
            for _, info in ipairs(nodes) do
                local id = ns.Num(info.nodeID)
                if not (id and ns.FLIGHT_NODES[id]) then id = ByName(ns.Text(info.name)) end
                local state = info.state
                local unknown = states.Unreachable ~= nil and state == states.Unreachable
                if id and not unknown then
                    known[id] = true
                    seen = seen + 1
                end
            end
        end
    end
    local count = ns.API(nil, "NumTaxiNodes")
    local nameOf, kindOf = ns.API(nil, "TaxiNodeName"), ns.API(nil, "TaxiNodeGetType")
    local okC, n = ns.Ask(count)
    if okC and ns.Num(n) and nameOf then
        for i = 1, n do
            local okN, name = ns.Ask(nameOf, i)
            local okK, kind = ns.Ask(kindOf, i)
            local id = okN and ByName(ns.Text(name))
            if id and (not okK or kind == "CURRENT" or kind == "REACHABLE") then
                known[id] = true
                seen = seen + 1
            end
        end
    end
    return seen
end
ns.ReadTaxiMap = ReadTaxiMap

local function Side()
    local ok, faction = ns.Ask(_G.UnitFactionGroup, "player")
    if faction == "Alliance" then return 1 end
    if faction == "Horde" then return 2 end
    return 3
end

-------------------------------------------------------------------------------
-- Where things are on the continent
-------------------------------------------------------------------------------

local function ContinentOf(zone) return ns.CONTINENT_YARDS and ns.CONTINENT_YARDS[zone.continent] end

-- A point of a zone, as fractions of its continent's map.
local function OnContinent(zone, x, y)
    local c = ContinentOf(zone)
    if not c then return nil end
    return ns.Translate(zone.map, x, y, c.map)
end

local function Yards(c, ax, ay, bx, by)
    local dx, dy = (ax - bx) * c.w, (ay - by) * c.h
    return math.sqrt(dx * dx + dy * dy)
end

local function RunSpeed()
    local ok, _, run = ns.Ask(_G.GetUnitSpeed, "player")
    run = ok and ns.Num(run)
    if run and run >= RUN then return run end
    return RUN
end

-------------------------------------------------------------------------------
-- The quickest way to a stop
-------------------------------------------------------------------------------

-- Seconds of flying between every two known points (through others known),
-- from each starting point's walk.
local function Flights(continent, side, startCost)
    local known = Known()
    local edges = {}
    for _, p in ipairs(ns.FLIGHT_PATHS or {}) do
        local a, b, len = p[1], p[2], p[3]
        local na, nb = ns.FLIGHT_NODES[a], ns.FLIGHT_NODES[b]
        if na and nb and known[a] and known[b] and na.continent == continent and nb.continent == continent
            and na.side % (side * 2) >= side and nb.side % (side * 2) >= side then
            edges[a] = edges[a] or {}
            table.insert(edges[a], { b, len / ns.FLIGHT_SPEED })
        end
    end
    -- Dijkstra from every start at once (each begins at its walking time).
    local best, prev, done = {}, {}, {}
    for id, cost in pairs(startCost) do best[id], prev[id] = cost, nil end
    while true do
        local cur, cc
        for id, c in pairs(best) do
            if not done[id] and (not cc or c < cc) then cur, cc = id, c end
        end
        if not cur then break end
        done[cur] = true
        for _, e in ipairs(edges[cur] or {}) do
            local c = cc + e[2]
            if not best[e[1]] or c < best[e[1]] then best[e[1]], prev[e[1]] = c, cur end
        end
    end
    return best, prev
end

-- Plan the way to `stop` on `zone`; sets ns.travel to a flight or nil.
function ns.PlanTravel(zone, stop)
    ns.travel = nil
    if not (zone and stop and ns.FLIGHT_NODES) then return nil end
    local c = ContinentOf(zone)
    if not c then return nil end
    local px, py = ns.PlayerOn(c.map)
    local tx, ty = OnContinent(zone, stop.x, stop.y)
    if not (px and tx) then return nil end
    local run = RunSpeed()
    local walk = Yards(c, px, py, tx, ty) * WINDING / run

    local side = Side()
    local known = Known()
    local startCost = {}
    for id in pairs(known) do
        local node = ns.FLIGHT_NODES[id]
        if node and node.continent == zone.continent and node.side % (side * 2) >= side then
            startCost[id] = Yards(c, px, py, node.x, node.y) * WINDING / run + TAKEOFF
        end
    end
    if not next(startCost) then return nil end
    local best, prev = Flights(zone.continent, side, startCost)
    local bestTotal, bestEnd
    for id, t in pairs(best) do
        local node = ns.FLIGHT_NODES[id]
        if startCost[id] ~= t or prev[id] then          -- an actual flight
            local total = t + Yards(c, node.x, node.y, tx, ty) * WINDING / run
            if not bestTotal or total < bestTotal then bestTotal, bestEnd = total, id end
        end
    end
    if not bestTotal or walk - bestTotal < SAVE_SECONDS or bestTotal > walk * SAVE_SHARE then return nil end
    local first = bestEnd
    while prev[first] do first = prev[first] end
    ns.travel = {
        zone = zone, stop = stop,
        fromID = first, toID = bestEnd,
        from = ns.FLIGHT_NODES[first], to = ns.FLIGHT_NODES[bestEnd],
        seconds = bestTotal, walk = walk,
    }
    return ns.travel
end

-- Arrow target while travelling: the flight master, on the continent map.
function ns.TravelTarget()
    local t = ns.travel
    if not t then return nil end
    local c = ContinentOf(t.zone)
    return c and { map = c.map, x = t.from.x, y = t.from.y, w = c.w, h = c.h } or nil
end

local function Short(node) return node.name:match("^([^,]+)") or node.name end

function ns.TravelText()
    local t = ns.travel
    if not t then return nil end
    return string.format("Fly: take the |cffffd100%s|r flight master to |cffffd100%s|r (saves about %d min)",
        Short(t.from), Short(t.to), math.max(1, math.floor((t.walk - t.seconds) / 60 + 0.5)))
end

-------------------------------------------------------------------------------
-- When to think about it
-------------------------------------------------------------------------------

local function OnTaxi()
    local fn = ns.API(nil, "UnitOnTaxi")
    local ok, on = ns.Ask(fn, "player")
    return ok and on == true
end
ns.OnTaxi = OnTaxi

local lastStop
local function Reconsider(force)
    local stop = ns.CurrentStop()
    if not stop then
        ns.travel = nil
        lastStop = nil
        return
    end
    if not force and stop == lastStop then return end
    lastStop = stop
    local before = ns.travel
    ns.PlanTravel(ns.route.zone, stop)
    if ns.travel and not (before and before.fromID == ns.travel.fromID and before.toID == ns.travel.toID) then
        ns.Banner("Fly there", ns.TravelText())
        ns.Print(ns.TravelText() .. ".")
    end
end

ns.On("route", function() Reconsider(false) end)

-- Every few seconds while a route runs: the flight may stop being worth it
-- (the player walked most of the way), and a landing replans from there.
local flying, elapsed, recheck = false, 0, 0
local watcher = CreateFrame("Frame")
watcher:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + (ns.Num(dt) or 0)
    if elapsed < 1 then return end
    elapsed = 0
    if not ns.route then
        flying = false
        return
    end
    -- Every ten seconds, see whether flying is still worth it.
    recheck = recheck + 1
    if recheck >= 10 and ns.travel then
        recheck = 0
        Reconsider(true)
    end
    local now = OnTaxi()
    if now and not flying then
        flying = true
        ns.travel = nil
        ns.Fire("travel")
    elseif flying and not now then
        flying = false
        ns.InvalidateProgress()
        ns.StartRoute(ns.route.zone, { quiet = true, skipped = ns.route.skipped, auto = ns.route.auto })
        local text = ns.NextStopText()
        if text then ns.Banner("Landed", text) end
    end
end)


local taxi = CreateFrame("Frame")
pcall(taxi.RegisterEvent, taxi, "TAXIMAP_OPENED")
taxi:SetScript("OnEvent", function()
    local n = ReadTaxiMap()
    if n > 0 and ns.route then Reconsider(true) end
end)
