"""Build Data/Graph.lua: a waypoint graph per continent, from the terrain
grids in Data/Terrain.lua, so the game finds walking paths over a few
thousand waypoints instead of millions of terrain points.

Waypoints (continent grid points, 8.3 yards apart):
  - a lattice: one every LATTICE points (200 yards) each way, on the most
    walkable point near the lattice spot, over every zone's ground;
  - along the terrain's roads: one per ROAD_GAP points of road;
  - every standing point of every area (Data/Exploration.lua) and every
    moved spot (Data/Spots.lua);
  - every flight master (Data/Flights.lua) and zeppelin or boat dock
    (Crossing.lua).

Links: from every waypoint a terrain search (the same rules as the game's
old grid search: steep or lava steps cost PENALTY times their length, steps
along a road ROAD of theirs) out to LIMIT yards; each waypoint keeps its
cheapest links to the waypoints it reaches, up to KEEP of them, those whose
path is no more than DETOUR times the straight line (and always its MIN_KEEP
cheapest). A link whose path bends is stored with its turning points, so it
is drawn as walked.

Walls, roads drawn by hand and zone lines aren't used here: the game lays
them over the graph itself (Graph.lua), so they can change without a
rebuild.

  python tools/build_graph.py
"""
import math
import os
import re
import sys
import time

import numpy as np
from lupa import lua51
from scipy.sparse import csr_matrix
from scipy.sparse.csgraph import dijkstra

ADDON = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TILE = 1600.0 / 3.0
NODE = TILE / 64
PENALTY = 25
UNKNOWN = 5
ROAD = 0.7
LATTICE = 24          # points between lattice waypoints (200 yards)
ROAD_GAP = 8          # points of road between road waypoints (67 yards)
LIMIT = 520           # yards a link may cost
KEEP = 8
MIN_KEEP = 3
DETOUR = 1.35
BATCH = 6
SIMPLIFY = 1.2        # points off the line a bend may be before it's kept

DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"


def b36(n, width=3):
    n = int(n)
    assert 0 <= n < 36 ** width, n
    s = ""
    for _ in range(width):
        s = DIGITS[n % 36] + s
        n //= 36
    return s


def to_py(t):
    if t is None or isinstance(t, (int, float, str, bool)):
        return t
    keys = list(t.keys())
    if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
        return [to_py(t[k]) for k in sorted(keys)]
    return {k: to_py(v) for k, v in t.items()}


def load_ns():
    rt = lua51.LuaRuntime()
    rt.execute("NS = {} function GetTime() return 0 end function CreateFrame() return setmetatable({}, "
               "{ __index = function() return function() end end }) end")
    for f in ("Data/Exploration.lua", "Data/Flights.lua", "Data/Spots.lua", "Data/Terrain.lua", "Crossing.lua"):
        src = open(os.path.join(ADDON, f), encoding="utf-8").read()
        fn = rt.eval("function(s, n) local f, e = loadstring(s, n) if not f then error(e) end return f end")(src, f)
        fn("CompassForever", rt.globals().NS)
    return rt.globals().NS


def unrle(s, pat):
    return re.sub(pat, lambda m: m.group(1) * int(m.group(2)), s)


def build_continent(ns, c):
    cont = to_py(ns.CONTINENT_YARDS[c])
    zones = [z for z in to_py(ns.ZONES) if z["continent"] == c]
    terr = {}
    for z in zones:
        t = ns.TERRAIN[z["ach"]]
        if t is not None:
            terr[z["ach"]] = to_py(t)
    # the continent's extent, in grid points
    I0 = min(t["gx"] for t in terr.values())
    J0 = min(t["gy"] for t in terr.values())
    I1 = max(t["gx"] + t["nx"] for t in terr.values())
    J1 = max(t["gy"] + t["ny"] for t in terr.values())
    C, R = I1 - I0, J1 - J0
    cov = np.zeros((R, C), bool)
    E = np.zeros((R, C), bool); W = np.zeros((R, C), bool)
    S = np.zeros((R, C), bool); N = np.zeros((R, C), bool)
    sameE = np.zeros((R, C), bool); sameS = np.zeros((R, C), bool)
    road = np.zeros((R, C), bool)
    hexv = np.array([int(ch, 16) for ch in "0123456789abcdef"])
    for ach, t in terr.items():
        cells = unrle(t["cells"], r"%([0-9a-f])(\d+)\.")
        nx, ny = t["nx"], t["ny"]
        v = np.frombuffer(cells.encode(), dtype=np.uint8)
        v = np.where(v >= 97, v - 87, v - 48).reshape(ny, nx)
        i0, j0 = t["gx"] - I0, t["gy"] - J0
        win = (slice(j0, j0 + ny), slice(i0, i0 + nx))
        cov[win] = True
        E[win] |= (v & 1) > 0
        S[win] |= (v & 4) > 0
        # bit 2: the point east can step west into this one
        W[j0:j0 + ny, i0 + 1:i0 + nx] |= (v[:, :-1] & 2) > 0
        N[j0 + 1:j0 + ny, i0:i0 + nx] |= (v[:-1, :] & 8) > 0
        sameE[j0:j0 + ny, i0:i0 + nx - 1] = True
        sameS[j0:j0 + ny - 1, i0:i0 + nx] = True
        if t.get("roads"):
            r = unrle(t["roads"], r"%(\d)(\d+)\.")
            rv = (np.frombuffer(r.encode(), dtype=np.uint8) - 48).reshape(ny, nx) > 0
            road[win] |= rv
    print(f"continent {c}: {C} x {R} points, {cov.sum()} on maps", flush=True)

    idx = -np.ones((R, C), np.int64)
    idx[cov] = np.arange(cov.sum())
    rows, cols, vals = [], [], []

    def add(src_mask, sj, si, dj, di, good, same, length):
        # steps from (j, i) to (j + dj, i + di), both on a map
        js, is_ = np.nonzero(src_mask)
        tj, ti = js + dj, is_ + di
        keep = (tj >= 0) & (tj < R) & (ti >= 0) & (ti < C)
        js, is_, tj, ti = js[keep], is_[keep], tj[keep], ti[keep]
        keep = cov[tj, ti]
        js, is_, tj, ti = js[keep], is_[keep], tj[keep], ti[keep]
        g = good[js, is_]
        s = same[js, is_] if same is not None else np.ones(len(js), bool)
        cost = np.where(g, length, np.where(s, length * PENALTY, length * UNKNOWN))
        onroad = road[js, is_] & road[tj, ti]
        cost = np.where(onroad, cost * ROAD, cost)
        rows.append(idx[js, is_]); cols.append(idx[tj, ti]); vals.append(cost)

    sameW = np.zeros((R, C), bool); sameW[:, 1:] = sameE[:, :-1]
    sameN = np.zeros((R, C), bool); sameN[1:, :] = sameS[:-1, :]
    add(cov, 0, 0, 0, 1, E, sameE, NODE)
    add(cov, 0, 0, 0, -1, W, sameW, NODE)
    add(cov, 0, 0, 1, 0, S, sameS, NODE)
    add(cov, 0, 0, -1, 0, N, sameN, NODE)
    rule = {(1, 0): E, (-1, 0): W, (0, 1): S, (0, -1): N}
    for di in (1, -1):
        for dj in (1, -1):
            h, v = rule[(di, 0)], rule[(0, dj)]
            # way 1: across then along; way 2: along then across
            hs = np.zeros((R, C), bool); vs = np.zeros((R, C), bool)
            # v at (j, i + di)
            if di == 1: hs[:, :-1] = v[:, 1:]
            else: hs[:, 1:] = v[:, :-1]
            # h at (j + dj, i)
            if dj == 1: vs[:-1, :] = h[1:, :]
            else: vs[1:, :] = h[:-1, :]
            good = (h & hs) | (v & vs)
            add(cov, 0, 0, dj, di, good, None, NODE * math.sqrt(2))
    n = int(cov.sum())
    G = csr_matrix((np.concatenate(vals), (np.concatenate(rows), np.concatenate(cols))), shape=(n, n))
    print(f"  {G.nnz} steps", flush=True)

    outs = E.astype(int) + W + S + N

    # --- waypoints -----------------------------------------------------
    way = {}          # (i, j) continent grid point -> kind

    def put(i, j, kind):
        if (i, j) not in way:
            way[(i, j)] = kind

    def nearest_walkable(i, j, radius=6):
        best = None
        for dj in range(-radius, radius + 1):
            for di in range(-radius, radius + 1):
                a, b = i + di - I0, j + dj - J0
                if 0 <= a < C and 0 <= b < R and cov[b, a] and outs[b, a] >= 2:
                    d = di * di + dj * dj
                    if best is None or d < best[0]:
                        best = (d, i + di, j + dj)
        return (best[1], best[2]) if best else None

    # lattice: per block, the most walkable point nearest its middle
    L = LATTICE
    for bj in range(0, R, L):
        for bi in range(0, C, L):
            blk = cov[bj:bj + L, bi:bi + L] & (outs[bj:bj + L, bi:bi + L] >= 3)
            if not blk.any():
                continue
            jj, ii = np.nonzero(blk)
            cj, ci = (min(R, bj + L) - bj) / 2, (min(C, bi + L) - bi) / 2
            k = np.argmin((jj - cj) ** 2 + (ii - ci) ** 2)
            put(bi + ii[k] + I0, bj + jj[k] + J0, "l")
    lattice = len(way)
    # roads
    for bj in range(0, R, ROAD_GAP):
        for bi in range(0, C, ROAD_GAP):
            blk = road[bj:bj + ROAD_GAP, bi:bi + ROAD_GAP] & cov[bj:bj + ROAD_GAP, bi:bi + ROAD_GAP]
            if not blk.any():
                continue
            jj, ii = np.nonzero(blk)
            k = np.argmin((jj - ROAD_GAP / 2) ** 2 + (ii - ROAD_GAP / 2) ** 2)
            put(bi + ii[k] + I0, bj + jj[k] + J0, "r")
    roads = len(way) - lattice

    def zone_point(z, x, y):
        t = terr.get(z["ach"])
        if not t:
            return None
        return (int(round((x - t["x0"]) / t["cw"])) + t["gx"], int(round((y - t["y0"]) / t["ch"])) + t["gy"])

    def cont_point(x, y):
        wy = cont["maxY"] - x * cont["w"]
        wx = cont["maxX"] - y * cont["h"]
        return int(round((32 * TILE - wy) / NODE)), int(round((32 * TILE - wx) / NODE))

    special = 0
    spots = to_py(ns.SPOTS) or {}
    for z in zones:
        for node in z["nodes"]:
            p = node["points"]
            pts = [(p[k] / 10000, p[k + 1] / 10000) for k in range(0, len(p), 2)]
            if node.get("criteria") in spots:
                pts.append(tuple(spots[node["criteria"]]))
            for x, y in pts:
                q = zone_point(z, x, y)
                q = q and nearest_walkable(*q)
                if q:
                    put(q[0], q[1], "s"); special += 1
    for fid, f in (to_py(ns.FLIGHT_NODES) or {}).items():
        if f["continent"] == c:
            q = nearest_walkable(*cont_point(f["x"], f["y"]))
            if q:
                put(q[0], q[1], "f"); special += 1
    for x in to_py(ns.CROSSINGS) or []:
        for end in (x["a"], x["b"]):
            z = next((z for z in zones if z["map"] == end["map"]), None)
            if z:
                q = zone_point(z, end["x"], end["y"])
                q = q and nearest_walkable(*q)
                if q:
                    put(q[0], q[1], "d"); special += 1
    pts = sorted(way)
    print(f"  waypoints: {len(pts)} ({lattice} lattice, {roads} road, {special} spots, flight masters, docks)",
          flush=True)
    wid = {p: k for k, p in enumerate(pts)}
    cell_of = np.array([idx[j - J0, i - I0] for i, j in pts])
    way_at = -np.ones(n, np.int64)
    way_at[cell_of] = np.arange(len(pts))

    # --- links -------------------------------------------------------------
    links = {}        # (a, b) a < b -> [cost a->b or None, cost b->a or None, poly]
    started = time.time()
    for s0 in range(0, len(pts), BATCH):
        src = cell_of[s0:s0 + BATCH]
        dist, pred = dijkstra(G, directed=True, indices=src, limit=LIMIT, return_predecessors=True)
        for r in range(len(src)):
            a = s0 + r
            reach = np.nonzero(np.isfinite(dist[r]) & (way_at >= 0))[0]
            ai, aj = pts[a]
            cand = []
            for cell in reach:
                b = int(way_at[cell])
                if b == a:
                    continue
                bi, bj = pts[b]
                straight = math.hypot(bi - ai, bj - aj) * NODE
                cand.append((float(dist[r, cell]), straight, b, int(cell)))
            cand.sort()
            kept = [x for x in cand if x[0] <= DETOUR * x[1] + NODE][:KEEP]
            for x in cand[:MIN_KEEP]:
                if x not in kept:
                    kept.append(x)
            for cost, straight, b, cell in kept:
                key = (min(a, b), max(a, b))
                e = links.setdefault(key, [None, None, None])
                e[0 if a < b else 1] = cost
                if e[2] is None and cost > straight * 1.08 + NODE:
                    # the path, as grid points, from a to b
                    chain = [cell]
                    while chain[-1] != src[r]:
                        chain.append(int(pred[r, chain[-1]]))
                    chain.reverse()
                    e[2] = (a, chain)
        if (s0 // BATCH) % 200 == 0:
            done = s0 + len(src)
            el = time.time() - started
            print(f"  {done}/{len(pts)} waypoints, {el:.0f} s", flush=True)

    # cell number -> (i, j)
    cj, ci = np.nonzero(cov)
    cell_i, cell_j = ci + I0, cj + J0

    def simplify(points):
        if len(points) <= 2:
            return points
        (x0, y0), (x1, y1) = points[0], points[-1]
        dx, dy = x1 - x0, y1 - y0
        L2 = math.hypot(dx, dy) or 1
        far, fk = -1, 0
        for k in range(1, len(points) - 1):
            x, y = points[k]
            d = abs(dy * (x - x0) - dx * (y - y0)) / L2
            if d > far:
                far, fk = d, k
        if far <= SIMPLIFY:
            return [points[0], points[-1]]
        return simplify(points[:fk + 1])[:-1] + simplify(points[fk:])

    edges, polys = [], {}
    for (a, b), (ab, ba, poly) in sorted(links.items()):
        cost = ab if ba is None else ba if ab is None else (ab + ba) / 2
        k = len(edges)
        edges.append((a, b, int(round(cost))))
        if poly:
            frm, chain = poly
            line = simplify([(int(cell_i[q]), int(cell_j[q])) for q in chain])
            inner = line[1:-1]
            if inner:
                if frm != a:
                    inner.reverse()
                polys[k] = inner
    deg = np.zeros(len(pts), int)
    for a, b, _ in edges:
        deg[a] += 1; deg[b] += 1
    print(f"  links: {len(edges)} ({len(polys)} bent), lone waypoints: {(deg == 0).sum()}", flush=True)
    return pts, edges, polys


def main():
    ns = load_ns()
    out = ["-- Generated by tools/build_graph.py from Data/Terrain.lua. Do not edit by hand.",
           "--",
           "-- Per continent, the waypoint graph walking paths are found over (Graph.lua):",
           "-- n: waypoints, continent grid points i, j (8.3 yards apart), three base-36",
           "-- digits each; e: links, waypoint a, waypoint b (numbered from 0) and the",
           "-- walking cost in yards, three digits each; p: the turning points of links",
           "-- that bend (by link number, from 0), grid points as in n, from a to b.",
           "local _, ns = ...",
           "ns.GRAPH = {"]
    for c in (0, 1):
        pts, edges, polys = build_continent(ns, c)
        out.append(f"    [{c}] = {{")
        nodes = "".join(b36(i) + b36(j) for i, j in pts)
        out.append(f'        n = "{nodes}",')
        es = "".join(b36(a) + b36(b) + b36(min(cost, 36 ** 3 - 1)) for a, b, cost in edges)
        out.append(f'        e = "{es}",')
        out.append("        p = {")
        for k in sorted(polys):
            out.append(f'            [{k}] = "{"".join(b36(i) + b36(j) for i, j in polys[k])}",')
        out.append("        },")
        out.append("    },")
    out.append("}")
    path = os.path.join(ADDON, "Data", "Graph.lua")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    print(f"wrote {path} ({os.path.getsize(path) // 1024} KB)")


if __name__ == "__main__":
    main()
