-- Compass Forever: Corpse.lua
-- While the player is a ghost: the way back to the corpse. The arrow, the
-- minimap button and the route's lines (window, world map, minimap) all lead
-- there along the walking path, ahead of any route, which carries on once
-- the player is alive again.

local _, ns = ...

local function XY(vec)
    if type(vec) ~= "table" and type(vec) ~= "userdata" then return nil end
    local x, y
    if vec.GetXY then
        local ok, a, b = pcall(vec.GetXY, vec)
        if ok then x, y = a, b end
    end
    if x == nil then x, y = vec.x, vec.y end
    return ns.Num(x), ns.Num(y)
end

local function Ghost()
    local ok, ghost = ns.Ask(ns.API(nil, "UnitIsGhost"), "player")
    return ok and ghost and ghost ~= 0 or false
end

-- The corpse and the player, both on their continent's map:
-- { c, cont, x, y, px, py, w, h }, or nil when the player is alive, or the
-- corpse is on another continent (or in a dungeon) the client won't place.
function ns.Corpse()
    if not Ghost() then return nil end
    local api = ns.API("C_DeathInfo", "GetCorpseMapPosition")
    for c, cont in pairs(ns.CONTINENT_YARDS or {}) do
        local px, py = ns.PlayerOn(cont.map)
        if px and px >= 0 and px <= 1 and py >= 0 and py <= 1 then
            local ok, vec = ns.Ask(api, cont.map)
            local x, y
            if ok then x, y = XY(vec) end
            if x and y and (x ~= 0 or y ~= 0) then
                return { c = c, cont = cont.map, x = x, y = y, px = px, py = py, w = cont.w, h = cont.h }
            end
        end
    end
    return nil
end

-- Bearing (radians counter-clockwise from north) and yards from the player
-- to the corpse: along the walking path once found, straight until then.
function ns.CorpseVector(corpse)
    corpse = corpse or ns.Corpse()
    if not corpse then return nil end
    local tx, ty, left = corpse.x, corpse.y, nil
    if ns.Steer then
        local ax, ay, rest = ns.Steer(corpse.c, { x = corpse.x, y = corpse.y }, corpse.px, corpse.py)
        if ax then tx, ty, left = ax, ay, rest end
    end
    local east = (tx - corpse.px) * corpse.w
    local north = -(ty - corpse.py) * corpse.h
    return math.atan2(-east, north), left or math.sqrt(east * east + north * north)
end

-- Dying, releasing and coming back: everything showing the way redraws.
local was = false
local function Check()
    local now = Ghost()
    if now == was then return end
    was = now
    ns.Fire("route")
end

local watch = CreateFrame("Frame")
for _, event in ipairs({ "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST", "PLAYER_ENTERING_WORLD" }) do
    pcall(watch.RegisterEvent, watch, event)
end
watch:SetScript("OnEvent", function() Check() end)
ns.On("login", Check)
