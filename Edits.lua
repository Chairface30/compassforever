-- Compass Forever: Edits.lua
-- Zones mapped by hand.
--
-- Walls, roads, zone lines and ledges drawn by hand (Pathing.lua) can be
-- built into the addon (Data/Walls.lua, Roads.lua, ZoneLines.lua, Ledges.lua,
-- by tools/bake_edits.py); at login the player's own copies of built-in ones
-- are dropped.

local KINDS = { walls = "WALLS", roads = "ROADS", zonelines = "ZONELINES", ledges = "LEDGES" }

local _, ns = ...

-- A zone mapped by hand: walls, roads or zone lines of it built in.
function ns.ZoneHandMapped(zone)
    for _, var in pairs(KINDS) do
        if ns[var] and ns[var][zone.ach] and #ns[var][zone.ach] > 0 then return true end
    end
    return false
end

-- The zone's built-in lines, taken over to edit: copied into the player's
-- own, and only those count for the zone's paths until it's baked again
-- (bake_edits.py puts them in place of the built-in ones).
function ns.TakeOverBuiltIn(zone)
    local db = ns.db
    if db.takeover and db.takeover[zone.ach] then return false end
    local n = 0
    for kind, var in pairs(KINDS) do
        local shipped = ns[var] and ns[var][zone.ach]
        if shipped and #shipped > 0 then
            db[kind] = db[kind] or {}
            local mine = db[kind][zone.ach] or {}
            for _, line in ipairs(shipped) do
                local copy = {}
                if line.circle then
                    copy.circle = { line.circle[1], line.circle[2], line.circle[3] }
                else
                    for i = 1, #line do copy[i] = line[i] end
                end
                mine[#mine + 1] = copy
                n = n + 1
            end
            db[kind][zone.ach] = mine
        end
    end
    db.takeover = db.takeover or {}
    db.takeover[zone.ach] = true
    if ns.WallsChanged then ns.WallsChanged() end
    return n
end

function ns.TakenOver(zone)
    return ns.db and ns.db.takeover and ns.db.takeover[zone.ach] and true or false
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
    -- a zone taken over: once what's built in is exactly the player's copy
    -- (it was baked), the copy goes and the zone is back to built-in
    for ach in pairs(db.takeover or {}) do
        local same = true
        for kind, var in pairs(KINDS) do
            local mine = db[kind] and db[kind][ach] or {}
            local shipped = ns[var] and ns[var][ach] or {}
            if #mine ~= #shipped then same = false break end
            for i = 1, #mine do
                if not Same(mine[i], shipped[i]) then same = false break end
            end
            if not same then break end
        end
        if same then
            db.takeover[ach] = nil
            for kind in pairs(KINDS) do
                if db[kind] then db[kind][ach] = nil end
            end
        end
    end
    for kind, var in pairs(KINDS) do
        local shippedAll = ns[var] or {}
        local mineAll = db[kind]
        if mineAll then
            for ach, mine in pairs(mineAll) do
                local shipped = not (db.takeover and db.takeover[ach]) and shippedAll[ach]
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
        if ns.ZoneMarkedDone(zone) and ns.ZoneHandMapped(zone) and not ns.TakenOver(zone)
                and not ns.OwnLines(zone, "walls") and not ns.OwnLines(zone, "roads")
                and not ns.OwnLines(zone, "zonelines") and not ns.OwnLines(zone, "ledges") then
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
