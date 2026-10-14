-- Compass Forever: Travel.lua
-- Flying there when that is quicker than walking.
--
-- Which flight points a character knows is read from the flight map, each
-- time one opens, and remembered for that character (CompassForeverDB.taxi).
-- On Forever the flight map lists every point of the faction: only those it
-- calls current or reachable are the character's; the rest (distant) are
-- points not learned yet, and forgotten if they were remembered. Until a
-- character's first flight map, nothing is assumed known or unknown.
--
-- The world map's list (C_TaxiMap.GetTaxiNodesForMap) is only trusted to
-- say a point is undiscovered: on Forever it calls every point of both
-- factions discovered, for every character.
--
-- At the flight master, with a flight planned, a "Fly to ..." button sits by
-- the flight map; with "Fly automatically" on, the flight is taken as soon as
-- the map opens.
--
-- When the next stop is far, the way there with the least running is worked
-- out: walking straight there, or walking to a known flight point, flying
-- (through other known points if need be) and walking from where you land,
-- a second in the air counted as a quarter of one on foot. Flying wins when
-- it saves a real amount of running, even if it takes longer. Then the arrow points at the flight
-- master first, and after landing the route carries on from there.
--
-- All distances here are on the continent's map (Data/Flights.lua puts every
-- flight point there), walking ones as the crow flies with an allowance for
-- the way not being straight.

local _, ns = ...

local WINDING = 1.3          -- walking is this much longer than a straight line
local TAKEOFF = 25           -- seconds to talk, mount up and land
local SAVE_SECONDS = 30      -- flying must save at least this much running
-- A flight is taken for the running it saves, even when it takes longer:
-- a second in the air counts as this much of a second on foot.
local FLY_WEIGHT = 0.25
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

-- Lists made before the world map's word stopped counting (2), or while a
-- distant point on the flight map counted (3), called every point known:
-- dropped once, so each character's first flight map fills
-- in the real list.
local TAXI_VERSION = 3
local function Fresh()
    local db = ns.db
    if db.taxiVersion ~= TAXI_VERSION then
        db.taxi, db.taxiRead, db.taxiVersion = {}, {}, TAXI_VERSION
    end
end

local function Known()
    local db = ns.db
    Fresh()
    db.taxi = db.taxi or {}
    local key = CharKey()
    db.taxi[key] = db.taxi[key] or {}
    return db.taxi[key]
end
ns.KnownFlights = Known

local nameIndex
local function ByName(name, retried)
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
    local id = nameIndex[name] or nameIndex[name:match("^([^,]+)") or ""]
    if not id and not retried then
        -- a point added since the index was made: make it again, once
        nameIndex = nil
        return ByName(name, true)
    end
    return id
end

-- Read the open flight map: every point the character can fly to, or is at.
local function ReadTaxiMap()
    local known, seen = Known(), 0
    local before = 0
    for _ in pairs(known) do before = before + 1 end
    -- what the flight map said, kept to be read after a /reload
    -- (CompassForeverDB.taxiSaid): name, type, state
    local said = {}
    ns.db.taxiSaid = said
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
                said[#said + 1] = "all: " .. tostring(ns.Text(info.name)) .. " state=" .. (ns.Secret(state) and "secret" or tostring(state))
                if id and state ~= nil and (state == states.Current or state == states.Reachable) then
                    known[id] = true
                    seen = seen + 1
                elseif id and state ~= nil and state == states.Unreachable then
                    known[id] = nil
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
            said[#said + 1] = "map: " .. (okN and tostring(name) or "?") .. " type=" .. (okK and tostring(kind) or "unreadable")
            local id = okN and ByName(ns.Text(name))
            -- a distant point is one not learned yet: it can't be flown to
            if id and (not kindOf or (okK and (kind == "CURRENT" or kind == "REACHABLE"))) then
                known[id] = true
                seen = seen + 1
            elseif id and okK and (kind == "DISTANT" or kind == "NONE") then
                known[id] = nil
            end
        end
    end
    if seen > 0 then
        ns.db.taxiRead = ns.db.taxiRead or {}
        ns.db.taxiRead[CharKey()] = true
        ns.flightsRead = true
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

-- The world map's word on flight points: one it calls undiscovered is
-- forgotten; one it calls discovered proves nothing (see the top). Returns
-- how many points it said anything about.
local function ReadFromMaps()
    Fresh()
    ns.flightsRead = (ns.db.taxiRead and ns.db.taxiRead[CharKey()]) and true or false
    local forMap = ns.API("C_TaxiMap", "GetTaxiNodesForMap")
    if not forMap then return 0 end
    local known, said = Known(), 0
    local maps = { 1415, 1414, 1453, 1454, 1455, 1456, 1457, 1458 }
    for _, zone in ipairs(ns.ZONES) do maps[#maps + 1] = zone.map end
    local seen = {}
    for _, mapID in ipairs(maps) do
        local ok, list = ns.Ask(forMap, mapID)
        if ok and type(list) == "table" then
            for _, info in ipairs(list) do
                local id = ns.Num(info.nodeID)
                if not (id and ns.FLIGHT_NODES[id]) then id = ByName(ns.Text(info.name)) end
                if id and not seen[id] then
                    seen[id] = true
                    said = said + 1
                    if info.isUndiscovered == true then known[id] = nil end
                end
            end
        end
    end
    return said
end
ns.ReadKnownFromMaps = ReadFromMaps

-- The flight masters of `zone` this character could learn and hasn't, as
-- route stops (Route.lua decides whether they're worth the walk). Only once
-- the client has said which points are known: until then every flight
-- master would look undiscovered.
-- A flight point of `zone` itself, by the zone its name gives ("Thunder
-- Bluff, Mulgore"): a zone's map reaches past its edges, onto its
-- neighbors' flight points.
local function InZone(node, zone)
    local where = node.name:match(",%s*(.+)$")
    return not where or zone.name:sub(1, #where) == where
end

local stopNodes = {}
function ns.FlightStops(zone)
    local out = {}
    if not (ns.flightsRead and ns.FLIGHT_NODES and ns.MapRect) then return out end
    local c = ns.CONTINENT_YARDS and ns.CONTINENT_YARDS[zone.continent]
    local r = c and ns.MapRect(zone.map, c.map)
    if not r then return out end
    local known, side = Known(), Side()
    for id, node in pairs(ns.FLIGHT_NODES) do
        if InZone(node, zone) and node.continent == zone.continent and not known[id] and node.side % (side * 2) >= side then
            local x = (node.x - r.l) / (r.r - r.l)
            local y = (node.y - r.t) / (r.b - r.t)
            if x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                local stop = stopNodes[id]
                if not stop then
                    stop = {
                        fp = id, overlay = "fp" .. id,
                        name = "Flight master: " .. (node.name:match("^([^,]+)") or node.name),
                        points = { math.floor(x * 10000 + 0.5), math.floor(y * 10000 + 0.5) },
                    }
                    stopNodes[id] = stop
                end
                out[#out + 1] = stop
            end
        end
    end
    return out
end


-------------------------------------------------------------------------------
-- Where things are on the continent
-------------------------------------------------------------------------------

local function ContinentOf(zone) return ns.CONTINENT_YARDS and ns.CONTINENT_YARDS[zone.continent] end

-- "Orgrimmar" for "Orgrimmar, Durotar".
local function Short(node) return node.name:match("^([^,]+)") or node.name end

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

-- The cost of reaching every known point by air (through others known), from
-- each starting point's cost, a flight's seconds counted at FLY_WEIGHT; and
-- the real seconds in the air to each.
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
    local best, prev, done, air = {}, {}, {}, {}
    for id, cost in pairs(startCost) do best[id], prev[id], air[id] = cost, nil, 0 end
    while true do
        local cur, cc
        for id, c in pairs(best) do
            if not done[id] and (not cc or c < cc) then cur, cc = id, c end
        end
        if not cur then break end
        done[cur] = true
        for _, e in ipairs(edges[cur] or {}) do
            local c = cc + e[2] * FLY_WEIGHT
            if not best[e[1]] or c < best[e[1]] then
                best[e[1]], prev[e[1]], air[e[1]] = c, cur, air[cur] + e[2]
            end
        end
    end
    return best, prev, air
end

-- Where a flight from here could land for a route through `zone`: every
-- known flight point of the zone (Sun Rock Retreat is on Ashenvale's map,
-- but Stonetalon's) that a flight reaches
-- (walking to a known point, then flying through others known), as
-- { x, y (the zone's map), yards (its cost as yards of running: the run to
-- the flight master, and the flight at FLY_WEIGHT), id, name }. Empty when no flight is known or you can't be placed.
local NEAR_ZONE = 0.05       -- of the zone's map outside its edge
function ns.FlightLandings(zone)
    local out = {}
    if not (zone and ns.FLIGHT_NODES and ns.MapRect) then return out end
    local c = ContinentOf(zone)
    local r = c and ns.MapRect(zone.map, c.map)
    if not r then return out end
    local px, py = ns.PlayerOn(c.map)
    if not px then return out end
    local run, side = RunSpeed(), Side()
    local startCost = {}
    for id in pairs(Known()) do
        local node = ns.FLIGHT_NODES[id]
        if node and node.continent == zone.continent and node.side % (side * 2) >= side then
            startCost[id] = Yards(c, px, py, node.x, node.y) * WINDING / run + TAKEOFF * FLY_WEIGHT
        end
    end
    if not next(startCost) then return out end
    local best, prev = Flights(zone.continent, side, startCost)
    for id, t in pairs(best) do
        local node = ns.FLIGHT_NODES[id]
        if (startCost[id] ~= t or prev[id]) and InZone(node, zone) then  -- an actual flight
            local x = (node.x - r.l) / (r.r - r.l)
            local y = (node.y - r.t) / (r.b - r.t)
            if x >= -NEAR_ZONE and x <= 1 + NEAR_ZONE and y >= -NEAR_ZONE and y <= 1 + NEAR_ZONE then
                out[#out + 1] = { x = x, y = y, yards = t * run, id = id, name = Short(node) }
            end
        end
    end
    return out
end

-- Plan the way to `stop` on `zone`; sets ns.travel to a flight or nil.
-- Returns nil, "unplaced" when the player can't be placed on the stop's
-- continent yet (on a zeppelin or boat, say): worth asking again soon.
local lastRead = -60
local function Why(text) ns.travelWhy = text return nil end
function ns.PlanTravel(zone, stop)
    ns.travel = nil
    ns.travelWhy = nil
    local okT, now = pcall(GetTime)
    now = okT and now or 0
    if now - lastRead > 30 then
        lastRead = now
        ReadFromMaps()
    end
    if not (zone and stop and ns.FLIGHT_NODES) then return Why("no stop") end
    local c = ContinentOf(zone)
    if not c then return Why("no continent for " .. tostring(zone.name)) end
    local px, py = ns.PlayerOn(c.map)
    local tx, ty = OnContinent(zone, stop.x, stop.y)
    if not (px and tx) then
        Why(string.format("can't place %s on the continent map %d (you: %s, map %s)", px and "the stop" or "you",
            c.map, px and string.format("%.3f, %.3f", px, py) or "nowhere", tostring(ns.PlayerMap and ns.PlayerMap())))
        return nil, "unplaced"
    end
    local run = RunSpeed()
    local walk = Yards(c, px, py, tx, ty) * WINDING / run

    local side = Side()
    local known = Known()
    -- the flight with the least running, a second in the air counting at
    -- FLY_WEIGHT: taken when it saves real running, even if it takes longer
    local startCost, toFP = {}, {}
    for id in pairs(known) do
        local node = ns.FLIGHT_NODES[id]
        if node and node.continent == zone.continent and node.side % (side * 2) >= side then
            toFP[id] = Yards(c, px, py, node.x, node.y) * WINDING / run
            startCost[id] = toFP[id] + TAKEOFF * FLY_WEIGHT
        end
    end
    if not next(startCost) then return Why("no known flight point on this continent") end
    local best, prev, air = Flights(zone.continent, side, startCost)
    local bestCost, bestEnd, bestRun
    for id, t in pairs(best) do
        local node = ns.FLIGHT_NODES[id]
        if prev[id] then                                 -- an actual flight
            local first = id
            while prev[first] do first = prev[first] end
            local fromLanding = Yards(c, node.x, node.y, tx, ty) * WINDING / run
            local cost = t + fromLanding
            if not bestCost or cost < bestCost then
                bestCost, bestEnd, bestRun = cost, id, toFP[first] + fromLanding
            end
        end
    end
    if not bestCost then return Why("no flight from the known points") end
    if walk - bestRun < SAVE_SECONDS then
        return Why(string.format("running there is shorter: %d s on foot, %d s of running with the flight to %s",
            math.floor(walk), math.floor(bestRun), Short(ns.FLIGHT_NODES[bestEnd])))
    end
    local first = bestEnd
    while prev[first] do first = prev[first] end
    ns.travel = {
        zone = zone, stop = stop,
        fromID = first, toID = bestEnd,
        from = ns.FLIGHT_NODES[first], to = ns.FLIGHT_NODES[bestEnd],
        seconds = bestRun + TAKEOFF + air[bestEnd], run = bestRun, walk = walk,
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


function ns.TravelText()
    local t = ns.travel
    if not t then return nil end
    return string.format("Fly: take the |cffffd100%s|r flight master to |cffffd100%s|r (about %d min less running)",
        Short(t.from), Short(t.to), math.max(1, math.floor((t.walk - (t.run or t.seconds)) / 60 + 0.5)))
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

-- On a flight: nothing is replanned, steered or redrawn until you land
-- (the route is planned again from where you come down). ns.flight says
-- where to, when a planned flight was taken.
ns.flight = nil
local inFlight = false
function ns.InFlight() return inFlight end

local lastStop
local hinted = false
local function Reconsider(force)
    local stop = ns.CurrentStop()
    if not stop then
        ns.travel = nil
        lastStop = nil
        return
    end
    -- across the sea: the flight is to the dock
    local zone = ns.route.zone
    local cross = ns.Crossing and ns.Crossing(zone, stop)
    if cross then zone, stop = cross.zone, cross.stop end
    if not force and stop == lastStop then return end
    lastStop = stop
    if not ns.flightsRead and not hinted then
        hinted = true
        ns.Print("doesn't know this character's flight points yet, so routes walk: open any flight master's map once.")
    end
    local before = ns.travel
    local _, why = ns.PlanTravel(zone, stop)
    -- coming off a zeppelin the stop changes before the game can place you
    -- on the new continent: asked again next second, not given up on
    if why == "unplaced" then lastStop = nil end
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
    local now = OnTaxi()
    inFlight = now
    if not ns.route then
        flying = false
        ns.flight = nil
        return
    end
    if now then
        if not flying then
            flying = true
            ns.flight = { to = ns.travel and Short(ns.travel.to) or nil }
            ns.travel = nil
            ns.Fire("travel")
        end
        return
    end
    -- Off a boat or zeppelin, the target is the stop again.
    Reconsider(false)
    -- Every ten seconds, see whether flying is (still) worth it.
    recheck = recheck + 1
    if recheck >= 10 and not flying then
        recheck = 0
        Reconsider(true)
    end
    if flying then
        flying = false
        ns.flight = nil
        ns.InvalidateProgress()
        ns.StartRoute(ns.route.zone, { quiet = true, skipped = ns.route.skipped, auto = ns.route.auto })
        local text = ns.NextStopText()
        if text then ns.Banner("Landed", text) end
    end
end)


-------------------------------------------------------------------------------
-- At the flight master
-------------------------------------------------------------------------------

-- The open flight map's entry for a flight point: its slot, to fly to.
local function Slot(nodeID)
    local node = ns.FLIGHT_NODES[nodeID]
    local getAll = ns.API("C_TaxiMap", "GetAllTaxiNodes")
    if getAll then
        local okM, mapID = ns.Ask(ns.API(nil, "GetTaxiMapID"))
        local ok, nodes = ns.Ask(getAll, okM and mapID or nil)
        if ok and type(nodes) == "table" then
            for _, info in ipairs(nodes) do
                local id = ns.Num(info.nodeID) or ByName(ns.Text(info.name))
                if id == nodeID and ns.Num(info.slotIndex) then return info.slotIndex end
            end
        end
    end
    local okC, n = ns.Ask(ns.API(nil, "NumTaxiNodes"))
    local nameOf = ns.API(nil, "TaxiNodeName")
    if okC and ns.Num(n) and nameOf and node then
        for i = 1, n do
            local okN, name = ns.Ask(nameOf, i)
            if okN and ByName(ns.Text(name)) == nodeID then return i end
        end
    end
    return nil
end

-- Take the planned flight from the open flight map. Returns true if asked.
function ns.TakePlannedFlight()
    local t = ns.travel
    if not t then return false end
    local slot = Slot(t.toID)
    local take = ns.API(nil, "TakeTaxiNode")
    if not (slot and take) then
        ns.Print("can't find " .. Short(t.to) .. " on this flight map.")
        return false
    end
    local ok, err = pcall(take, slot)
    if not ok then
        ns.Print("|cffff5555couldn't take the flight:|r", err)
        return false
    end
    return true
end

-- The "Fly to ..." button, by the flight map while one is planned.
local flyButton
local function ShowFlyButton()
    local t = ns.travel
    if not t then
        if flyButton then flyButton:Hide() end
        return
    end
    if not flyButton then
        flyButton = CreateFrame("Button", "CompassForeverFlyButton", UIParent, "UIPanelButtonTemplate")
        flyButton:SetSize(220, 28)
        flyButton:SetFrameStrata("DIALOG")
        flyButton:SetScript("OnClick", function(self)
            if ns.TakePlannedFlight() then self:Hide() end
        end)
    end
    flyButton:SetText("Compass: fly to " .. Short(t.to))
    flyButton:ClearAllPoints()
    local taxiFrame = _G.TaxiFrame or _G.FlightMapFrame
    if taxiFrame and taxiFrame.IsShown and taxiFrame:IsShown() then
        flyButton:SetPoint("TOP", taxiFrame, "BOTTOM", 0, -4)
    else
        flyButton:SetPoint("TOP", UIParent, "TOP", 0, -120)
    end
    flyButton:Show()
end

local taxi = CreateFrame("Frame")
for _, event in ipairs({ "TAXIMAP_OPENED", "TAXIMAP_CLOSED", "TAXI_NODE_STATUS_CHANGED" }) do
    pcall(taxi.RegisterEvent, taxi, event)
end
taxi:SetScript("OnEvent", function(_, event)
    if event == "TAXIMAP_CLOSED" then
        if flyButton then flyButton:Hide() end
        return
    end
    if event == "TAXI_NODE_STATUS_CHANGED" then
        ReadFromMaps()
        if ns.route then
            Reconsider(true)
            ns.ProgressChanged()
        end
        return
    end
    local seen = ReadTaxiMap()
    ReadFromMaps()
    if ns.route then
        Reconsider(true)
        ns.ProgressChanged()
    end
    -- what the flight map told, and what the route makes of it, every time
    local count = 0
    for _ in pairs(Known()) do count = count + 1 end
    local text = seen > 0 and string.format("knows %d flight point%s here", count, count == 1 and "" or "s")
        or "couldn't read which flight points this character knows"
    if ns.travel then
        text = text .. "; " .. ns.TravelText()
    elseif ns.route then
        text = text .. "; no flight for the route: " .. tostring(ns.travelWhy or "not asked")
    end
    ns.db.travelSaid = text
    ns.Print(text .. ".")
    if not ns.travel then return end
    if ns.db.autoFly and ns.TakePlannedFlight() then return end
    ShowFlyButton()
end)

ns.On("login", function()
    ReadFromMaps()
end)
