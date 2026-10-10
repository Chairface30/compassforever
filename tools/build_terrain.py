"""Build Data/Terrain.lua and Data/Flights.lua from the files
fetch_terrain.py downloaded. Run after build_data.py.

Terrain: for each zone, a grid of points 8.3 yards apart over the zone's map
(every other terrain height sample), and for every pair of neighbouring
points whether you can walk from one to the other. That is judged from the
terrain's own height samples, one every 4.2 yards:

  - uphill steeper than CLIMB (50 degrees) can't be walked up;
  - downhill steeper than DROP (75 degrees) is a fall, not a walk;
  - deep water (DEEP yards or more over the ground) is swum, whatever the
    ground under it does;
  - lava and slime are never walked into.

A step that breaks a rule is not forbidden outright: it costs PENALTY times
its length. Bridges and buildings are not terrain, so a gorge with a bridge
over it looks like a cliff here; the penalty keeps such a crossing possible
when nothing else is, while every real detour is preferred.

Each point's four rules (east out, east in, south out, south in) are one hex
digit; a zone's points are a run-length coded string of them.

For the route planner, the walking cost between every two standing points of
a zone (Data/Exploration.lua's points, in order) is worked out here with
Dijkstra over that grid, so the game never has to.

Flights: every flight point on the two continents (faction, position on the
continent map) and every direct flight between two of them, with its length
along the flight path (Chairface's flown times put flights at a median of 30
yards a second).

Usage: python build_terrain.py <cache dir> <addon dir>
"""
import csv
import math
import os
import re
import struct
import sys
from collections import defaultdict

import numpy as np
from scipy.sparse import csr_matrix
from scipy.sparse.csgraph import dijkstra

TILE = 1600.0 / 3.0
CHUNK = TILE / 16.0
STEP = CHUNK / 8.0
NODE = STEP * 2               # grid points are every other height sample
CLIMB = math.tan(math.radians(50)) * STEP
DROP = math.tan(math.radians(75)) * STEP
DEEP = 1.5
PENALTY = 25.0
LAVA = {3, 7, 19}
SLIME = {4, 8, 20}
CONTINENT_MAP = {0: "1415", 1: "1414"}


def load(cache, name):
    with open(os.path.join(cache, "db2", name + ".csv"), encoding="utf-8") as f:
        return list(csv.DictReader(f))


# ---------------------------------------------------------------------------
# Terrain files
# ---------------------------------------------------------------------------

def read_tile(path):
    """{(ix, iy): (heights 9x9 absolute, water level or None, deadly)}."""
    data = open(path, "rb").read()
    chunks = {}
    order = []
    mh2o = None
    pos = 0
    while pos + 8 <= len(data):
        magic = data[pos:pos + 4][::-1]
        size = struct.unpack_from("<I", data, pos + 4)[0]
        body = pos + 8
        if magic == b"MH2O":
            mh2o = (body, size)
        elif magic == b"MCNK":
            ix, iy = struct.unpack_from("<II", data, body + 4)
            base = struct.unpack_from("<3f", data, body + 0x68)[2]
            sub, end = body + 0x80, body + size
            heights = None
            while sub + 8 <= end:
                smagic = data[sub:sub + 4][::-1]
                ssize = struct.unpack_from("<I", data, sub + 4)[0]
                if smagic == b"MCVT":
                    h = struct.unpack_from("<145f", data, sub + 8)
                    heights = np.array([[h[r * 17 + c] for c in range(9)] for r in range(9)]) + base
                    break
                sub += 8 + ssize
            if heights is not None:
                chunks[(ix, iy)] = [heights, None, False]
                order.append((ix, iy))
        pos = body + size
    if mh2o:
        start, _ = mh2o
        for i in range(256):
            ofs, layers, _ = struct.unpack_from("<III", data, start + i * 12)
            if layers == 0 or ofs == 0:
                continue
            ix, iy = i % 16, i // 16
            if (ix, iy) not in chunks:
                continue
            kind, _, lo, hi = struct.unpack_from("<HHff", data, start + ofs)
            c = chunks[(ix, iy)]
            c[1] = hi if hi == hi else lo
            if kind in LAVA or kind in SLIME:
                c[2] = True
    return chunks


def load_continent(cache, mapID):
    d = os.path.join(cache, f"map{mapID}")
    grid = {}
    for name in os.listdir(d):
        if not name.endswith(".adt"):
            continue
        tx, ty = (int(v) for v in name[:-4].split("_"))
        for (ix, iy), c in read_tile(os.path.join(d, name)).items():
            grid[(tx * 16 + ix, ty * 16 + iy)] = c
    return grid


# ---------------------------------------------------------------------------
# Walking rules
# ---------------------------------------------------------------------------
# The grid's points are every other terrain height sample: 8.3 yards apart.
# A step between two neighbouring points crosses the sample between them, so
# both 4.2-yard halves must keep to the rules.

def zone_heights(cont, bounds):
    """The zone's height samples (water surface where it is deep enough to
    swim), and which samples can't be stood on (no terrain, lava, slime)."""
    minX, minY, maxX, maxY = bounds
    gx0 = int(math.floor((32 * TILE - maxY) / CHUNK))
    gx1 = int(math.ceil((32 * TILE - minY) / CHUNK)) - 1
    gy0 = int(math.floor((32 * TILE - maxX) / CHUNK))
    gy1 = int(math.ceil((32 * TILE - minX) / CHUNK)) - 1
    nx, ny = gx1 - gx0 + 1, gy1 - gy0 + 1
    H = np.full((ny * 8 + 1, nx * 8 + 1), np.nan)
    bad = np.zeros(H.shape, bool)
    for gy in range(gy0, gy1 + 1):
        for gx in range(gx0, gx1 + 1):
            c = cont.get((gx, gy))
            if c is None:
                continue
            heights, water, deadly = c
            r, q = (gy - gy0) * 8, (gx - gx0) * 8
            block = heights.copy()
            if water is not None:
                deep = water - heights >= DEEP
                block[deep] = water
            H[r:r + 9, q:q + 9] = block
            if deadly:
                bad[r:r + 9, q:q + 9] = True
    bad |= np.isnan(H)
    return gx0, gy0, H, bad


def ok(rise):
    with np.errstate(invalid="ignore"):
        return (rise >= -DROP) & (rise <= CLIMB)


def node_rules(H, bad):
    """For each grid point, whether each of its four steps can be walked:
    east, west, south and north out of it (False off the grid)."""
    P = H[::2, ::2]
    R, C = P.shape
    east = np.zeros((R, C), bool)
    west = np.zeros((R, C), bool)
    south = np.zeros((R, C), bool)
    north = np.zeros((R, C), bool)
    a, m, b = H[::2, 0:-2:2], H[::2, 1:-1:2], H[::2, 2::2]
    stop = bad[::2, 0:-2:2] | bad[::2, 1:-1:2] | bad[::2, 2::2]
    east[:, :-1] = ok(m - a) & ok(b - m) & ~stop
    west[:, 1:] = ok(m - b) & ok(a - m) & ~stop
    a, m, b = H[0:-2:2, ::2], H[1:-1:2, ::2], H[2::2, ::2]
    stop = bad[0:-2:2, ::2] | bad[1:-1:2, ::2] | bad[2::2, ::2]
    south[:-1, :] = ok(m - a) & ok(b - m) & ~stop
    north[1:, :] = ok(m - b) & ok(a - m) & ~stop
    return east, west, south, north


def digits_of(east, west, south, north):
    """One hex digit per point: 1 east out, 2 east in (the point to the east
    can step west into it), 4 south out, 8 south in."""
    R, C = east.shape
    east_in = np.zeros((R, C), bool)
    east_in[:, :-1] = west[:, 1:]
    south_in = np.zeros((R, C), bool)
    south_in[:-1, :] = north[1:, :]
    bits = east.astype(int) + 2 * east_in + 4 * south + 8 * south_in
    return "".join(np.array(list("0123456789abcdef"))[bits].ravel())


def rle(s):
    """Runs of four or more of one digit become %<digit><count>."""
    out = []
    for m in re.finditer(r"(.)\1*", s):
        run = m.group(0)
        out.append(f"%{run[0]}{len(run)}." if len(run) >= 4 else run)
    return "".join(out)


def graph(east, west, south, north):
    """Directed graph over the points, costs in yards (a step that breaks a
    rule PENALTY times its length). A diagonal is a step east or west and a
    step north or south; it keeps to the rules if either order does."""
    R, C = east.shape
    idx = np.arange(R * C).reshape(R, C)
    rows, cols, vals = [], [], []
    rule = {(1, 0): east, (-1, 0): west, (0, 1): south, (0, -1): north}

    def add(src, dst, good, length):
        rows.append(src.ravel()); cols.append(dst.ravel())
        vals.append(np.where(good.ravel(), length, length * PENALTY))

    for (di, dj), out in rule.items():
        rs = slice(max(0, -dj), R - max(0, dj))
        cs = slice(max(0, -di), C - max(0, di))
        rd = slice(max(0, dj), R - max(0, -dj) if dj < 0 else R)
        cd = slice(max(0, di), C - max(0, -di) if di < 0 else C)
        add(idx[rs, cs], idx[rd, cd], out[rs, cs], NODE)
    for di in (1, -1):
        for dj in (1, -1):
            h, v = rule[(di, 0)], rule[(0, dj)]
            rs = slice(max(0, -dj), R - max(0, dj))
            cs = slice(max(0, -di), C - max(0, di))
            rd = slice(max(0, dj), R - max(0, -dj) if dj < 0 else R)
            cd = slice(max(0, di), C - max(0, -di) if di < 0 else C)
            # Way 1: across, then along from the point across. Way 2: the other.
            rh = slice(rs.start, rs.stop); ch_ = slice(cs.start + di, cs.stop + di)
            rv = slice(rs.start + dj, rs.stop + dj); cv = slice(cs.start, cs.stop)
            way1 = h[rs, cs] & v[rh, ch_]
            way2 = v[rs, cs] & h[rv, cv]
            add(idx[rs, cs], idx[rd, cd], way1 | way2, NODE * math.sqrt(2))
    return csr_matrix((np.concatenate(vals), (np.concatenate(rows), np.concatenate(cols))), shape=(R * C, R * C))



def b36(n, width=3):
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    n = max(0, min(36 ** width - 1, int(round(n))))
    s = ""
    for _ in range(width):
        s = digits[n % 36] + s
        n //= 36
    return s


def read_zones(addon):
    """Zones and their standing points, from Data/Exploration.lua."""
    src = open(os.path.join(addon, "Data", "Exploration.lua"), encoding="utf-8").read()
    zones = []
    for zm in re.finditer(r"\{ ach = (\d+), map = (\d+), name = \"([^\"]*)\", continent = (\d+), "
                          r"w = ([\d.]+), h = ([\d.]+), nodes = \{\n(.*?)\n    \} \},", src, re.S):
        nodes = []
        for pm in re.finditer(r"points = \{ ([\d, ]+) \}", zm.group(7)):
            v = [int(x) for x in pm.group(1).split(",")]
            nodes.append([(v[i] / 10000, v[i + 1] / 10000) for i in range(0, len(v), 2)])
        zones.append({"ach": int(zm.group(1)), "map": zm.group(2), "name": zm.group(3),
                      "continent": int(zm.group(4)), "nodes": nodes})
    return zones


def main():
    cache, addon = sys.argv[1], sys.argv[2]
    assign = {}
    for r in load(cache, "UiMapAssignment"):
        if r["OrderIndex"] == "0" and r["MapID"] in ("0", "1"):
            assign.setdefault(r["UiMapID"], r)

    def bounds(ui):
        a = assign[ui]
        return float(a["Region_0"]), float(a["Region_1"]), float(a["Region_3"]), float(a["Region_4"])

    zones = read_zones(addon)
    conts = {}
    out = [
        "-- Generated by tools/build_terrain.py from the client's own terrain. Do",
        "-- not edit by hand.",
        "--",
        "-- Per zone (keyed by its Explore achievement): a grid of points over the",
        "-- zone map, yd yards apart. x0, y0: point (0, 0) as fractions of the map;",
        "-- cw, ch: the spacing in fractions; nx, ny: points across and down.",
        "-- cells: one hex digit per point, row by row (1 east out, 2 east in, 4",
        "-- south out, 8 south in: a step you can walk), runs of four or more",
        "-- written %<digit><count>.",
        "-- dist: walking cost in yards between every two standing points of the",
        "-- zone (in Data/Exploration.lua order, every point of every node), from",
        "-- each to each, three base-36 digits per number.",
        "local _, ns = ...",
        "ns.TERRAIN = {",
    ]
    total_cells = 0
    for z in zones:
        c = z["continent"]
        if c not in conts:
            print(f"reading continent {c}...", flush=True)
            conts[c] = load_continent(cache, c)
        minX, minY, maxX, maxY = bounds(z["map"])
        w, h = maxY - minY, maxX - minX
        gx0, gy0, H, bad = zone_heights(conts[c], (minX, minY, maxX, maxY))
        east, west, south, north = node_rules(H, bad)
        ny, nx = east.shape
        digits = digits_of(east, west, south, north)
        total_cells += nx * ny
        # Point (0, 0) is the first chunk's top-left corner.
        x0 = (maxY - (32 * TILE - gx0 * CHUNK)) / w
        y0 = (maxX - (32 * TILE - gy0 * CHUNK)) / h
        cw, ch = NODE / w, NODE / h

        pts = [p for node in z["nodes"] for p in node]
        cells = []
        for fx, fy in pts:
            i = min(nx - 1, max(0, int(round((fx - x0) / cw))))
            j = min(ny - 1, max(0, int(round((fy - y0) / ch))))
            cells.append(j * nx + i)
        g = graph(east, west, south, north)
        uniq = sorted(set(cells))
        d = dijkstra(g, directed=True, indices=uniq)
        row = {cell: k for k, cell in enumerate(uniq)}
        dist = []
        for a in cells:
            for b in cells:
                v = d[row[a], b]
                if not np.isfinite(v):
                    v = 36 ** 3 - 1
                dist.append(b36(v))
        out.append(f"    [{z['ach']}] = {{ x0 = {x0:.7f}, y0 = {y0:.7f}, cw = {cw:.7f}, ch = {ch:.7f}, "
                   f"nx = {nx}, ny = {ny}, yd = {NODE:.4f},")
        out.append(f"        cells = \"{rle(digits)}\",")
        out.append(f"        dist = \"{''.join(dist)}\" }},")
        blocked = digits.count("0")
        print(f"  {z['name']:22} {nx}x{ny} points, {blocked} closed, {len(pts)} standing points", flush=True)
    out.append("}")
    with open(os.path.join(addon, "Data", "Terrain.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    print(f"terrain: {len(zones)} zones, {total_cells} points, "
          f"{os.path.getsize(os.path.join(addon, 'Data', 'Terrain.lua')) // 1024} KB")
    write_flights(cache, addon, bounds)
    return 0


# ---------------------------------------------------------------------------
# Flights
# ---------------------------------------------------------------------------

def write_flights(cache, addon, bounds):
    nodes = {r["ID"]: r for r in load(cache, "TaxiNodes")}
    paths = load(cache, "TaxiPath")
    pts = defaultdict(list)
    for r in load(cache, "TaxiPathNode"):
        pts[r["PathID"]].append((int(r["NodeIndex"]), float(r["Loc_0"]), float(r["Loc_1"]), float(r["Loc_2"])))
    length = {}
    for pid, l in pts.items():
        l.sort()
        length[pid] = sum(math.dist(a[1:], b[1:]) for a, b in zip(l, l[1:]))

    out = [
        "-- Generated by tools/build_terrain.py from the client's own tables. Do",
        "-- not edit by hand.",
        "--",
        "-- Every flight point on the two continents: its name as the flight map",
        "-- gives it, continent, faction (1 Alliance, 2 Horde, 3 both) and where it",
        "-- is as fractions of its continent's map. Then every direct flight:",
        "-- from, to, and its length in yards along the flight path.",
        "local _, ns = ...",
        "ns.FLIGHT_SPEED = 30   -- yards a second, the median of Chairface's flown times",
        "ns.FLIGHT_NODES = {",
    ]
    keep = set()
    for nid, n in sorted(nodes.items(), key=lambda kv: int(kv[0])):
        c = n["ContinentID"]
        side = int(n["Flags"]) & 3
        if c not in ("0", "1") or side == 0 or n["Name_lang"].startswith("zz"):
            continue
        minX, minY, maxX, maxY = bounds(CONTINENT_MAP[int(c)])
        x, y = float(n["Pos_0"]), float(n["Pos_1"])
        fx, fy = (maxY - y) / (maxY - minY), (maxX - x) / (maxX - minX)
        name = n["Name_lang"].replace('"', '\\"')
        out.append(f"    [{nid}] = {{ name = \"{name}\", continent = {c}, side = {side}, "
                   f"x = {fx:.5f}, y = {fy:.5f} }},")
        keep.add(nid)
    out.append("}")
    out.append("ns.FLIGHT_PATHS = {")
    n_paths = 0
    for p in paths:
        a, b = p["FromTaxiNode"], p["ToTaxiNode"]
        if a in keep and b in keep and p["ID"] in length:
            out.append(f"    {{ {a}, {b}, {round(length[p['ID']])} }},")
            n_paths += 1
    out.append("}")
    for c, ui in CONTINENT_MAP.items():
        minX, minY, maxX, maxY = bounds(ui)
        out.append(f"ns.CONTINENT_YARDS = ns.CONTINENT_YARDS or {{}}")
        out.append(f"ns.CONTINENT_YARDS[{c}] = {{ map = {ui}, w = {maxY - minY:.1f}, h = {maxX - minX:.1f} }}")
    with open(os.path.join(addon, "Data", "Flights.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    print(f"flights: {len(keep)} flight points, {n_paths} flights")


if __name__ == "__main__":
    sys.exit(main())
