-- Compass Forever: Edits.lua
-- Zones mapped by hand, and where each area's credit was really given.
--
-- Walls, roads and zone lines drawn by hand (Pathing.lua) can be built into
-- the addon (Data/Walls.lua, Data/Roads.lua, Data/ZoneLines.lua, by
-- tools/bake_edits.py); at login the player's own copies of built-in ones
-- are dropped.
--
-- Whenever an area of the zone you're in turns uncovered, where you were
-- standing is kept in CompassForeverDB.credit[key] = { x, y } and said in
-- chat, so the outlines can be checked against where the game gives credit.

local _, ns = ...

-- A zone mapped by hand: walls, roads or zone lines of it built in.
function ns.ZoneHandMapped(zone)
    if ns.WALLS and ns.WALLS[zone.ach] and #ns.WALLS[zone.ach] > 0 then return true end
    if ns.ROADS and ns.ROADS[zone.ach] and #ns.ROADS[zone.ach] > 0 then return true end
    if ns.ZONELINES and ns.ZONELINES[zone.ach] and #ns.ZONELINES[zone.ach] > 0 then return true end
    return false
end

-- Marked done mapping by the player: ready to be built in.
function ns.ZoneMarkedDone(zone)
    return ns.db and ns.db.finished and ns.db.finished[zone.ach] and true or false
end

function ns.SetZoneMarkedDone(zone, on)
    ns.db.finished = ns.db.finished or {}
    ns.db.finished[zone.ach] = on and true or nil
end

-- At login: saved walls, roads and zone lines that are now shipped are
-- dropped, so what was built in doesn't show as the player's own; a zone
-- marked done with nothing of its own left has been built in, and loses the
-- mark. Spots (gone from the addon) are dropped too.
local function Same(a, b)
    if a.circle or b.circle then
        if not (a.circle and b.circle) then return false end
        a, b = a.circle, b.circle
    end
    if #a ~= #b then return false end
    for i = 1, #a do
        if math.abs(a[i] - b[i]) > 1e-6 then return false end
    end
    return true
end

local function DropShipped()
    local db = ns.db
    db.spots, db.learnSpots = nil, nil
    for kind, shippedAll in pairs({ walls = ns.WALLS or {}, roads = ns.ROADS or {}, zonelines = ns.ZONELINES or {} }) do
        local mineAll = db[kind]
        if mineAll then
            for ach, mine in pairs(mineAll) do
                local shipped = shippedAll[ach]
                if shipped then
                    for i = #mine, 1, -1 do
                        for _, s in ipairs(shipped) do
                            if Same(mine[i], s) then
                                table.remove(mine, i)
                                break
                            end
                        end
                    end
                end
                if #mine == 0 then mineAll[ach] = nil end
            end
        end
    end
    for _, zone in ipairs(ns.ZONES) do
        if ns.ZoneMarkedDone(zone) and ns.ZoneHandMapped(zone)
                and not ns.OwnLines(zone, "walls") and not ns.OwnLines(zone, "roads")
                and not ns.OwnLines(zone, "zonelines") then
            ns.SetZoneMarkedDone(zone, false)
        end
    end
end
-- Zones taken back out of the built-in lines (Data/Returned.lua): their
-- lines become the player's own again, once (CompassForeverDB.returned), so
-- they can be edited; the zone's done mark goes, to be ticked again.
local function TakeBack()
    local db = ns.db
    db.returned = db.returned or {}
    -- built in again since: taken back out another time, it's handed back
    for ach in pairs(db.returned) do
        if not (ns.RETURNED and ns.RETURNED[ach]) then db.returned[ach] = nil end
    end
    for ach, kinds in pairs(ns.RETURNED or {}) do
        if not db.returned[ach] then
            for kind, lines in pairs(kinds) do
                db[kind] = db[kind] or {}
                local mine = db[kind][ach] or {}
                for _, line in ipairs(lines) do
                    local have = false
                    for _, m in ipairs(mine) do if Same(m, line) then have = true break end end
                    if not have then mine[#mine + 1] = line end
                end
                db[kind][ach] = #mine > 0 and mine or nil
            end
            if db.finished then db.finished[ach] = nil end
            db.returned[ach] = true
        end
    end
end

ns.On("login", function()
    pcall(TakeBack)
    pcall(DropShipped)
end)
ns.DropShippedEdits = DropShipped

-- Where credit for an area was given, or nil.
function ns.CreditAt(node)
    local credit = ns.db and ns.db.credit
    local key = ns.NodeKey(node)
    return key and credit and credit[key] or nil
end

local function Round(v) return math.floor(v * 10000 + 0.5) / 10000 end

-- Credit: what the zone you're in had uncovered last time, by its ach.
local seen = {}

-- Where you were when the game said something changed: progress is
-- handled a moment later, by which time you may have run on.
local eventAt
function ns.OnProgressEvent()
    local zone = ns.CurrentZone()
    local px, py
    if zone then px, py = ns.PlayerOn(zone.map) end
    eventAt = (px and py) and { ach = zone.ach, x = px, y = py } or nil
end

ns.On("progress", function()
    local zone = ns.CurrentZone()
    if not zone then return end
    local state = ns.ZoneState(zone).state
    local last = seen[zone.ach]
    local now = {}
    for i in ipairs(zone.nodes) do now[i] = state[i] end
    seen[zone.ach] = now
    if not last then return end
    for i, node in ipairs(zone.nodes) do
        local key = ns.NodeKey(node)
        if state[i] == true and last[i] ~= true and key then
            local px, py
            if eventAt and eventAt.ach == zone.ach then
                px, py = eventAt.x, eventAt.y
            else
                px, py = ns.PlayerOn(zone.map)
            end
            if px and py then
                ns.db.credit = ns.db.credit or {}
                ns.db.credit[key] = { Round(px), Round(py) }
                ns.Print(string.format("Credit for %s at %.1f, %.1f.", node.name, px * 100, py * 100))
            end
        end
    end
end)
