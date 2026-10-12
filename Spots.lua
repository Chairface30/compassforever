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

-- A moved spot, or nil.
function ns.MovedSpot(node)
    local spots = ns.db and ns.db.spots
    return node.criteria and spots and spots[node.criteria] or nil
end

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
                local learn = ns.db.learnSpots ~= false and ns.route and ns.route.zone == zone
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
