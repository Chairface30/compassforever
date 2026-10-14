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
    mapPins = false,       -- markers and the route bar on the world map
    worldMapGray = true,   -- covered areas drawn in gray on the world map
    areaBorders = true,    -- each area's outline drawn on the window's map
    doneAreaBorders = true, -- and the outlines of areas already uncovered
    minimapRoute = true,   -- the route drawn on the minimap too
    replaceWorldMap = false, -- the world map key opens this window instead
    mapOnly = false,       -- the window shows its map and nothing else
    autoRoute = false,     -- start a zone's route on entering it
    onTheWay = false,      -- a route to another zone clears the zones on the way first
    banner = true,         -- big words for a new route, an uncovered area
    fanfare = true,        -- music on finishing a zone
    learnFlights = true,   -- route past the zone's flight masters not yet learned
    autoFly = false,       -- take the planned flight as soon as the flight map opens
    editing = false,       -- the window's tools for walls, roads and zone lines
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

-- Route editing (walls, roads and zone lines) is for the addon's own
-- mapping, on its author's characters only: everyone else just gets the
-- lines built in. Forever names are "First Last" (UnitName gives the two
-- apart); the beta realm's have no surname.
local MAPPERS = {
    ["Beefstrokin Goff"] = true, ["Briaar Shadowfoot"] = true, ["Chairface Chippendale"] = true,
    ["Highley Regarded"] = true, ["Notte Sure"] = true, ["Salty Udders"] = true,
    ["Scrootie Mcboogrballs"] = true, ["Sewer Urchin"] = true,
    Chairface = true, Highley = true, Notte = true, Whitehot = true,
}
function ns.CanEdit()
    local ok, first, last = ns.Ask(_G.UnitName, "player")
    if not ok or type(first) ~= "string" then return false end
    local key = (type(last) == "string" and last ~= "") and (first .. " " .. last) or first
    return MAPPERS[key] and true or false
end

-- The editing tools are showing: turned on, by someone who may edit.
function ns.Editing()
    return ns.db and ns.db.editing and ns.CanEdit() or false
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
    -- whoever already drew or moved something keeps the tools showing
    if db.editing == nil then
        for _, key in ipairs({ "walls", "roads", "zonelines", "finished" }) do
            if type(db[key]) == "table" and next(db[key]) then db.editing = true end
        end
    end
    -- the world map markers went off by default with the area outlines:
    -- turned off once for everyone, then theirs to turn on again
    if not db.mapPinsOff then
        db.mapPins, db.mapPinsOff = false, true
    end
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

-------------------------------------------------------------------------------
-- Measuring (/cf perf): time and memory each part takes, while switched on
-------------------------------------------------------------------------------

ns.perf = nil

local function Clock()
    local f = _G.debugprofilestop
    return type(f) == "function" and f() or 0
end

function ns.PerfAdd(name, ms, kb)
    local p = ns.perf
    if not p then return end
    local e = p[name]
    if not e then
        e = { ms = 0, n = 0, kb = 0 }
        p[name] = e
    end
    e.ms, e.n = e.ms + ms, e.n + 1
    if kb > 0 then e.kb = e.kb + kb end
end

-- `fn`, timed under `name` while measuring.
function ns.Timed(name, fn)
    return function(...)
        if not ns.perf then return fn(...) end
        local t0, m0 = Clock(), collectgarbage("count")
        local a, b, c, d = fn(...)
        ns.PerfAdd(name, Clock() - t0, collectgarbage("count") - m0)
        return a, b, c, d
    end
end

-- A frame's OnUpdate, timed under `name`.
function ns.TimeUpdates(frame, name)
    local ok, fn = pcall(frame.GetScript, frame, "OnUpdate")
    if ok and type(fn) == "function" then frame:SetScript("OnUpdate", ns.Timed(name, fn)) end
end

function ns.Fire(message, ...)
    for _, fn in ipairs(listeners[message] or {}) do
        local t0, m0 = ns.perf and Clock(), ns.perf and collectgarbage("count")
        local ok, err = pcall(fn, ...)
        if not ok then ns.Print("|cffff5555" .. message .. ":|r", err) end
        if t0 then ns.PerfAdd("on " .. message, Clock() - t0, collectgarbage("count") - m0) end
    end
end

-- Several progress events can arrive in one frame (a discovery fires the
-- criteria update, the exploration update and the info message together):
-- one refresh, a moment later, covers them all.
local pending = false
local lastSignature
function ns.ProgressChanged()
    if pending then return end
    pending = true
    local after = ns.API("C_Timer", "After")
    local function run()
        pending = false
        ns.InvalidateProgress()
        -- the game sends these for every kill and quest step: only a change
        -- in what's uncovered (where you are, or on the route) or in the
        -- flight points known goes on to replan and redraw
        local sig = ns.ProgressSignature and ns.ProgressSignature()
        if sig and sig == lastSignature then return end
        lastSignature = sig
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
        if ns.SetupMinimapRoute then pcall(ns.SetupMinimapRoute) end
        ns.Fire("login")
        ns.ProgressChanged()
        return
    end
    ns.ProgressChanged()
end)
