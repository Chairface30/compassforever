-- Chair Legacy: Auto.lua
-- With "Route me automatically" on: entering a zone that still has covered
-- areas starts its route and says where to run. Leaving it ends that route.
-- A route the player started themself is left alone until they stop it.

local _, ns = ...

local lastZone

local function Check()
    local zone = ns.CurrentZone()
    if zone == lastZone then return end
    lastZone = zone
    local r = ns.route
    if r and r.auto and r.zone ~= zone then ns.StopRoute() end
    if not (ns.db.autoRoute and zone) then return end
    if ns.route and ns.route.zone == zone then return end
    if ns.route and not ns.route.auto then return end     -- the player's own
    local d, t = ns.ZoneCounts(zone)
    if d == t then return end
    if ns.StartRoute(zone, { quiet = true, auto = true }) then
        ns.Banner(string.format("%s: %d area%s to uncover", zone.name, t - d, t - d == 1 and "" or "s"),
            ns.NextStopText())
    end
end

local driver = CreateFrame("Frame")
for _, event in ipairs({ "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "PLAYER_ENTERING_WORLD" }) do
    pcall(driver.RegisterEvent, driver, event)
end
driver:SetScript("OnEvent", function()
    -- The map catches up a moment after the event.
    local after = ns.API("C_Timer", "After")
    if after then after(1, function() pcall(Check) end) else pcall(Check) end
end)

-- Turning it on in a zone with work to do starts right away.
function ns.SetAutoRoute(on)
    ns.db.autoRoute = on and true or false
    lastZone = nil
    if on then pcall(Check) end
    ns.Fire("settings")
end

ns.AutoCheck = Check
