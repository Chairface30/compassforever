# Compass Forever in a stand-in client (needs: pip install lupa)
#   python tests/addon_test.py
#
# The harness is kinder than the client: it proves the logic, not that the
# client will hand these values over. That is what /cf probe is for.
import io, itertools, math, os, re, sys
from lupa import lua51

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

failures = []


def check(name, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + name + ("" if cond else f"  {detail}"))
    if not cond:
        failures.append(name)


HARNESS = r'''
NOW = 100
function GetTime() return NOW end
CURSOR = { 300, 200 }
function GetCursorPosition() return CURSOR[1], CURSOR[2] end
SOUNDS = {}
HAVE_FANFARE = false
function PlaySoundFile(path, channel)
    table.insert(SOUNDS, path)
    return HAVE_FANFARE and path:find("fanfare") ~= nil
end
function PlaySound(id) table.insert(SOUNDS, id) end
SECRET = setmetatable({}, { __tostring = function() return "SECRET" end })
function issecretvalue(v) return v == SECRET end
PRINTED = {}
function print(...) local t = {} for i = 1, select("#", ...) do t[#t+1] = tostring((select(i, ...))) end table.insert(PRINTED, table.concat(t, " ")) end
tinsert = table.insert
unpack = unpack or table.unpack
UISpecialFrames = {}
SlashCmdList = {}
function hooksecurefunc() end
GameTooltip = setmetatable({}, { __index = function() return function() end end })

FRAMES, LINES = {}, {}
local function Widget(kind)
    local w = { _events = {}, _scripts = {}, _kind = kind }
    return setmetatable(w, { __index = function(self, key)
        if key == "RegisterEvent" then return function(s, e) s._events[e] = true end
        elseif key == "SetScript" then return function(s, n, f) s._scripts[n] = f end
        elseif key == "HookScript" then return function(s, n, f) s._scripts[n] = f end
        elseif key == "CreateTexture" or key == "CreateFontString" then return function()
            local r = Widget("region") table.insert(FRAMES, r) return r end
        elseif key == "SetText" then return function(s, t) rawset(s, "_text", t) end
        elseif key == "SetChecked" then return function(s, v) rawset(s, "_checked", v) end
        elseif key == "GetChecked" then return function(s) return rawget(s, "_checked") end
        elseif key == "Show" then return function(s) rawset(s, "_shown", true) end
        elseif key == "Hide" then return function(s) rawset(s, "_shown", false) end
        elseif key == "IsShown" then return function(s) return rawget(s, "_shown") == true end
        elseif key == "GetWidth" then return function(s) return rawget(s, "_w") or 1000 end
        elseif key == "GetHeight" then return function(s) return rawget(s, "_h") or 1000 end
        elseif key == "SetSize" then return function(s, w, h) rawset(s, "_w", w) rawset(s, "_h", h) end
        elseif key == "GetLeft" then return function() return 0 end
        elseif key == "GetTop" then return function() return 400 end
        elseif key == "IsMouseOver" then return function() return true end
        elseif key == "GetEffectiveScale" then return function(s) return rawget(s, "_eff") or 1 end
        elseif key == "GetFrameLevel" then return function() return 1 end
        elseif key == "SetScale" then return function(s, v) rawset(s, "_scale", v) end
        elseif key == "SetFrameLevel" then return function(s, v) rawset(s, "_level", v) end
        elseif key == "SetDesaturated" then return function(s, v) rawset(s, "_gray", v) end
        elseif key == "SetTexture" then return function(s, v) rawset(s, "_tex", v) end
        elseif key == "GetScale" then return function(s) return rawget(s, "_scale") or 1 end
        elseif key == "SetPoint" then return function(s, ...) rawset(s, "_point", { ... }) end
        elseif key == "CreateLine" then return function() local r = Widget("line") table.insert(LINES, r) return r end
        elseif key == "GetPoint" then return function() return "CENTER", nil, "CENTER", 0, 0 end
        end
        return function() end
    end })
end
function CreateFrame(kind, name, parent, template)
    local f = Widget(kind)
    rawset(f, "_shown", true)
    table.insert(FRAMES, f)
    if name then _G[name] = f end
    return f
end
UIParent = CreateFrame("Frame")

function FIRE(event, ...)
    for _, f in ipairs(FRAMES) do
        if f._events[event] and f._scripts.OnEvent then f._scripts.OnEvent(f, event, ...) end
    end
end

AFTER = {}
C_Timer = { After = function(d, fn) table.insert(AFTER, fn) end }
function FLUSH() local list = AFTER AFTER = {} for _, fn in ipairs(list) do fn() end end

-- The player: which map, where on it, and facing (radians ccw from north).
PLAYER = { map = 1429, x = 0.42, y = 0.65, facing = 0 }
function GetPlayerFacing() return PLAYER.facing end
C_Map = {
    GetBestMapForUnit = function() return PLAYER.map end,
    GetPlayerMapPosition = function(map)
        if map ~= PLAYER.map then return nil end
        return { x = PLAYER.x, y = PLAYER.y }
    end,
    GetMapInfo = function(map) return { mapID = map, name = "Map " .. map, parentMapID = 0 } end,
    GetMapArtLayers = function() return { { layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256 } } end,
    GetMapArtLayerTextures = function() local t = {} for i = 1, 12 do t[i] = 1000 + i end return t end,
}

-- Achievements: DONE[criteriaID] = true marks a criterion done.
ACH_API = true
DONE = {}
EARNED = {}
function GetAchievementInfo(id)
    if not ACH_API then error("missing") end
    local def = ACH_BY_ID[id]
    if not def then return nil end
    return id, def.name, 10, EARNED[id] or false, nil, nil, nil, def.text or "", 0, 0, "", false, EARNED[id] or false
end
function GetAchievementNumCriteria(id)
    if not ACH_API then error("missing") end
    local def = ACH_BY_ID[id]
    return def and #def.crit or 0
end
function GetAchievementCriteriaInfo(id, i)
    if not ACH_API then error("missing") end
    local c = ACH_BY_ID[id].crit[i]
    return c.name, 43, DONE[c.id] or false, DONE[c.id] and 1 or 0, 1, nil, 0, c.asset, "", c.id, true
end

-- The map's uncovered art: EXPLORED[map] = { { offsetX, offsetY } ... }
EXPLORED = {}
C_MapExplorationInfo = { GetExploredMapTextures = function(map)
    local out = {}
    for _, o in ipairs(EXPLORED[map] or {}) do
        out[#out + 1] = { offsetX = o[1], offsetY = o[2], textureWidth = 300, textureHeight = 200,
            numTexturesWide = 2, numTexturesTall = 1, fileDataIDs = { 2001, 2002 } }
    end
    return out
end }

DBICON = { registered = {} }
local LDB = {}
function LDB:NewDataObject(name, obj) return obj end
function DBICON:Register(name, obj, db) self.registered[name] = obj end
function LibStub(name) return name == "LibDataBroker-1.1" and LDB or name == "LibDBIcon-1.0" and DBICON or nil end
WorldMapFrame = CreateFrame("Frame")
WorldMapFrame.ScrollContainer = CreateFrame("Frame")
WorldMapFrame.ScrollContainer.Child = CreateFrame("Frame")
SHOWN_MAP = 1429
WorldMapFrame.GetMapID = function() return SHOWN_MAP end
PIN_LEVELS = { PIN_FRAME_LEVEL_MAP_EXPLORATION = 1990, PIN_FRAME_LEVEL_TOPMOST = 2150 }
WorldMapFrame.GetPinFrameLevelsManager = function()
    return { GetValidFrameLevel = function(_, kind) return PIN_LEVELS[kind] or 2000 end }
end
-- On a continent every point is "Westfall"; on Azeroth every point is
-- Kalimdor. Each zone sits in a tenth of its continent.
C_Map.GetMapInfoAtPosition = function(map, x, y)
    if map == 1415 or map == 1414 then return { mapID = 1436 } end
    if map == 947 then return { mapID = 1414 } end
end
RECTS = {
    ["1429:1415"] = { 0.40, 0.50, 0.70, 0.80 },   -- Elwynn on Eastern Kingdoms
    ["1436:1415"] = { 0.30, 0.40, 0.72, 0.82 },   -- Westfall, just west of it
    ["1415:947"] = { 0.50, 1.00, 0.00, 1.00 },
}
C_Map.GetMapRectOnMap = function(map, on)
    local r = RECTS[map .. ":" .. on]
    if r then return r[1], r[2], r[3], r[4] end
    return 0.4, 0.5, 0.4, 0.5
end
local ownPos = C_Map.GetPlayerMapPosition
C_Map.GetPlayerMapPosition = function(map)
    if map == PLAYER.map then return ownPos(map) end
    local r = RECTS[PLAYER.map .. ":" .. map]
    if r then return { x = r[1] + PLAYER.x * (r[2] - r[1]), y = r[3] + PLAYER.y * (r[4] - r[3]) } end
end
C_Map.GetMapHighlightInfoAtPosition = function() return 5555, nil, 1, 1, 0.1, 0.1, 0.4, 0.4 end

-- Mark every line hidden, so a check counts only what is drawn after.
function HIDE_LINES() for _, l in ipairs(LINES) do rawset(l, "_shown", false) end end

-- One frame of every OnUpdate script.
function FRAME(dt)
    for _, f in ipairs(FRAMES) do
        local fn = f._scripts.OnUpdate
        if fn and rawget(f, "_shown") ~= false then fn(f, dt or 0.05) end
    end
end

-- Every text a font string was given.
function TEXTS()
    local out = {}
    for _, f in ipairs(FRAMES) do local t = rawget(f, "_text") if type(t) == "string" then out[#out + 1] = t end end
    return table.concat(out, "\n")
end
-- The banner's title font string.
function BANNER_TITLE()
    for _, f in ipairs(FRAMES) do
        local t = rawget(f, "_text")
        if type(t) == "string" and (t:find("^Uncovered") or t:find("to uncover$")) then return f end
    end
    return {}
end
'''

TOC = [l.strip() for l in io.open("CompassForever.toc", encoding="utf-8")
       if l.strip() and not l.startswith("#") and not l.startswith("Libs")]


def boot():
    rt = lua51.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(HARNESS)
    rt.execute("NS = {}")
    for path in TOC:
        src = io.open(path, encoding="utf-8").read()
        fn = rt.eval("function(src, name) local f, err = loadstring(src, name) if not f then error(err) end return f end")(src, path)
        fn("CompassForever", rt.globals().NS)
    # The stand-in achievements: every zone, criteria from the built-in data.
    rt.execute('''
        ACH_BY_ID = {}
        for _, z in ipairs(NS.ZONES) do
            local crit = {}
            for i, n in ipairs(z.nodes) do crit[i] = { name = n.name, id = n.criteria, asset = n.overlay } end
            ACH_BY_ID[z.ach] = { name = "Explore " .. z.name, crit = crit }
        end
    ''')
    rt.execute("FIRE('ADDON_LOADED', 'CompassForever') FIRE('PLAYER_LOGIN') FLUSH()")
    return rt


def printed(rt):
    return list(rt.globals().PRINTED.values())


print("files")
for path in TOC:
    check(f"{path} exists", os.path.exists(path))

print("load")
rt = boot()
NS = rt.globals().NS
check("loads and logs in without an error", not any("|cffff5555" in p for p in printed(rt)), printed(rt))
check("slash command registered", rt.eval("SlashCmdList.COMPASSFOREVER ~= nil"))
check("minimap button registered", rt.eval("DBICON.registered.CompassForever ~= nil"))

print("data")
zones = rt.eval("#NS.ZONES")
nodes = rt.eval("(function() local n = 0 for _, z in ipairs(NS.ZONES) do n = n + #z.nodes end return n end)()")
check("43 zones", zones == 43, zones)
check("549 map areas", nodes == 549, nodes)
check("every point on its zone's map", rt.eval('''(function()
    for _, z in ipairs(NS.ZONES) do for _, n in ipairs(z.nodes) do
        if #n.points < 2 or #n.points % 2 ~= 0 then return false end
        for _, v in ipairs(n.points) do if v < 0 or v > 10000 then return false end end
    end end return true end)()'''))
check("only Undercity is approximate", rt.eval('''(function()
    local r = {} for _, z in ipairs(NS.ZONES) do for _, n in ipairs(z.nodes) do
        if n.rough then r[#r + 1] = n.name end end end
    return table.concat(r, ",") end)()''') == "Undercity")
# Known spots, checked against the game's own map: Goldshire, Razor Hill,
# Far Watch Post, Kormek's Hut.
for zone, area, x, y in (("Elwynn Forest", "Goldshire", 42.5, 65.5), ("Durotar", "Razor Hill", 52.5, 42.5),
                         ("The Barrens", "Far Watch Post", 62.0, 19.5), ("Desolace", "Kormek's Hut", 62.0, 38.5)):
    pt = rt.eval(f'''(function() for _, z in ipairs(NS.ZONES) do if z.name == "{zone}" then
        for _, n in ipairs(z.nodes) do if n.name == "{area}" then return n.points[1] / 100, n.points[2] / 100 end end
    end end end)()''')
    check(f"{area} near {x}, {y}", pt and math.hypot(pt[0] - x, pt[1] - y) < 3, pt)

print("route planning")
rt.execute('''ELWYNN = NS.ZoneByMap(1429)''')
rt.execute('''STOPS, LEN = NS.PlanRoute(ELWYNN, ELWYNN.nodes, 0.42, 0.65)''')
check("route visits every area once", rt.eval('''(function()
    local seen = {} for _, s in ipairs(STOPS) do if seen[s.node] then return false end seen[s.node] = true end
    return #STOPS == #ELWYNN.nodes end)()'''))


def brute(rt, zone_expr, count, sx, sy):
    """Best open walk over the first `count` areas' first points, tried every
    way, against the planner (which may also choose other points: <=)."""
    pts = rt.eval(f'''(function() local z = {zone_expr} local out = {{}}
        for i = 1, {count} do local p = NS.NodePoints(z.nodes[i]) out[i] = {{ p[1][1], p[1][2] }} end
        return out end)()''')
    w, h = rt.eval(f"{zone_expr}.w"), rt.eval(f"{zone_expr}.h")
    P = [(pts[i][1], pts[i][2]) for i in range(1, count + 1)]

    def d(a, b):
        return math.hypot((a[0] - b[0]) * w, (a[1] - b[1]) * h)
    best = min(sum(d(a, b) for a, b in zip(((sx, sy),) + perm, perm)) for perm in itertools.permutations(P))
    rt.execute(f'''SUB = {{}} for i = 1, {count} do local n = {zone_expr}.nodes[i]
        SUB[i] = {{ name = n.name, points = {{ n.points[1], n.points[2] }} }} end''')
    _, length = rt.eval(f"NS.PlanRoute({zone_expr}, SUB, {sx}, {sy})")
    return best, length


for zone in ("ELWYNN", "NS.ZoneByMap(1411)", "NS.ZoneByMap(1434)"):
    best, got = brute(rt, zone, 8, 0.5, 0.5)
    check(f"route over 8 areas of {zone} is the shortest ({got:.0f} vs {best:.0f} yd)", got <= best * 1.0001, (got, best))

print("progress from the achievement")
rt.execute("FIRE('CRITERIA_UPDATE') FLUSH()")
check("nothing uncovered at first", rt.eval("(NS.ZoneCounts(ELWYNN))") == 0)
rt.execute("DONE[ELWYNN.nodes[1].criteria] = true DONE[ELWYNN.nodes[2].criteria] = true FIRE('CRITERIA_UPDATE') FLUSH()")
check("two criteria done -> two uncovered", rt.eval("(NS.ZoneCounts(ELWYNN))") == 2)
check("remaining leaves them out", rt.eval("#NS.ZoneRemaining(ELWYNN)") == len(rt.eval("ELWYNN.nodes")) - 2)

print("progress from the map, without achievement functions")
rt2 = boot()
rt2.execute("ACH_API = false ELWYNN = NS.ZoneByMap(1429)")
rt2.execute("local n = ELWYNN.nodes[3] EXPLORED[1429] = { { n.ox, n.oy } } FIRE('MAP_EXPLORATION_UPDATED') FLUSH()")
check("uncovered art counts", rt2.eval("(NS.ZoneCounts(ELWYNN))") == 1)
check("the rest are still to do, not unknown", rt2.eval("select(3, NS.ZoneCounts(ELWYNN))") == 0)
check("the source is the map", rt2.eval("NS.ZoneState(ELWYNN).source") == "map")

print("the route")
rt.execute("SlashCmdList.COMPASSFOREVER('route')")
check("route starts in the player's zone", rt.eval("NS.route and NS.route.zone == ELWYNN"))
n0 = rt.eval("#NS.route.stops")
check("route skips what is done", n0 == len(rt.eval("ELWYNN.nodes")) - 2, n0)
first = rt.eval("NS.CurrentStop().node.criteria")
rt.execute(f"DONE[{first}] = true FIRE('CRITERIA_UPDATE') FLUSH()")
check("uncovering a stop replans without it", rt.eval("#NS.route.stops") == n0 - 1
      and rt.eval(f"NS.CurrentStop().node.criteria ~= {first}"))
check("the banner says what was uncovered and where next", "Uncovered" in (rt.eval("rawget(BANNER_TITLE(), '_text')") or ""))
skipped = rt.eval("NS.CurrentStop().node.overlay")
rt.execute("SlashCmdList.COMPASSFOREVER('skip')")
check("skip moves the stop to the end", rt.eval("NS.route.stops[#NS.route.stops].node.overlay") == skipped)
rt.execute(f"DONE[NS.CurrentStop().node.criteria] = true FIRE('CRITERIA_UPDATE') FLUSH()")
check("a skipped stop stays last after a replan", rt.eval("NS.route.stops[#NS.route.stops].node.overlay") == skipped)
rt.execute("SlashCmdList.COMPASSFOREVER('route westfall')")
check("route by zone name", rt.eval("NS.route.zone.name") == "Westfall")
rt.execute("for _, n in ipairs(ELWYNN.nodes) do DONE[n.criteria] = true end SlashCmdList.COMPASSFOREVER('route elwynn')")
check("a finished zone has no route", rt.eval("NS.route == nil"))
rt.execute("SlashCmdList.COMPASSFOREVER('stop')")

print("arrow")
rt.execute("ZONE = { w = 1000, h = 1000, map = 1429 } PLAYER.x, PLAYER.y = 0.5, 0.5")
b, y = rt.eval("NS.StopVector(ZONE, { x = 0.5, y = 0.4 })")
check("target due north: bearing 0, 100 yd", abs(b) < 1e-6 and abs(y - 100) < 1e-6, (b, y))
b, y = rt.eval("NS.StopVector(ZONE, { x = 0.6, y = 0.5 })")
check("target due east: bearing -pi/2", abs(b + math.pi / 2) < 1e-6, b)

print("fanfare")
rt.execute("SOUNDS = {} NS.Fanfare()")
check("no clip: the game's fanfare plays", rt.eval("SOUNDS[#SOUNDS]") == 888)
rt.execute("SOUNDS = {} HAVE_FANFARE = true NS.Fanfare()")
check("with Sounds/fanfare.ogg: that plays, and only that",
      rt.eval("#SOUNDS") == 1 and rt.eval("SOUNDS[1]") == r"Interface\AddOns\CompassForever\Sounds\fanfare.ogg")
rt.execute("for _, n in ipairs(ELWYNN.nodes) do DONE[n.criteria] = nil end NS.InvalidateProgress() NS.StartRoute(ELWYNN)")
rt.execute("SOUNDS = {} for _, n in ipairs(ELWYNN.nodes) do DONE[n.criteria] = true end FIRE('CRITERIA_UPDATE') FLUSH()")
check("finishing a zone on a route plays it", rt.eval("SOUNDS[1]") is not None and "fanfare" in str(rt.eval("SOUNDS[1]")))

print("window navigation")
rt.execute("NS.ShowZone(ELWYNN)")
check("opens on a zone", rt.eval("NS.WindowView().kind") == "zone")
rt.execute("NS.WindowZoomOut()")
check("right-click: back to the zone's continent", rt.eval("NS.WindowView().kind") == "continent"
      and rt.eval("NS.WindowView().map") == 1415)
check("the continent shows what each zone has left", "left|r" in rt.eval("TEXTS()"))
target = rt.eval("NS.WindowTarget(0.45, 0.45).zone.name")
check("the zone under the cursor is found", target == "Westfall", target)
rt.execute("NS.WindowOpen(NS.WindowTarget(0.45, 0.45))")
check("clicking it opens that zone", rt.eval("NS.WindowView().zone.name") == "Westfall")
rt.execute("NS.WindowZoomOut() NS.WindowZoomOut()")
check("right-click again: Azeroth", rt.eval("NS.WindowView().kind") == "world")
rt.execute("NS.WindowOpen(NS.WindowTarget(0.5, 0.5))")
check("clicking a continent opens it", rt.eval("NS.WindowView().map") == 1414)
rt.execute("NS.WindowZoomOut() NS.WindowZoomOut()")
check("right-click on Azeroth stays there", rt.eval("NS.WindowView().kind") == "world")

print("gray covered areas")
rt.execute("""for _, n in ipairs(ELWYNN.nodes) do DONE[n.criteria] = nil end
    DONE[ELWYNN.nodes[1].criteria] = true NS.InvalidateProgress() NS.ShowZone(ELWYNN)""")
def gray_count():
    return rt.eval("""(function() local n, files = 0, {}
        for _, f in ipairs(FRAMES) do if rawget(f, "_gray") and rawget(f, "_shown") then
            n = n + 1 files[rawget(f, "_tex")] = true end end
        return n, files end)()""")
n, files = gray_count()
want = rt.eval("(function() local n = 0 for i = 2, #ELWYNN.nodes do n = n + #ELWYNN.nodes[i].files end return n end)()")
check("every covered area's art is drawn gray", n >= want, (n, want))
first_files = list(rt.eval("ELWYNN.nodes[1].files").values())
check("an uncovered area is not drawn gray", not any(files[f] for f in first_files if f in files))

print("world map layers")
rt.execute("PRINTED = {} SHOWN_MAP = 1429 NS.db.mapPins = true WorldMapFrame._scripts.OnShow()")
levels = rt.eval("""(function() local out = {}
    for _, f in ipairs(FRAMES) do local l = rawget(f, "_level") if l then out[#out + 1] = l end end
    return table.concat(out, ",") end)()""")
lv = [int(x) for x in levels.split(",") if x]
check("markers and bar sit above the map's top-most pins", any(l > 2150 for l in lv), lv)
check("gray art sits at the map's own explored-art level", 1990 in lv, lv)
check("the world map draws its gray art", gray_count()[0] > 0)

print("zooming the window's map")
rt.execute("NS.ShowZone(ELWYNN) CURSOR = { 450, 300 }")   # box x 450, y 100
z0 = rt.eval("(NS.WindowZoom())")
check("a new map starts at full size", z0 == 1)
rt.execute("NS.WindowWheel(nil, 1)")
z1, ox, oy = rt.eval("NS.WindowZoom()")
check("scrolling up zooms in", z1 > 1, z1)
# The point under the cursor stays under it: (off + box) / size is unchanged.
check("zooming keeps the point under the cursor in place",
      abs((ox + 450) / (600 * z1) - 450 / 600) < 1e-9 and abs((oy + 100) / (400 * z1) - 100 / 400) < 1e-9, (ox, oy))
for _ in range(20):
    rt.execute("NS.WindowWheel(nil, 1)")
check("zoom stops at 4x", rt.eval("(NS.WindowZoom())") == 4)
check("no error drawing a zoomed map", not any("|cffff5555" in p for p in printed(rt)), printed(rt))
for _ in range(20):
    rt.execute("NS.WindowWheel(nil, -1)")
check("scrolling down zooms back out, then goes up a level", rt.eval("NS.WindowView().kind") in ("continent", "world"))
rt.execute("NS.ShowZone(ELWYNN) NS.WindowZoomOut()")
check("the continent opens at full size", rt.eval("(NS.WindowZoom())") == 1)
rt.execute("CURSOR = { 300, 200 } NS.WindowWheel(nil, 1) NS.WindowWheel(nil, 1)")
target = rt.eval("NS.WindowTarget(0.45, 0.45).zone.name")
check("zoomed in, the zone under the cursor is still found", target == "Westfall", target)
rt.execute("NS.WindowWheel(nil, -1) NS.WindowWheel(nil, -1) NS.WindowWheel(nil, -1)")
check("scrolling out past full size on a continent shows Azeroth", rt.eval("NS.WindowView().kind") == "world")

print("go here next")
rt.execute("for _, n in ipairs(ELWYNN.nodes) do DONE[n.criteria] = nil end PLAYER.map, PLAYER.x, PLAYER.y = 1429, 0.42, 0.65")
rt.execute("FIRE('CRITERIA_UPDATE') FLUSH() PICK = ELWYNN.nodes[7] NS.RouteVia(ELWYNN, PICK)")
check("a picked spot becomes the first stop", rt.eval("NS.CurrentStop().node == PICK"))
check("the rest of the zone follows it", rt.eval("#NS.route.stops") == len(rt.eval("ELWYNN.nodes")))
rt.execute("PICK2 = NS.route.stops[5].node NS.RouteVia(ELWYNN, PICK2)")
check("picking another moves it to the front", rt.eval("NS.CurrentStop().node == PICK2")
      and rt.eval("#NS.route.stops") == len(rt.eval("ELWYNN.nodes")))
rt.execute("NS.StopRoute()")

print("automatic routes")
rt.execute("FIRE('ZONE_CHANGED_NEW_AREA') FLUSH()")
check("off by default: entering a zone starts nothing", rt.eval("NS.route == nil"))
rt.execute("SlashCmdList.COMPASSFOREVER('auto') FLUSH()")
check("turning it on in a zone with work starts its route", rt.eval("NS.route and NS.route.zone == ELWYNN and NS.route.auto"))
check("and the banner says where to run", "to uncover" in (rt.eval("rawget(BANNER_TITLE(), '_text')") or ""))
rt.execute("PLAYER.map, PLAYER.x, PLAYER.y = 1436, 0.5, 0.5 FIRE('ZONE_CHANGED_NEW_AREA') FLUSH()")
check("entering the next zone switches to its route", rt.eval("NS.route and NS.route.zone.name") == "Westfall")
rt.execute("PLAYER.map = 9999 FIRE('ZONE_CHANGED_NEW_AREA') FLUSH()")
check("leaving for a place with no map ends the automatic route", rt.eval("NS.route == nil"))
rt.execute("PLAYER.map = 1429 SlashCmdList.COMPASSFOREVER('route westfall') FIRE('ZONE_CHANGED_NEW_AREA') FLUSH()")
check("a route the player started is kept on entering another zone", rt.eval("NS.route.zone.name") == "Westfall")
rt.execute("NS.StopRoute() SlashCmdList.COMPASSFOREVER('auto')")
check("auto can be turned off again", rt.eval("NS.db.autoRoute") is False)

print("terrain")
check("every zone has terrain", rt.eval("(function() local n = 0 for _, z in ipairs(NS.ZONES) do if NS.TERRAIN[z.ach] then n = n + 1 end end return n end)()") == 43)
check("a grid decodes to one digit per point", rt.eval("(function() local z = NS.ZoneByMap(1413) local g = NS.Grid(z) return #g.cells == g.nx * g.ny end)()"))
# The game's path search must agree with the build's: the same grid, the same
# rules, the same costs (to the yard the build rounds to).
worst, pairs_checked = 0.0, 0
for zone_map in (1441, 1427, 1434):      # Thousand Needles, Searing Gorge, Stranglethorn
    n = rt.eval(f"#NS.ZoneByMap({zone_map}).nodes")
    for a in range(1, n + 1, max(1, n // 4)):
        for b in range(1, n + 1, max(1, n // 3)):
            if a == b:
                continue
            got, want = rt.eval(f"""(function()
                local z = NS.ZoneByMap({zone_map})
                local na, nb = z.nodes[{a}], z.nodes[{b}]
                local pa, pb = NS.NodePoints(na)[1], NS.NodePoints(nb)[1]
                local _, cost = NS.FindPathNow(z, pa[1], pa[2], pb[1], pb[2])
                return cost, NS.WalkCost(z, NS.PointID(z, na, 1), NS.PointID(z, nb, 1))
            end)()""")
            worst = max(worst, abs(got - want))
            pairs_checked += 1
check(f"the game's path search matches the build's costs ({pairs_checked} pairs, worst {worst:.2f} yd)", worst <= 1.0, worst)
# A cliff the straight line crosses: the path goes round, and costs more.
found = rt.eval("""(function()
    local z = NS.ZoneByMap(1441)
    local g = NS.Grid(z)
    for _, na in ipairs(z.nodes) do for _, nb in ipairs(z.nodes) do if na ~= nb then
        local pa, pb = NS.NodePoints(na)[1], NS.NodePoints(nb)[1]
        local straight = math.sqrt(((pa[1] - pb[1]) * z.w) ^ 2 + ((pa[2] - pb[2]) * z.h) ^ 2)
        local cost = NS.WalkCost(z, NS.PointID(z, na, 1), NS.PointID(z, nb, 1))
        if cost and cost > straight * 1.3 and cost < straight * 5 then return na.name .. " > " .. nb.name, straight, cost end
    end end end
end)()""")
check("some legs in Thousand Needles go round the mesas", found is not None and found[0] is not None, found)
if found and found[0]:
    print(f"       e.g. {found[0]}: {found[1]:.0f} yd straight, {found[2]:.0f} yd walking")

print("route planner walks round cliffs")
legs = rt.eval("""(function()
    local z = NS.ZoneByMap(1441)
    local stops, len = NS.PlanRoute(z, z.nodes)
    local sum = 0
    for i = 2, #stops do
        local function id(stop) for k, p in ipairs(NS.NodePoints(stop.node)) do
            if math.abs(p[1] - stop.x) < 1e-9 and math.abs(p[2] - stop.y) < 1e-9 then return NS.PointID(z, stop.node, k) end end end
        local a, b = id(stops[i - 1]), id(stops[i])
        sum = sum + (NS.WalkCost(z, a, b) + NS.WalkCost(z, b, a)) / 2
    end
    return len, sum
end)()""")
check("a route's length is its legs' walking costs", abs(legs[0] - legs[1]) < 1, legs)

print("the arrow follows the path")
rt.execute("""TN = NS.ZoneByMap(1441)
    NS.StopRoute()
    for _, n in ipairs(TN.nodes) do DONE[n.criteria] = nil end NS.InvalidateProgress()""")
bend = rt.eval("""(function()
    local z = TN
    for _, na in ipairs(z.nodes) do for _, nb in ipairs(z.nodes) do if na ~= nb then
        local pa, pb = NS.NodePoints(na)[1], NS.NodePoints(nb)[1]
        local straight = math.sqrt(((pa[1] - pb[1]) * z.w) ^ 2 + ((pa[2] - pb[2]) * z.h) ^ 2)
        local cost = NS.WalkCost(z, NS.PointID(z, na, 1), NS.PointID(z, nb, 1))
        if cost and cost > straight * 1.5 and cost < straight * 4 and straight > 300 then
            PLAYER.map, PLAYER.x, PLAYER.y = z.map, pa[1], pa[2]
            STEER_STOP = { x = pb[1], y = pb[2], node = nb }
            return true
        end
    end end end
end)()""")
check("found a leg that bends", bend is True)
straight_b = rt.eval("(NS.StopVector({ w = TN.w, h = TN.h, map = TN.map }, STEER_STOP))")
rt.execute("NS.StopVector(TN, STEER_STOP)")
for _ in range(400):
    rt.execute("FRAME(0.05)")
path_b, path_d = rt.eval("NS.StopVector(TN, STEER_STOP)")
check("once the path is found, the arrow points along it, not straight", abs(path_b - straight_b) > 0.05, (path_b, straight_b))
check("and the distance is the walk, not the straight line",
      path_d > rt.eval("select(2, NS.StopVector({ w = TN.w, h = TN.h, map = TN.map }, STEER_STOP))") * 1.2, path_d)

print("flights")
rt.execute("""
    DW = NS.ZoneByMap(1431)
    REAL_PLAYERON, REAL_TRANSLATE = NS.PlayerOn, NS.Translate
    -- On the Eastern Kingdoms map: the player at Ironforge's flight point, the
    -- stop a little way from Darkshire's.
    NS.PlayerOn = function(map) if map == 1415 then return 0.48737, 0.52365 end return REAL_PLAYERON(map) end
    NS.Translate = function(from, x, y, to) if to == 1415 then return 0.4920, 0.7680 end return REAL_TRANSLATE(from, x, y, to) end
    function UnitFactionGroup() return "Alliance" end
    function GetRealmName() return "Forever" end
    STOP = { x = 0.5, y = 0.5, node = DW.nodes[1] }
""")
rt.execute("NS.db.taxi = {} NS.PlanTravel(DW, STOP)")
check("no flight points known: walk", rt.eval("NS.travel == nil"))
rt.execute("""C_TaxiMap = { GetAllTaxiNodes = function() return {
        { nodeID = 6, name = "Ironforge, Dun Morogh", state = 0 },
        { nodeID = 2, name = "Stormwind, Elwynn", state = 1 },
        { nodeID = 12, name = "Darkshire, Duskwood", state = 1 },
        { nodeID = 5, name = "Lakeshire, Redridge", state = 2 } } end }
    Enum = Enum or {} Enum.FlightPathState = { Current = 0, Reachable = 1, Unreachable = 2 }
    FIRE('TAXIMAP_OPENED')""")
known = rt.eval("(function() local t = {} for id in pairs(NS.KnownFlights()) do t[#t + 1] = id end table.sort(t) return table.concat(t, ',') end)()")
check("opening a flight map remembers the known points, not the unreachable", known == "2,6,12", known)
rt.execute("NS.PlanTravel(DW, STOP)")
check("far away with flights known: fly Ironforge to Darkshire",
      rt.eval("NS.travel and NS.travel.fromID") == 6 and rt.eval("NS.travel and NS.travel.toID") == 12,
      rt.eval("NS.travel and (NS.travel.fromID .. '>' .. NS.travel.toID)"))
check("the flight is said plainly", "Ironforge" in (rt.eval("NS.TravelText()") or "") and "Darkshire" in (rt.eval("NS.TravelText()") or ""))
rt.execute("NS.PlayerOn = function(map) if map == 1415 then return 0.4900, 0.7600 end return REAL_PLAYERON(map) end NS.PlanTravel(DW, STOP)")
check("close by: walk", rt.eval("NS.travel == nil"))
rt.execute("NS.PlayerOn, NS.Translate = REAL_PLAYERON, REAL_TRANSLATE NS.travel = nil")

print("the route line crosses zone lines")
rt.execute("""NS.StopRoute()
    for _, n in ipairs(ELWYNN.nodes) do DONE[n.criteria] = nil end NS.InvalidateProgress()
    PLAYER.map, PLAYER.x, PLAYER.y = 1429, 0.10, 0.50
    NS.StartRoute(ELWYNN)
    PLAYER.map, PLAYER.x, PLAYER.y = 1436, 0.80, 0.40      -- now in Westfall
    GEO = NS.RouteGeometry()""")
check("the route is laid out on the continent", rt.eval("GEO and GEO.cont") == 1415)
walk = rt.eval("""(function() for _, p in ipairs(GEO.parts) do if p.kind == "walk" then return p.pts end end end)()""")
check("its first leg starts where the player is, in Westfall",
      walk is not None and abs(walk[1] - (0.30 + 0.80 * 0.10)) < 1e-9 and abs(walk[2] - (0.72 + 0.40 * 0.10)) < 1e-9, walk)
ends_x = rt.eval("""(function()
    local conv = NS.ContinentToMap(GEO.cont, 1436)
    for _, p in ipairs(GEO.parts) do if p.kind == "walk" then
        local x1 = conv(p.pts[1], p.pts[2]) local x2 = conv(p.pts[#p.pts - 1], p.pts[#p.pts]) return x1, x2 end end
end)()""")
check("on Westfall's map it starts inside and runs off the east edge into Elwynn",
      0 <= ends_x[0] <= 1 and ends_x[1] > 1, ends_x)
rt.execute("HIDE_LINES() NS.ShowZone(NS.ZoneByMap(1436))")
check("the window draws the route on Westfall's map", rt.eval("""(function() local n = 0
    for _, l in ipairs(LINES) do if rawget(l, "_shown") then n = n + 1 end end return n end)()""") > 0)
check("and Elwynn's numbered stops with it", rt.eval("""(function()
    for _, f in ipairs(FRAMES) do if f.node and f.zone == ELWYNN and rawget(f, "_shown") and f.order == 1 then return true end end
end)()""") is True)
rt.execute("HIDE_LINES() NS.WindowZoomOut()")
check("on the continent too", rt.eval("""(function() local n = 0
    for _, l in ipairs(LINES) do if rawget(l, "_shown") then n = n + 1 end end return n end)()""") > 0)
rt.execute("HIDE_LINES() PRINTED = {} SHOWN_MAP = 1436 WorldMapFrame._scripts.OnShow()")
check("the world map draws it on Westfall as well", rt.eval("""(function() local n = 0
    for _, l in ipairs(LINES) do if rawget(l, "_shown") then n = n + 1 end end return n end)()""") > 0)
check("with no error", not any("|cffff5555" in p for p in printed(rt)), printed(rt))
rt.execute("NS.StopRoute() PLAYER.map, PLAYER.x, PLAYER.y = 1429, 0.42, 0.65")

print("window and world map")
rt.execute("PRINTED = {} NS.ShowZone(ELWYNN)")
check("window opens on a zone without an error", not any("|cffff5555" in p for p in printed(rt)), printed(rt))
texts = rt.eval("TEXTS()")
check("zone list shows what is left", " left" in texts and "Elwynn Forest" in texts)
check("overall bar counts areas and zones", "Explorer:" in texts)
rt.execute("HIDE_LINES() PRINTED = {} NS.StartRoute(ELWYNN)")
shown = rt.eval("(function() local n = 0 for _, l in ipairs(LINES) do if rawget(l, '_shown') then n = n + 1 end end return n end)()")
check("route lines drawn on the window's map", shown >= len(rt.eval("ELWYNN.nodes")) - 1, shown)
check("the window shows the next stop", "Head " in rt.eval("TEXTS()"))
rt.execute("local n = ELWYNN.nodes[1] EXPLORED[1429] = { { n.ox, n.oy } } NS.InvalidateProgress() NS.RefreshWindow()")
check("uncovered map art is drawn without an error", not any("|cffff5555" in p for p in printed(rt)), printed(rt))
rt.execute("PRINTED = {} SHOWN_MAP = 1436 WorldMapFrame._scripts.OnShow()")
check("world map bar offers the zone's route", "Westfall: |cffffd100" in rt.eval("TEXTS()"))
check("no error drawing the world map", not any("|cffff5555" in p for p in printed(rt)), printed(rt))
# Zoomed in: the canvas is drawn at a third of UIParent's scale, so markers
# are scaled up 3x to stay one size; their spots must not move with it.
rt.execute("""PRINTED = {}
    for _, f in ipairs(FRAMES) do if f ~= UIParent then rawset(f, "_eff", 1 / 3) end end
    NS.StartRoute(NS.ZoneByMap(1436)) WorldMapFrame._scripts.OnShow()""")
off = rt.eval("""(function()
    local worst = 0
    for _, stop in ipairs(NS.route.stops) do
        for _, f in ipairs(FRAMES) do
            local pt, sc = rawget(f, "_point"), rawget(f, "_scale")
            if f.node == stop.node and pt and sc and f:IsShown() then
                local x, y = pt[4] * sc / 1000, -pt[5] * sc / 1000
                worst = math.max(worst, math.abs(x - stop.x), math.abs(y - stop.y))
            end
        end
    end
    return worst end)()""")
check("world map markers sit on their spots when zoomed", off < 1e-6, off)
rt.execute("PRINTED = {} SlashCmdList.COMPASSFOREVER('probe')")
out = "\n".join(printed(rt))
check("probe reports the criteria match", "match the built-in areas" in out, out)

print("lua escapes")
# A path written through a shell heredoc once lost its backslashes; every
# texture path must read Interface\... in the source.
for path in TOC:
    src = open(path, encoding="utf-8").read()
    check(f"{path}: texture paths keep their backslashes", not re.search(r'"Interface[^\\"]', src))

print()
print("FAILED: " + ", ".join(failures) if failures else "all passed")
sys.exit(1 if failures else 0)
