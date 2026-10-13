"""Build Data/Exploration.lua from the files
fetch_terrain.py downloaded.

Exploration: each "Explore <zone>" achievement lists, as criteria, the world
map overlays it needs (criteria type 43, asset = WorldMapOverlay ID). An
overlay is uncovered by standing in any of the areas it names (AreaID_0..3).
The terrain says which 33-yard chunk belongs to which area, so for every
overlay this finds the chunks of its areas and picks standing points:

  - well inside: as many chunks from the area's edge as the area allows
    (an edge chunk can be half someone else's ground once WMOs are counted);
  - flat: a chunk whose corners differ by less than CLIFF yards, so the spot
    is ground you can walk onto, not a cliff face;
  - spread out: up to CANDIDATES points far from each other, so the route
    planner in game can take whichever one is on its way.

A point is a fraction of the zone's own world map, the same numbers
C_Map.GetPlayerMapPosition gives, so the addon needs no world maths.

Usage: python build_data.py <cache dir> <addon dir>
"""
import csv
import math
import os
import struct
import sys
from collections import defaultdict, deque

TILE = 1600.0 / 3.0          # yards per ADT tile
CHUNK = TILE / 16.0          # yards per chunk
CANDIDATES = 5
CLIFF = 25.0                 # yards of height difference across a chunk

EXPLORE_CATS = {14777: 0, 14778: 1}      # Eastern Kingdoms, Kalimdor -> map ID


def load(cache, name):
    with open(os.path.join(cache, "db2", name + ".csv"), encoding="utf-8") as f:
        return list(csv.DictReader(f))


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


# ---------------------------------------------------------------------------
# Terrain
# ---------------------------------------------------------------------------

def read_tile(path):
    """[(chunkX, chunkY, areaID, relief)] for one root ADT."""
    data = open(path, "rb").read()
    out = []
    pos = 0
    while pos + 8 <= len(data):
        magic = data[pos:pos + 4][::-1]
        size = struct.unpack_from("<I", data, pos + 4)[0]
        body = pos + 8
        if magic == b"MCNK":
            ix, iy = struct.unpack_from("<II", data, body + 4)
            area = struct.unpack_from("<I", data, body + 0x34)[0]
            relief = 0.0
            # Sub-chunks follow the 0x80-byte header; MCVT is 145 heights.
            sub = body + 0x80
            end = body + size
            while sub + 8 <= end:
                smagic = data[sub:sub + 4][::-1]
                ssize = struct.unpack_from("<I", data, sub + 4)[0]
                if smagic == b"MCVT":
                    h = struct.unpack_from("<145f", data, sub + 8)
                    relief = max(h) - min(h)
                    break
                sub += 8 + ssize
            out.append((ix, iy, area, relief))
        pos = body + size
    return out


def load_terrain(cache, mapID):
    """{(gx, gy): (area, relief)} on a 1024x1024 chunk grid per continent.
    gx grows east... no: gx grows WEST->EAST with the tile's first index and
    chunk column, gy NORTH->SOUTH with the second index and chunk row."""
    d = os.path.join(cache, f"map{mapID}")
    grid = {}
    for name in os.listdir(d):
        if not name.endswith(".adt"):
            continue
        tx, ty = (int(v) for v in name[:-4].split("_"))
        for ix, iy, area, relief in read_tile(os.path.join(d, name)):
            grid[(tx * 16 + ix, ty * 16 + iy)] = (area, relief)
    return grid


def chunk_world(gx, gy):
    """World (X north, Y west) of a chunk's centre. 32 tiles from the edge is
    the world origin; X falls with the row, Y with the column."""
    wx = 32 * TILE - (gy + 0.5) * CHUNK
    wy = 32 * TILE - (gx + 0.5) * CHUNK
    return wx, wy


# ---------------------------------------------------------------------------
# Standing points
# ---------------------------------------------------------------------------

def depth_map(cells):
    """Chunks from the nearest chunk that is NOT in `cells` (8-neighbour
    steps). An edge chunk is 1."""
    depth = {}
    q = deque()
    for c in cells:
        x, y = c
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                if (x + dx, y + dy) not in cells:
                    depth[c] = 1
                    q.append(c)
                    break
            if c in depth:
                break
    while q:
        c = q.popleft()
        x, y = c
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                n = (x + dx, y + dy)
                if n in cells and n not in depth:
                    depth[n] = depth[c] + 1
                    q.append(n)
    return depth


def pick_points(cells, terrain, inside):
    """Up to CANDIDATES chunks: the best-placed first, then the ones farthest
    from those already picked. `inside(c)` says the chunk is on the zone map."""
    cells = {c for c in cells if inside(c)}
    if not cells:
        return []
    depth = depth_map(cells)
    best = max(depth.values())
    want = min(best, 3)

    def score(c):
        flat = terrain[c][1] < CLIFF
        return (min(depth[c], 3), flat, -terrain[c][1])

    pool = [c for c in cells if depth[c] >= want and terrain[c][1] < CLIFF]
    if not pool:
        pool = [c for c in cells if depth[c] >= want]
    first = max(pool, key=score)
    picked = [first]
    while len(picked) < CANDIDATES:
        far = max(pool, key=lambda c: min((c[0] - p[0]) ** 2 + (c[1] - p[1]) ** 2 for p in picked))
        gap = min(math.hypot(far[0] - p[0], far[1] - p[1]) for p in picked)
        if gap < 4:          # under ~130 yards from one already picked
            break
        picked.append(far)
    return picked, len(cells), best


# ---------------------------------------------------------------------------
# Tables
# ---------------------------------------------------------------------------

def criteria_children(trees):
    kids = defaultdict(list)
    for t in trees:
        kids[t["Parent"]].append(t)
    for v in kids.values():
        v.sort(key=lambda t: int(t["OrderIndex"]))
    return kids


def leaf_criteria(tree_id, kids, crit):
    """Every criteria leaf under a criteria tree, with its tree description."""
    out = []
    for t in kids.get(tree_id, []):
        c = crit.get(t["CriteriaID"])
        if c and t["CriteriaID"] != "0":
            out.append((t, c))
        out.extend(leaf_criteria(t["ID"], kids, crit))
    return out


def map_only_overlays(overlays, art_id, used_live, art):
    """The overlays of a zone's current map art that no criterion's overlay
    matched, with art to show (some have none and never draw), by ID."""
    out = [o for o in overlays.values()
           if o["UiMapArtID"] == art_id and o["ID"] not in used_live
           and int(o["TextureWidth"]) > 0 and art.get(o["ID"])]
    return sorted(out, key=lambda o: int(o["ID"]))


def main():
    cache, addon = sys.argv[1], sys.argv[2]
    ach = {a["ID"]: a for a in load(cache, "Achievement")}
    crit = {c["ID"]: c for c in load(cache, "Criteria")}
    kids = criteria_children(load(cache, "CriteriaTree"))
    overlays = {o["ID"]: o for o in load(cache, "WorldMapOverlay")}
    # Each overlay's art: its tiles' file IDs, row by row (layer 0).
    tiles = defaultdict(list)
    for t in load(cache, "WorldMapOverlayTile"):
        if t["LayerIndex"] == "0":
            tiles[t["WorldMapOverlayID"]].append((int(t["RowIndex"]), int(t["ColIndex"]), int(t["FileDataID"])))
    art = {k: [f for _, _, f in sorted(v)] for k, v in tiles.items()}
    # Forever redrew the zone maps: each zone has new art with new overlays,
    # while the achievements still name the old ones. The old art's zone comes
    # from the Classic Era table, and each old overlay is matched to the new
    # overlay of the same areas, whose offsets the live map hands back.
    current = {r["UiMapID"]: r["UiMapArtID"] for r in load(cache, "UiMapXMapArt")}
    art_to_map = {r["UiMapArtID"]: r["UiMapID"] for r in load(cache, "UiMapXMapArt_era")}
    art_to_map.update({art: ui for ui, art in current.items()})
    new_by_area = {}
    for o in overlays.values():
        new_by_area.setdefault((o["UiMapArtID"], o["AreaID_0"]), o)
    uimaps = {u["ID"]: u for u in load(cache, "UiMap")}
    areas = {a["ID"]: a for a in load(cache, "AreaTable")}
    assign = {}
    for r in load(cache, "UiMapAssignment"):
        if r["OrderIndex"] == "0" and r["MapID"] in ("0", "1"):
            assign.setdefault(r["UiMapID"], r)

    terrain = {0: load_terrain(cache, 0), 1: load_terrain(cache, 1)}
    by_area = {0: defaultdict(set), 1: defaultdict(set)}
    for m, grid in terrain.items():
        for c, (area, _) in grid.items():
            by_area[m][area].add(c)

    zones = []
    report = []
    for a in sorted(ach.values(), key=lambda a: a["Title_lang"]):
        if a["Category"] not in map(str, EXPLORE_CATS):
            continue
        leaves = leaf_criteria(a["Criteria_tree"], kids, crit)
        if not leaves or any(c["Type"] != "43" for _, c in leaves):
            continue                      # the continent rollups, not a zone
        mapID = EXPLORE_CATS[int(a["Category"])]
        first = overlays[leaves[0][1]["Asset"]]
        ui = art_to_map[first["UiMapArtID"]]
        asg = assign[ui]
        minX, minY = float(asg["Region_0"]), float(asg["Region_1"])
        maxX, maxY = float(asg["Region_3"]), float(asg["Region_4"])
        w, h = maxY - minY, maxX - minX

        def to_map(c):
            wx, wy = chunk_world(*c)
            return (maxY - wy) / w, (maxX - wx) / h

        def inside(c):
            fx, fy = to_map(c)
            return 0 <= fx <= 1 and 0 <= fy <= 1

        nodes = []
        used_live = set()
        for t, c in leaves:
            o = overlays[c["Asset"]]
            live = new_by_area.get((current.get(ui), o["AreaID_0"]), o)
            used_live.add(live["ID"])
            # a piece the redrawn map renamed (Gates of Ironforge is its
            # Ironforge) sits where the old one did: the same piece, not new
            for n in overlays.values():
                if (n["UiMapArtID"] == current.get(ui) and n["OffsetX"] == o["OffsetX"]
                        and n["OffsetY"] == o["OffsetY"]):
                    used_live.add(n["ID"])
            # The spots come from the areas both overlays name: the one the
            # achievement checks and the one the map shows now. They can differ
            # (the achievement's Drygulch Ravine also takes Razorwind Canyon, the
            # map's does not), and a spot in only one ticks the criterion but
            # leaves the map covered, or the reverse. With none in common, the
            # achievement's areas.
            old_ids = [o[f"AreaID_{i}"] for i in range(4) if o[f"AreaID_{i}"] != "0"]
            live_ids = {live[f"AreaID_{i}"] for i in range(4) if live[f"AreaID_{i}"] != "0"}
            ids = [x for x in old_ids if x in live_ids] or old_ids
            cells = set()
            for aid in ids:
                cells |= by_area[mapID].get(int(aid), set())
            picked = pick_points(cells, terrain[mapID], inside) if cells else []
            if picked:
                pts, count, best = picked
                coords = [to_map(p) for p in pts]
                how = "terrain"
            else:
                # No terrain carries the area (a WMO-only area, or ground off
                # this zone's map): the middle of the overlay art, marked rough.
                cx = (int(live["OffsetX"]) + int(live["TextureWidth"]) / 2) / 1002
                cy = (int(live["OffsetY"]) + int(live["TextureHeight"]) / 2) / 668
                coords, count, best, how = [(cx, cy)], 0, 0, "overlay"
            nodes.append({"overlay": int(o["ID"]), "criteria": int(c["ID"]),
                          "name": t["Description_lang"] or areas.get(ids[0], {}).get("AreaName_lang", "?"),
                          "areas": [int(x) for x in ids], "points": coords,
                          "ox": int(live["OffsetX"]), "oy": int(live["OffsetY"]),
                          # A new overlay with no tiles yet (Zul'Gurub) keeps the
                          # old art, which sits at the same spot.
                          "tw": int((live if art.get(live["ID"]) else o)["TextureWidth"]),
                          "th": int((live if art.get(live["ID"]) else o)["TextureHeight"]),
                          "files": art.get(live["ID"]) or art.get(o["ID"], []), "rough": how != "terrain"})
            report.append(f"{uimaps[ui]['Name_lang']:22} {nodes[-1]['name']:32} {how:8} chunks={count:5} depth={best}"
                          f" at {coords[0][0]*100:5.1f},{coords[0][1]*100:5.1f}")
        # Pieces of the redrawn map no criterion names (areas Forever added,
        # Shen'dralas's middle): the map stays covered there until they're
        # walked too, so they're areas of their own, read off the map only.
        for o in map_only_overlays(overlays, current.get(ui), used_live, art):
            ids = [o[f"AreaID_{i}"] for i in range(4) if o[f"AreaID_{i}"] != "0"]
            cells = set()
            for aid in ids:
                cells |= by_area[mapID].get(int(aid), set())
            picked = pick_points(cells, terrain[mapID], inside) if cells else []
            if not picked:
                continue
            pts, count, best = picked
            coords = [to_map(p) for p in pts]
            nodes.append({"overlay": int(o["ID"]), "criteria": None, "mapOnly": True,
                          "name": areas.get(ids[0], {}).get("AreaName_lang", "?"),
                          "areas": [int(x) for x in ids], "points": coords,
                          "ox": int(o["OffsetX"]), "oy": int(o["OffsetY"]),
                          "tw": int(o["TextureWidth"]), "th": int(o["TextureHeight"]),
                          "files": art[o["ID"]], "rough": False})
            report.append(f"{uimaps[ui]['Name_lang']:22} {nodes[-1]['name']:32} map only chunks={count:5} depth={best}"
                          f" at {coords[0][0]*100:5.1f},{coords[0][1]*100:5.1f}")
        zones.append({"ach": int(a["ID"]), "ui": int(ui), "name": uimaps[ui]["Name_lang"],
                      "continent": mapID, "w": w, "h": h, "nodes": nodes})

    write_exploration(addon, zones)
    with open(os.path.join(addon, "tools", "exploration_report.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(report) + "\n")
    rough = sum(1 for z in zones for n in z["nodes"] if n["rough"])
    print(f"{len(zones)} zones, {sum(len(z['nodes']) for z in zones)} areas, {rough} without terrain")
    return 0


def write_exploration(addon, zones):
    lines = [
        "-- Generated by tools/build_data.py from the client's own tables and",
        "-- terrain. Do not edit by hand.",
        "--",
        "-- One entry per \"Explore <zone>\" achievement. Each node is one world map",
        "-- overlay the achievement needs: its criteria ID, its overlay ID, its name,",
        "-- and standing points on the zone's map (fractions x 10000, x then y).",
        "-- ox, oy, tw, th and files are its map art: where it sits on the zone map",
        "-- (in map art pixels), its size, and its tiles' file IDs row by row, so a",
        "-- covered area can still be drawn (gray) on the map.",
        "-- A node whose area has no terrain of its own is marked rough = true: its",
        "-- point is the middle of the map art, not a checked spot.",
        "-- A node marked mapOnly = true has no criterion: a piece of the redrawn",
        "-- map the achievement doesn't name, uncovered on the map all the same.",
        "-- Those come after a zone's others, so the points before keep their order.",
        "local _, ns = ...",
        "ns.ZONES = {",
    ]
    for z in sorted(zones, key=lambda z: (z["continent"], z["name"])):
        lines.append(f"    {{ ach = {z['ach']}, map = {z['ui']}, name = {lua_str(z['name'])}, "
                     f"continent = {z['continent']}, w = {z['w']:.1f}, h = {z['h']:.1f}, nodes = {{")
        for n in z["nodes"]:
            pts = ", ".join(f"{round(x * 10000)}, {round(y * 10000)}" for x, y in n["points"])
            rough = ", rough = true" if n["rough"] else ""
            first = (f"criteria = {n['criteria']}, overlay = {n['overlay']}, " if n["criteria"] is not None
                     else f"overlay = {n['overlay']}, mapOnly = true, ")
            lines.append(f"        {{ {first}"
                         f"ox = {n['ox']}, oy = {n['oy']}, tw = {n['tw']}, th = {n['th']}, "
                         f"files = {{ {', '.join(str(f) for f in n['files'])} }}, name = {lua_str(n['name'])}, points = {{ {pts} }}{rough} }},")
        lines.append("    } },")
    lines.append("}")
    with open(os.path.join(addon, "Data", "Exploration.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    sys.exit(main())
