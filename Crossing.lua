-- Compass Forever: Crossing.lua
-- A stop on the other continent: the way there is the nearest zeppelin or
-- boat across. While the player is on the wrong continent, the arrow, the
-- lines and the flight planner (Travel.lua) all aim at that dock instead of
-- the stop; once across, they aim at the stop again.
--
-- The docks, on their zone's map. Each crossing runs both ways; `side` is
-- who may take it (1 Alliance, 2 Horde, 3 both).

local _, ns = ...

local RIDE = 150             -- seconds: waiting for it, and the crossing
local RUN = 7                -- yards a second on foot
local WINDING = 1.3

ns.CROSSINGS = {
    { kind = "Zeppelin", side = 2,
      a = { map = 1411, x = 0.509, y = 0.135, place = "Orgrimmar" },
      b = { map = 1420, x = 0.607, y = 0.588, place = "Undercity" } },
    { kind = "Zeppelin", side = 2,
      a = { map = 1411, x = 0.506, y = 0.126, place = "Orgrimmar" },
      b = { map = 1434, x = 0.316, y = 0.292, place = "Grom'gol" } },
    { kind = "Boat", side = 1,
      a = { map = 1437, x = 0.049, y = 0.635, place = "Menethil Harbor" },
      b = { map = 1445, x = 0.716, y = 0.564, place = "Theramore" } },
    { kind = "Boat", side = 1,
      a = { map = 1437, x = 0.046, y = 0.572, place = "Menethil Harbor" },
      b = { map = 1439, x = 0.324, y = 0.438, place = "Auberdine" } },
    { kind = "Boat", side = 3,
      a = { map = 1413, x = 0.637, y = 0.386, place = "Ratchet" },
      b = { map = 1434, x = 0.259, y = 0.731, place = "Booty Bay" } },
}

local function Side()
    local ok, faction = ns.Ask(_G.UnitFactionGroup, "player")
    if ok and faction == "Alliance" then return 1 end
    if ok and faction == "Horde" then return 2 end
    return 3
end

-- The continent (0 or 1) the player is on, or nil.
function ns.PlayerContinent()
    for c, cont in pairs(ns.CONTINENT_YARDS or {}) do
        local x, y = ns.PlayerOn(cont.map)
        if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then return c end
    end
    return nil
end

local function Yards(cont, ax, ay, bx, by)
    local dx, dy = (ax - bx) * cont.w, (ay - by) * cont.h
    return math.sqrt(dx * dx + dy * dy)
end

-- A dock as a stop of its own (the same table every time, so the flight
-- planner sees when the target changes).
local docks = {}
local function DockStop(key, from, to, kind)
    local s = docks[key]
    if not s then
        s = { x = from.x, y = from.y, dock = true,
              node = { name = kind .. " to " .. to.place, overlay = "dock" .. key } }
        docks[key] = s
    end
    return s
end

local cache = { t = -10 }

-- When `stop` on `zone` is across the sea from the player: { zone, stop,
-- name, place } for the dock to head for; nil when it's on this continent,
-- or no crossing is known (or the player can't be placed).
function ns.Crossing(zone, stop)
    local okT, now = pcall(GetTime)
    now = okT and now or 0
    if cache.stop == stop and cache.zone == zone and now - cache.t < 1 then return cache.result end
    local result
    local here = ns.PlayerContinent()
    if here and here ~= zone.continent then
        local hc, tc = ns.CONTINENT_YARDS[here], ns.CONTINENT_YARDS[zone.continent]
        local px, py = ns.PlayerOn(hc.map)
        local tx, ty = ns.ZoneToContinentPoint(zone, stop.x, stop.y)
        local side, best = Side(), nil
        for i, x in ipairs(ns.CROSSINGS) do
            if x.side % (side * 2) >= side then
                for _, dir in ipairs({ { x.a, x.b, "a" }, { x.b, x.a, "b" } }) do
                    local from, to = dir[1], dir[2]
                    local fz, tz = ns.ZoneByMap(from.map), ns.ZoneByMap(to.map)
                    if fz and tz and fz.continent == here and tz.continent == zone.continent then
                        local fx, fy = ns.ZoneToContinentPoint(fz, from.x, from.y)
                        local ax, ay = ns.ZoneToContinentPoint(tz, to.x, to.y)
                        if fx and ax and px and tx then
                            local cost = (Yards(hc, px, py, fx, fy) + Yards(tc, ax, ay, tx, ty)) * WINDING / RUN + RIDE
                            if not best or cost < best.cost then
                                best = { cost = cost, zone = fz, stop = DockStop(i .. dir[3], from, to, x.kind),
                                         name = x.kind .. " to " .. to.place, place = to.place, kind = x.kind }
                            end
                        end
                    end
                end
            end
        end
        result = best
    end
    cache = { t = now, stop = stop, zone = zone, result = result }
    return result
end

-- Where to head now for the route's next stop: the stop itself, or the dock
-- across to it. zone, stop, crossing (or nil).
function ns.NavTarget()
    local stop = ns.CurrentStop()
    if not stop then return nil end
    local zone = ns.route.zone
    local cross = ns.Crossing(zone, stop)
    if cross then return cross.zone, cross.stop, cross end
    return zone, stop, nil
end
