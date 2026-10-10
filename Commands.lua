-- Compass Forever: Commands.lua
-- /cf and /compassforever (and /legacy, its first name).

local _, ns = ...

local function ZoneFromText(text)
    if not text or text == "" then return ns.CurrentZone() end
    text = text:lower()
    for _, zone in ipairs(ns.ZONES) do
        if zone.name:lower() == text then return zone end
    end
    for _, zone in ipairs(ns.ZONES) do
        if zone.name:lower():find(text, 1, true) then return zone end
    end
    return nil
end

-- What /cf probe prints: the functions this relies on, what they say
-- about the zone the player is in, and whether the map's uncovered art lines
-- up with the built-in data. This is what to send back when something is off.
local function Probe()
    ns.Print("probe:")
    local names = {
        { nil, "GetAchievementInfo" }, { nil, "GetAchievementNumCriteria" },
        { nil, "GetAchievementCriteriaInfo" }, { "C_MapExplorationInfo", "GetExploredMapTextures" },
        { "C_Map", "GetBestMapForUnit" }, { "C_Map", "GetPlayerMapPosition" },
        { "C_Map", "GetWorldPosFromMapPos" }, { "C_GameRules", "IsHardcoreActive" },
        { nil, "GetPlayerFacing" },
    }
    for _, pair in ipairs(names) do
        print(string.format("  %s%s = %s", pair[1] and (pair[1] .. ".") or "", pair[2],
            ns.API(pair[1], pair[2]) and "|cff55ff55yes|r" or "|cffff5555missing|r"))
    end
    local ad, at, zd, zt = ns.Totals()
    print(string.format("  explored: %d of %d areas, %d of %d zones; auto-route %s", ad, at, zd, zt,
        ns.db.autoRoute and "on" or "off"))

    local zone = ZoneFromText()
    print("  player map = " .. tostring(ns.PlayerMap()) .. ", zone = " .. tostring(zone and zone.name))
    if not zone then return end
    local px, py = ns.PlayerOn(zone.map)
    print(string.format("  position = %s", px and string.format("%.1f, %.1f", px * 100, py * 100) or "unknown"))
    local info = ns.AchInfo(zone.ach)
    print(string.format("  achievement %d: %s", zone.ach,
        info and ((info.name or "?") .. (info.completed and " (complete)" or "")) or "|cffff5555unreadable|r"))
    local crit = ns.Criteria(zone.ach)
    if crit then
        local matched = 0
        for _, c in ipairs(crit) do
            for _, node in ipairs(zone.nodes) do
                if node.criteria == c.id or node.overlay == c.asset then matched = matched + 1 break end
            end
        end
        print(string.format("  criteria: %d read, %d match the built-in areas (of %d)", #crit, matched, #zone.nodes))
        local c = crit[1]
        if c then
            print(string.format("    first: %s done=%s id=%s asset=%s", tostring(c.name), tostring(c.done),
                tostring(c.id), tostring(c.asset)))
        end
    else
        print("  criteria: |cffff5555unreadable|r")
    end
    local ok, list = ns.Ask(ns.API("C_MapExplorationInfo", "GetExploredMapTextures"), zone.map)
    if ok and type(list) == "table" then
        local known = {}
        for _, node in ipairs(zone.nodes) do known[node.ox .. ":" .. node.oy] = node.name end
        local hit = 0
        for _, t in ipairs(list) do
            if known[tostring(ns.Num(t.offsetX)) .. ":" .. tostring(ns.Num(t.offsetY))] then hit = hit + 1 end
        end
        print(string.format("  map art uncovered: %d pieces, %d match the built-in areas", #list, hit))
    else
        print("  map art uncovered: |cffff5555unreadable|r")
    end
    local d, t, u = ns.ZoneCounts(zone)
    print(string.format("  result: %d of %d areas uncovered, %d unknown (from %s)", d, t, u,
        tostring(ns.ZoneState(zone).source)))
    local g = ns.Grid and ns.Grid(zone)
    print("  terrain: " .. (g and string.format("%dx%d points", g.nx, g.ny) or "|cffff5555none|r"))
    local known = 0
    for _ in pairs(ns.KnownFlights and ns.KnownFlights() or {}) do known = known + 1 end
    print(string.format("  flight points known on this character: %d%s", known,
        known == 0 and " (open any flight map once to fill this in)" or ""))
    print("  UnitOnTaxi = " .. (ns.API(nil, "UnitOnTaxi") and "|cff55ff55yes|r" or "|cffff5555missing|r")
        .. ", C_TaxiMap.GetAllTaxiNodes = "
        .. (ns.API("C_TaxiMap", "GetAllTaxiNodes") and "|cff55ff55yes|r" or "|cffff5555missing|r"))
    if ns.travel then print("  travel: " .. (ns.TravelText() or "")) end
end

local function Help()
    ns.Print("commands:")
    print("  /cf - open or close the window")
    print("  /cf route [zone] - walk the shortest route through the zone's covered areas (default: this zone)")
    print("  /cf auto - route automatically on entering a zone, on or off")
    print("  /cf next - say the next stop in chat")
    print("  /cf skip - leave the current stop for the end of the route")
    print("  /cf stop - stop the route")
    print("  /cf banner - the big on-screen messages, on or off")
    print("  /cf arrow <0.5-2> - size of the arrow")
    print("  /cf probe - what the client says; send this when something looks wrong")
end

SLASH_COMPASSFOREVER1 = "/cf"
SLASH_COMPASSFOREVER2 = "/compassforever"
SLASH_COMPASSFOREVER3 = "/legacy"
SlashCmdList.COMPASSFOREVER = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if cmd == "" then
        ns.ToggleWindow()
    elseif cmd == "route" or cmd == "go" then
        local zone = ZoneFromText(rest)
        if not zone then
            ns.Print(rest ~= "" and ("No zone called \"" .. rest .. "\".") or "This zone has no map to explore.")
            return
        end
        ns.InvalidateProgress()
        ns.StartRoute(zone)
        local text = ns.NextStopText()
        if text then ns.Print(text .. ".") end
    elseif cmd == "next" then
        local stop, i = ns.CurrentStop()
        if not stop then ns.Print("No route.") return end
        local _, yards = ns.StopVector(ns.route.zone, stop)
        ns.Print(string.format("stop %d of %d: %s at %.1f, %.1f%s", i, #ns.route.stops, stop.node.name,
            stop.x * 100, stop.y * 100, type(yards) == "number" and (" (" .. ns.Yards(yards) .. ")") or ""))
    elseif cmd == "skip" then
        ns.SkipStop()
    elseif cmd == "stop" then
        ns.StopRoute()
    elseif cmd == "auto" then
        ns.SetAutoRoute(not ns.db.autoRoute)
        ns.Print("automatic routes " .. (ns.db.autoRoute and "on" or "off") .. ".")
    elseif cmd == "banner" then
        ns.db.banner = not ns.db.banner
        ns.Print("on-screen messages " .. (ns.db.banner and "on" or "off") .. ".")
    elseif cmd == "arrow" then
        local n = tonumber(rest)
        if n then
            ns.db.arrowScale = math.max(0.5, math.min(2, n))
            ns.ApplyArrowScale()
        end
        ns.Print("arrow size " .. ns.db.arrowScale)
    elseif cmd == "probe" then
        ns.InvalidateProgress()
        Probe()
    else
        Help()
    end
end
