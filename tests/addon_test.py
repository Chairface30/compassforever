# Chair Legacy in a stand-in client (needs: pip install lupa)
#   python tests/addon_test.py
#
# The harness is kinder than the client: it proves the logic, not that the
# client will hand these values over. That is what /legacy probe is for.
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

FRAMES = {}
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
        elseif key == "GetWidth" or key == "GetHeight" then return function() return 1000 end
        elseif key == "GetEffectiveScale" then return function() return 1 end
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
    for _, o in ipairs(EXPLORED[map] or {}) do out[#out + 1] = { offsetX = o[1], offsetY = o[2] } end
    return out
end }

DBICON = { registered = {} }
local LDB = {}
function LDB:NewDataObject(name, obj) return obj end
function DBICON:Register(name, obj, db) self.registered[name] = obj end
function LibStub(name) return name == "LibDataBroker-1.1" and LDB or name == "LibDBIcon-1.0" and DBICON or nil end
WorldMapFrame = CreateFrame("Frame")
WorldMapFrame.ScrollContainer = { Child = CreateFrame("Frame") }
SHOWN_MAP = 1429
WorldMapFrame.GetMapID = function() return SHOWN_MAP end
'''

TOC = [l.strip() for l in io.open("ChairLegacy.toc", encoding="utf-8")
       if l.strip() and not l.startswith("#") and not l.startswith("Libs")]


def boot():
    rt = lua51.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(HARNESS)
    rt.execute("NS = {}")
    for path in TOC:
        src = io.open(path, encoding="utf-8").read()
        fn = rt.eval("function(src, name) local f, err = loadstring(src, name) if not f then error(err) end return f end")(src, path)
        fn("ChairLegacy", rt.globals().NS)
    # The stand-in achievements: every challenge and every zone, criteria
    # from the built-in data.
    rt.execute('''
        ACH_BY_ID = {}
        for _, def in ipairs(NS.CHALLENGES) do
            local crit = {}
            for i, s in ipairs(def.steps) do crit[i] = { name = s, id = def.id * 100 + i, asset = 0 } end
            ACH_BY_ID[def.id] = { name = def.name, text = def.text, crit = crit }
        end
        for _, z in ipairs(NS.ZONES) do
            local crit = {}
            for i, n in ipairs(z.nodes) do crit[i] = { name = n.name, id = n.criteria, asset = n.overlay } end
            ACH_BY_ID[z.ach] = { name = "Explore " .. z.name, crit = crit }
        end
    ''')
    rt.execute("FIRE('ADDON_LOADED', 'ChairLegacy') FIRE('PLAYER_LOGIN') FLUSH()")
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
check("slash command registered", rt.eval("SlashCmdList.CHAIRLEGACY ~= nil"))
check("minimap button registered", rt.eval("DBICON.registered.ChairLegacy ~= nil"))

print("data")
zones = rt.eval("#NS.ZONES")
nodes = rt.eval("(function() local n = 0 for _, z in ipairs(NS.ZONES) do n = n + #z.nodes end return n end)()")
check("43 zones", zones == 43, zones)
check("549 map areas", nodes == 549, nodes)
check("65 challenges, 65 hardcore", rt.eval("#NS.CHALLENGES") == 65 and rt.eval("#NS.CHALLENGES_HARDCORE") == 65)
check("every point on its zone's map", rt.eval('''(function()
    for _, z in ipairs(NS.ZONES) do for _, n in ipairs(z.nodes) do
        if #n.points < 2 or #n.points % 2 ~= 0 then return false end
        for _, v in ipairs(n.points) do if v < 0 or v > 10000 then return false end end
    end end return true end)()'''))
check("only Undercity is approximate", rt.eval('''(function()
    local r = {} for _, z in ipairs(NS.ZONES) do for _, n in ipairs(z.nodes) do
        if n.rough then r[#r + 1] = n.name end end end
    return table.concat(r, ",") end)()''') == "Undercity")
check("every challenge in a category", rt.eval('''(function()
    local ok = {} for _, c in ipairs(NS.CHALLENGE_CATEGORIES) do ok[c.id] = true end
    for _, d in ipairs(NS.CHALLENGES) do if not ok[d.category] then return false end end
    return true end)()'''))
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
rt.execute("SlashCmdList.CHAIRLEGACY('route')")
check("route starts in the player's zone", rt.eval("NS.route and NS.route.zone == ELWYNN"))
n0 = rt.eval("#NS.route.stops")
check("route skips what is done", n0 == len(rt.eval("ELWYNN.nodes")) - 2, n0)
first = rt.eval("NS.CurrentStop().node.criteria")
rt.execute(f"DONE[{first}] = true FIRE('CRITERIA_UPDATE') FLUSH()")
check("uncovering a stop replans without it", rt.eval("#NS.route.stops") == n0 - 1
      and rt.eval(f"NS.CurrentStop().node.criteria ~= {first}"))
check("says the next stop", any(p.find("Next:") >= 0 for p in printed(rt)))
skipped = rt.eval("NS.CurrentStop().node.overlay")
rt.execute("SlashCmdList.CHAIRLEGACY('skip')")
check("skip moves the stop to the end", rt.eval("NS.route.stops[#NS.route.stops].node.overlay") == skipped)
rt.execute(f"DONE[NS.CurrentStop().node.criteria] = true FIRE('CRITERIA_UPDATE') FLUSH()")
check("a skipped stop stays last after a replan", rt.eval("NS.route.stops[#NS.route.stops].node.overlay") == skipped)
rt.execute("SlashCmdList.CHAIRLEGACY('route westfall')")
check("route by zone name", rt.eval("NS.route.zone.name") == "Westfall")
rt.execute("for _, n in ipairs(ELWYNN.nodes) do DONE[n.criteria] = true end SlashCmdList.CHAIRLEGACY('route elwynn')")
check("a finished zone has no route", rt.eval("NS.route == nil"))
rt.execute("SlashCmdList.CHAIRLEGACY('stop')")

print("arrow")
rt.execute("ZONE = { w = 1000, h = 1000, map = 1429 } PLAYER.x, PLAYER.y = 0.5, 0.5")
b, y = rt.eval("NS.StopVector(ZONE, { x = 0.5, y = 0.4 })")
check("target due north: bearing 0, 100 yd", abs(b) < 1e-6 and abs(y - 100) < 1e-6, (b, y))
b, y = rt.eval("NS.StopVector(ZONE, { x = 0.6, y = 0.5 })")
check("target due east: bearing -pi/2", abs(b + math.pi / 2) < 1e-6, b)

print("window, tracker, pins, probe")
rt.execute("NS.ToggleWindow()")
for page in ["'overview'", "'explore'", "15568", "15586", "15593", "15594", "15595", "15596"]:
    rt.execute(f"PRINTED = {{}} NS.SelectPage({page})")
    check(f"page {page} draws", rt.eval('''(function() for _, f in ipairs(FRAMES) do
        local t = rawget(f, "_text") if type(t) == "string" and t:find("Could not draw") then return false end
    end return true end)()'''))
rt.execute("NS.SetTracked(62031, true) NS.SetTracked(776, true)")
text = rt.eval("(function() for _, f in ipairs(FRAMES) do local t = rawget(f, '_text') if type(t) == 'string' and t:find('Spelunker') then return t end end end)()")
check("tracker lists a tracked challenge's steps", text and "Wailing Caverns" in text, text)
rt.execute("SHOWN_MAP = 1436 SlashCmdList.CHAIRLEGACY('route westfall')")
check("route draws on the map without an error", not any("|cffff5555" in p for p in printed(rt)))
rt.execute("PRINTED = {} SlashCmdList.CHAIRLEGACY('probe')")
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
