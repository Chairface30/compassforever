-- Compass Forever: Spots.lua
-- Where each area's spot is, and where its credit was really given.
--
-- A spot can be moved by hand (the window's Spots mode: drag a marker):
-- CompassForeverDB.spots[criteria] = { x, y } on the zone's map, used in
-- place of the spots picked from the terrain. Right-click puts it back.
--
-- Whenever an area of the zone you're in turns uncovered, where you were
-- standing is kept in CompassForeverDB.credit[criteria] = { x, y } and said
-- in chat, so spots can be put exactly where the game gives credit. While a
-- route runs there (and learnSpots is on), the area's spot moves to it too.

local _, ns = ...

-- A moved spot: the player's own, else the shipped one (Data/Spots.lua),
-- else nil.
function ns.MovedSpot(node)
    if not node.criteria then return nil end
    local spots = ns.db and ns.db.spots
    return spots and spots[node.criteria] or ns.SPOTS and ns.SPOTS[node.criteria] or nil
end

-- A zone mapped by hand: walls, roads or spots of it built into the addon.
function ns.ZoneHandMapped(zone)
    if ns.WALLS and ns.WALLS[zone.ach] and #ns.WALLS[zone.ach] > 0 then return true end
    if ns.ROADS and ns.ROADS[zone.ach] and #ns.ROADS[zone.ach] > 0 then return true end
    if ns.ZONELINES and ns.ZONELINES[zone.ach] and #ns.ZONELINES[zone.ach] > 0 then return true end
    for _, node in ipairs(zone.nodes) do
        if node.criteria and ns.SPOTS and ns.SPOTS[node.criteria] then return true end
    end
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

-- At login: saved walls, roads and spots that are now shipped are dropped,
-- so what was built in doesn't show as the player's own; a zone marked done
-- with nothing of its own left has been built in, and loses the mark.
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
    for crit, xy in pairs(db.spots or {}) do
        local s = ns.SPOTS and ns.SPOTS[crit]
        if s and Same(xy, s) then db.spots[crit] = nil end
    end
    for _, zone in ipairs(ns.ZONES) do
        if ns.ZoneMarkedDone(zone) and ns.ZoneHandMapped(zone)
                and not ns.OwnLines(zone, "walls") and not ns.OwnLines(zone, "roads")
                and not ns.OwnLines(zone, "zonelines") then
            local own = false
            for _, node in ipairs(zone.nodes) do
                if node.criteria and db.spots and db.spots[node.criteria] then own = true end
            end
            if not own then ns.SetZoneMarkedDone(zone, false) end
        end
    end
end
ns.On("login", function() pcall(DropShipped) end)

-- Where credit for an area was given, or nil.
function ns.CreditSpot(node)
    local credit = ns.db and ns.db.credit
    return node.criteria and credit and credit[node.criteria] or nil
end

-- A route under way in `zone` is planned again from where it stands.
local function Replan(zone)
    if ns.route and ns.route.zone == zone then
        ns.StartRoute(zone, { quiet = true })
    end
    ns.Fire("spots")
end

local function Round(v) return math.floor(v * 10000 + 0.5) / 10000 end

function ns.MoveSpot(zone, node, x, y)
    if not node.criteria then return end
    ns.db.spots = ns.db.spots or {}
    ns.db.spots[node.criteria] = { Round(x), Round(y) }
    ns.Print(string.format("%s's spot moved to %.1f, %.1f.", node.name, x * 100, y * 100))
    Replan(zone)
end

function ns.ResetSpot(zone, node)
    if not (node.criteria and ns.db.spots and ns.db.spots[node.criteria]) then return end
    ns.db.spots[node.criteria] = nil
    ns.Print(node.name .. "'s spot is back where it was.")
    Replan(zone)
end
ns.DropShippedEdits = DropShipped

-- A node's spot moved to where you stand, uncovered here or not (spots are
-- the account's, not the character's).
function ns.SpotToMe(zone, node)
    local px, py = ns.PlayerOn(zone.map)
    if not (px and py and px >= 0 and px <= 1 and py >= 0 and py <= 1) then
        ns.Print("You're not on " .. zone.name .. "'s map.")
        return
    end
    ns.MoveSpot(zone, node, px, py)
end

-- The area you're standing in, by the game's subzone name.
function ns.AreaHere()
    local zone = ns.CurrentZone()
    if not zone then return nil end
    local ok, sub = ns.Ask(ns.API(nil, "GetSubZoneText"))
    sub = ok and ns.Text(sub)
    if not sub or sub == "" then return zone, nil end
    sub = sub:lower()
    for _, node in ipairs(zone.nodes) do
        if node.name:lower() == sub and not node.fp then return zone, node end
    end
    return zone, nil
end

-- The Spot here button: the area you're in gets its spot where you stand.
function ns.SpotHere()
    local zone, node = ns.AreaHere()
    if not zone then
        ns.Print("You're not in a zone with areas to explore.")
    elseif not node then
        ns.Print("You're not in one of " .. zone.name .. "'s areas (by its name). "
            .. "Shift-click an area's marker in Spots mode to move that one to you.")
    else
        ns.SpotToMe(zone, node)
    end
end

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
        if state[i] == true and last[i] ~= true and node.criteria then
            local px, py
            if eventAt and eventAt.ach == zone.ach then
                px, py = eventAt.x, eventAt.y
            else
                px, py = ns.PlayerOn(zone.map)
            end
            if px and py then
                ns.db.credit = ns.db.credit or {}
                ns.db.credit[node.criteria] = { Round(px), Round(py) }
                -- an area with a known outline keeps heading for its edge
                local learn = ns.db.learnSpots ~= false and ns.route and ns.route.zone == zone
                    and not (ns.AreaOf and ns.AreaOf(node))
                if learn then
                    ns.db.spots = ns.db.spots or {}
                    ns.db.spots[node.criteria] = { Round(px), Round(py) }
                end
                ns.Print(string.format("Credit for %s at %.1f, %.1f.%s", node.name, px * 100, py * 100,
                    learn and " Its spot is moved there." or ""))
            end
        end
    end
end)
