-- Compass Forever: Progress.lua
-- Which parts of each zone map are uncovered, read from the client.
--
-- Each "Explore <zone>" achievement has one criterion per part of the
-- zone's map; when a criterion cannot be read, the map's own list of uncovered
-- art (C_MapExplorationInfo) is asked instead.
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
        local ok, list = ns.Ask(ns.API("C_MapExplorationInfo", "GetExploredMapTextures"), mapID)
        if not ok or type(list) ~= "table" then return nil end
        local seen = {}
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
        local crit = Criteria(zone.ach)
        if crit then
            local byID = {}
            for _, c in ipairs(crit) do
                if c.id then byID[c.id] = c.done end
                if c.asset then byID["o" .. c.asset] = c.done end
            end
            for i, node in ipairs(zone.nodes) do
                local done = byID[node.criteria]
                if done == nil then done = byID["o" .. node.overlay] end
                state[i] = done
            end
            source = "achievement"
        end
        -- Whatever the criteria left unknown, the map may know.
        local art = ExploredArt(zone.map)
        if art then
            -- The map's list is trusted only where it matches the data: some
            -- uncovered art of this zone found at a node's spot.
            local matches = false
            for _, node in ipairs(zone.nodes) do
                if node.ox and art[node.ox .. ":" .. node.oy] then
                    matches = true
                    break
                end
            end
            for i, node in ipairs(zone.nodes) do
                if state[i] == nil and node.ox then
                    state[i] = art[node.ox .. ":" .. node.oy] == true
                    source = source or "map"
                elseif state[i] == false and node.ox and art[node.ox .. ":" .. node.oy] then
                    state[i] = true      -- the map has caught up first
                elseif state[i] == true and matches and node.ox and not art[node.ox .. ":" .. node.oy] then
                    -- The criterion is ticked but the map still has the gap:
                    -- the achievement can name an older overlay with more
                    -- areas than the map's (Razorwind Canyon ticks Drygulch
                    -- Ravine), so the area stays on the route until the map
                    -- shows it.
                    state[i] = false
                end
            end
        end
        return { state = state, source = source }
    end)
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

-- The nodes still to uncover. Unknown ones are included: a spot already
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
