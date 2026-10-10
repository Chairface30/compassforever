-- Compass Forever: Core.lua
-- Settings, events and the helpers every file shares.
--
-- Built for WoW Forever. Every read of a client value goes through a pcall and
-- an issecretvalue check: a value the addon cannot read counts as unknown,
-- never as a guess.

local addonName, ns = ...
ns.addonName = addonName
ns.title = "Compass Forever"

local DEFAULTS = {
    window = {},           -- the main window's spot
    arrow = {},            -- the arrow's spot
    arrowScale = 1,
    mapPins = true,        -- markers and the route bar on the world map
    autoRoute = false,     -- start a zone's route on entering it
    banner = true,         -- big words for a new route, an uncovered area
    learnFlights = true,   -- route past flight masters not yet learned, when close
    autoFly = false,       -- take the planned flight as soon as the flight map opens
    minimap = {},          -- LibDBIcon's own settings
}

function ns.Print(...)
    local parts = { "|cff66ccffCompass Forever|r:" }
    for i = 1, select("#", ...) do
        local value = (select(i, ...))
        local ok, text = pcall(function() return "" .. tostring(value) end)
        parts[#parts + 1] = ok and text or "<unreadable>"
    end
    print(table.concat(parts, " "))
end

function ns.Secret(value)
    local check = _G.issecretvalue
    if type(check) ~= "function" then return false end
    local ok, secret = pcall(check, value)
    return ok and secret and true or false
end

-- A client call that may be missing, may throw, or may answer in secrets.
-- Gives back its results only when they are all readable.
function ns.Ask(fn, ...)
    if type(fn) ~= "function" then return false end
    local results = { pcall(fn, ...) }
    if not results[1] then return false end
    for i = 2, #results do
        if ns.Secret(results[i]) then return false end
    end
    return unpack(results)
end

function ns.Num(v)
    if ns.Secret(v) then return nil end
    return type(v) == "number" and v or nil
end

function ns.Text(v)
    if ns.Secret(v) then return nil end
    return type(v) == "string" and v or nil
end

-- C_Something.Fn, looked up when it is used.
function ns.API(space, name)
    local tbl = space and _G[space] or _G
    local fn = type(tbl) == "table" and tbl[name]
    return type(fn) == "function" and fn or nil
end

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------

function ns.LoadSettings()
    if type(CompassForeverDB) ~= "table" then CompassForeverDB = {} end
    local db = CompassForeverDB
    for key, value in pairs(DEFAULTS) do
        if db[key] == nil then
            db[key] = type(value) == "table" and {} or value
        end
    end
    ns.db = db
    return db
end

function ns.SavePoint(frame, store)
    local point, _, relPoint, x, y = frame:GetPoint(1)
    if type(point) ~= "string" then return end
    store.point, store.relPoint, store.x, store.y = point, relPoint or point, x, y
end

function ns.RestorePoint(frame, store, point, relPoint, x, y)
    frame:ClearAllPoints()
    local ok = store.point and pcall(frame.SetPoint, frame, store.point, UIParent,
        store.relPoint or store.point, store.x or 0, store.y or 0)
    if not ok then
        frame:ClearAllPoints()
        frame:SetPoint(point, UIParent, relPoint, x, y)
    end
end

-------------------------------------------------------------------------------
-- Messages between files
-------------------------------------------------------------------------------
-- "progress":  something a map area depends on changed.
-- "route":     the route or its current step changed.
-- "uncovered": (zone, nodes) areas the route was heading for are uncovered.
-- "settings":  a setting changed.

local listeners = {}

function ns.On(message, fn)
    listeners[message] = listeners[message] or {}
    table.insert(listeners[message], fn)
end

function ns.Fire(message, ...)
    for _, fn in ipairs(listeners[message] or {}) do
        local ok, err = pcall(fn, ...)
        if not ok then ns.Print("|cffff5555" .. message .. ":|r", err) end
    end
end

-- Several progress events can arrive in one frame (a discovery fires the
-- criteria update, the exploration update and the info message together):
-- one refresh, a moment later, covers them all.
local pending = false
function ns.ProgressChanged()
    if pending then return end
    pending = true
    local after = ns.API("C_Timer", "After")
    local function run()
        pending = false
        ns.InvalidateProgress()
        ns.Fire("progress")
    end
    if after then after(0.3, run) else run() end
end

-------------------------------------------------------------------------------
-- Boot
-------------------------------------------------------------------------------

local PROGRESS_EVENTS = { "CRITERIA_UPDATE", "ACHIEVEMENT_EARNED", "MAP_EXPLORATION_UPDATED" }

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == addonName then ns.LoadSettings() end
        return
    end
    if event == "PLAYER_LOGIN" then
        if not ns.db then ns.LoadSettings() end
        -- Not every client has every event, and registering an unknown one
        -- throws: each is tried on its own.
        for _, name in ipairs(PROGRESS_EVENTS) do pcall(boot.RegisterEvent, boot, name) end
        if ns.SetupMinimap then pcall(ns.SetupMinimap) end
        ns.Fire("login")
        ns.ProgressChanged()
        return
    end
    ns.ProgressChanged()
end)
