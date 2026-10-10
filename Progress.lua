-- Chair Legacy: Progress.lua
-- What is done and what is left, read from the client.
--
-- The Legacy challenges are achievements: the game's own Legacy window reads
-- them with GetAchievementInfo and GetAchievementCriteriaInfo, and so does
-- this. Each "Explore <zone>" achievement has one criterion per part of the
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
-- Legacy challenges
-------------------------------------------------------------------------------

-- Hardcore realms have their own set of challenges.
local function Hardcore()
    local fn = ns.API("C_GameRules", "IsHardcoreActive")
    local ok, hc = ns.Ask(fn)
    return ok and hc == true
end

function ns.ChallengeList()
    return Hardcore() and ns.CHALLENGES_HARDCORE or ns.CHALLENGES
end

-- A challenge as it stands: { def, done (true/false/nil = unknown), steps }.
-- Each step: { name, done, qty, req }.
function ns.Challenge(def)
    local info = AchInfo(def.id)
    local crit = Criteria(def.id)
    local steps = {}
    if crit then
        for i, c in ipairs(crit) do
            steps[i] = { name = c.name or def.steps[i] or "?", done = c.done, qty = c.qty, req = c.req }
        end
    else
        for i, name in ipairs(def.steps) do steps[i] = { name = name } end
    end
    return {
        def = def,
        name = (info and info.name) or def.name,
        text = (info and info.text) or def.text,
        done = info and info.completed or nil,
        steps = steps,
    }
end

-- How many challenges are done, out of how many, and how many are unknown.
function ns.ChallengeCounts(category)
    local done, total, unknown = 0, 0, 0
    for _, def in ipairs(ns.ChallengeList()) do
        if not category or def.category == category then
            total = total + 1
            local info = AchInfo(def.id)
            if not info then unknown = unknown + 1
            elseif info.completed then done = done + 1 end
        end
    end
    return done, total, unknown
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
            for i, node in ipairs(zone.nodes) do
                if state[i] == nil and node.ox then
                    state[i] = art[node.ox .. ":" .. node.oy] == true
                    source = source or "map"
                elseif state[i] == false and node.ox and art[node.ox .. ":" .. node.oy] then
                    state[i] = true      -- the map has caught up first
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
