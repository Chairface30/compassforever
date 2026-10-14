-- Compass Forever: Progress.lua
-- Which parts of each zone map are uncovered, read from the client.
--
-- Uncovering is per character: the map's own list of uncovered art
-- (C_MapExplorationInfo) is what this character has found. A map with
-- nothing uncovered gives back no list at all, which is "none", not
-- "unknown". The "Explore <zone>" achievements are account-wide, so their
-- criteria show areas another character uncovered: they're asked only for
-- what the map can't answer, and a criterion done counts only once this
-- character has the achievement itself.
--
-- Answers are cached until something that could change them happens
-- (ns.ProgressChanged in Core.lua).

local _, ns = ...

local cache = {}

function ns.InvalidateProgress()
    cache = {}
end

local function Cached(key, build)
    local v = cache[key]
    if v == nil then
        v = build() or false
        cache[key] = v
    end
    return v or nil
end

-------------------------------------------------------------------------------
-- Achievements
-------------------------------------------------------------------------------

-- id, name, completed (account), earned by this character; nil if unreadable.
local function AchInfo(id)
    return Cached("a" .. id, function()
        local ok, aid, name, _, completed, _, _, _, desc, _, _, _, _, mine =
            ns.Ask(_G.GetAchievementInfo, id)
        if not ok or ns.Num(aid) ~= id then return nil end
        return { name = ns.Text(name), text = ns.Text(desc),
                 completed = completed and true or false, mine = mine and true or false }
    end)
end
ns.AchInfo = AchInfo

-- Every criterion of an achievement: name, done, quantity, needed, ID, asset.
local function Criteria(id)
    return Cached("c" .. id, function()
        local okN, n = ns.Ask(_G.GetAchievementNumCriteria, id)
        n = okN and ns.Num(n)
        if not n then return nil end
        local list = {}
        for i = 1, n do
            local ok, name, _, done, qty, req, _, _, asset, _, criteriaID =
                ns.Ask(_G.GetAchievementCriteriaInfo, id, i)
            if not ok then return nil end
            list[i] = { name = ns.Text(name), done = done and true or false,
                        qty = ns.Num(qty), req = ns.Num(req),
                        id = ns.Num(criteriaID), asset = ns.Num(asset) }
        end
        return list
    end)
end
ns.Criteria = Criteria

function ns.HasAchievementAPI()
    return type(_G.GetAchievementInfo) == "function"
        and type(_G.GetAchievementCriteriaInfo) == "function"
end

-------------------------------------------------------------------------------
-- Exploration
-------------------------------------------------------------------------------

-- Overlays the map shows as uncovered on this character, keyed "x:y" by the
-- art's offset, which is how the map hands them back.
local function ExploredArt(mapID)
    return Cached("m" .. mapID, function()
        local fn = ns.API("C_MapExplorationInfo", "GetExploredMapTextures")
        if not fn then return nil end
        local ok, list = ns.Ask(fn, mapID)
        if not ok then return nil end
        local seen = {}
        -- no list: nothing on this map uncovered yet
        if type(list) ~= "table" then return seen end
        for _, info in ipairs(list) do
            local x, y = ns.Num(info.offsetX), ns.Num(info.offsetY)
            if x and y then seen[x .. ":" .. y] = true end
        end
        return seen
    end)
end

-- Per node of a zone: true (uncovered), false (still to do) or nil (unknown).
-- Returns the table and where the answer came from.
function ns.ZoneState(zone)
    return Cached("z" .. zone.ach, function()
        local state, source = {}, nil
        -- This character's map first: every node with art is answered by it.
        local art = ExploredArt(zone.map)
        if art then
            for i, node in ipairs(zone.nodes) do
                if node.ox then state[i] = art[node.ox .. ":" .. node.oy] == true end
            end
            source = "map"
        end
        -- Only what the map left unknown from the account-wide criteria.
        local crit = Criteria(zone.ach)
        local info = AchInfo(zone.ach)
        local mine = info and info.mine
        if crit then
            local byID = {}
            for _, c in ipairs(crit) do
                if c.id then byID[c.id] = c.done end
                if c.asset then byID["o" .. c.asset] = c.done end
            end
            for i, node in ipairs(zone.nodes) do
                if state[i] == nil then
                    local done = byID[node.criteria]
                    if done == nil then done = byID["o" .. node.overlay] end
                    -- done by some character of the account, maybe not this one
                    if done == true and not mine then done = nil end
                    state[i] = done
                    if done ~= nil then source = source or "achievement" end
                end
            end
        end
        return { state = state, source = source }
    end)
end

-- What a progress refresh depends on, as text: the areas of the zone you're
-- in and of the route's zone, and the flight points known.
function ns.ProgressSignature()
    local parts = {}
    local seen = {}
    for _, zone in ipairs({ ns.CurrentZone() or false, ns.route and ns.route.zone or false }) do
        if zone and not seen[zone] then
            seen[zone] = true
            local s = ns.ZoneState(zone).state
            parts[#parts + 1] = zone.ach .. "="
            for i = 1, #zone.nodes do parts[#parts + 1] = s[i] == true and "1" or s[i] == false and "0" or "?" end
        end
    end
    local known = 0
    for _ in pairs(ns.KnownFlights and ns.KnownFlights() or {}) do known = known + 1 end
    parts[#parts + 1] = "f" .. known
    return table.concat(parts)
end

-- done, total, unknown for one zone.
function ns.ZoneCounts(zone)
    local s = ns.ZoneState(zone).state
    local done, unknown = 0, 0
    for i = 1, #zone.nodes do
        if s[i] == true then done = done + 1 elseif s[i] == nil then unknown = unknown + 1 end
    end
    return done, #zone.nodes, unknown
end

-- The nodes still to uncover. Unknown ones are included: an area already
-- uncovered costs a walk past, a missed one costs the achievement.
function ns.ZoneRemaining(zone)
    local s = ns.ZoneState(zone).state
    local out = {}
    for i, node in ipairs(zone.nodes) do
        if s[i] ~= true then out[#out + 1] = node end
    end
    return out
end

function ns.ZoneByMap(mapID)
    for _, zone in ipairs(ns.ZONES) do
        if zone.map == mapID then return zone end
    end
    return nil
end

function ns.ZoneByAch(id)
    for _, zone in ipairs(ns.ZONES) do
        if zone.ach == id then return zone end
    end
    return nil
end

-- The zone the player is in: their map, or the zone above it (a city, a
-- subzone map). nil in an instance or anywhere without a zone map to explore.
function ns.CurrentZone()
    local here = ns.PlayerMap()
    for _ = 1, 5 do
        if not here then return nil end
        local zone = ns.ZoneByMap(here)
        if zone then return zone end
        local ok, info = ns.Ask(ns.API("C_Map", "GetMapInfo"), here)
        here = ok and type(info) == "table" and ns.Num(info.parentMapID) or nil
    end
    return nil
end

-- Areas and zones uncovered, over every zone or one continent.
function ns.Totals(continent)
    local areas, areasDone, zones, zonesDone = 0, 0, 0, 0
    for _, zone in ipairs(ns.ZONES) do
        if not continent or zone.continent == continent then
            local d, t = ns.ZoneCounts(zone)
            areas, areasDone, zones = areas + t, areasDone + d, zones + 1
            if d == t then zonesDone = zonesDone + 1 end
        end
    end
    return areasDone, areas, zonesDone, zones
end
