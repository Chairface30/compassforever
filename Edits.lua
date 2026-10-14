-- Compass Forever: Edits.lua
-- Zones mapped by hand.
--
-- Walls, roads and zone lines drawn by hand (Pathing.lua) can be built into
-- the addon (Data/Walls.lua, Data/Roads.lua, Data/ZoneLines.lua, by
-- tools/bake_edits.py); at login the player's own copies of built-in ones
-- are dropped.

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
-- mark. Spots and where credit was given (gone from the addon) are dropped too.
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
    db.spots, db.learnSpots, db.credit = nil, nil, nil
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
