-- Compass Forever: Areas.lua
-- Each map area's real outline (Data/Areas.lua, from the terrain; Mulgore so
-- far). An area is uncovered by stepping anywhere into it, so a route heads
-- for the nearest point just inside its edge rather than one point in its
-- middle, and you're there as soon as you're inside.

local _, ns = ...

local SCALE = 10000
local decoded = {}

-- Areas the game gives credit for at one place only, by their key: the
-- route goes there rather than to the nearest edge, and only there counts
-- as arriving.
--   Drygulch Ravine (Durotar): a cave, reached by the narrow path on the
--   left of the ravine.
local ENTRY = {
    [830] = { { 0.515, 0.277 } },
}

-- An area's outline as fractions of its zone's map: { rings = { { x1, y1,
-- x2, y2, ... } ... }, edge = { { x, y } ... } }, or nil without one.
-- A node's key for what's kept per area (its outline, its credit): its
-- criteria ID, or "o" .. overlay ID for a piece of the map no criterion
-- names (mapOnly). nil for a flight master or a dock.
function ns.NodeKey(node)
    return node.criteria or (node.mapOnly and "o" .. node.overlay) or nil
end

function ns.AreaOf(node)
    local crit = ns.NodeKey(node)
    local raw = crit and ns.AREAS and ns.AREAS[crit]
    if not raw then return nil end
    local a = decoded[crit]
    if a then return a end
    a = { rings = {}, edge = {} }
    for _, r in ipairs(raw.rings) do
        local ring = {}
        for i = 1, #r do ring[i] = r[i] / SCALE end
        a.rings[#a.rings + 1] = ring
    end
    for i = 1, #raw.edge - 1, 2 do
        a.edge[#a.edge + 1] = { raw.edge[i] / SCALE, raw.edge[i + 1] / SCALE }
    end
    if ENTRY[crit] then a.edge, a.fixed = ENTRY[crit], true end
    decoded[crit] = a
    return a
end

-- Is (x, y) on the zone's map inside the area (inside an odd number of its
-- rings)? nil when it has no outline.
function ns.InArea(node, x, y)
    local a = ns.AreaOf(node)
    if not a then return nil end
    local inside = false
    for _, r in ipairs(a.rings) do
        local jx, jy = r[#r - 1], r[#r]
        for i = 1, #r - 1, 2 do
            local ix, iy = r[i], r[i + 1]
            if (iy > y) ~= (jy > y) and x < (jx - ix) * (y - iy) / (jy - iy) + ix then
                inside = not inside
            end
            jx, jy = ix, iy
        end
    end
    return inside
end

-- Is the player standing inside the area? false without an outline, and for
-- an area whose credit is given at one place only.
function ns.PlayerInArea(zone, node)
    local a = ns.AreaOf(node)
    if not a or a.fixed then return false end
    local px, py = ns.PlayerOn(zone.map)
    return (px and ns.InArea(node, px, py)) and true or false
end
