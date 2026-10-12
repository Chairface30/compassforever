"""Copy hand-made walls, roads and spots from the saved settings into the
addon's data, for the zones named.

  python tools/bake_edits.py <CompassForever.lua saved variables> <zone ach> [...]

Walls and roads go to Data/Walls.lua and Data/Roads.lua, spots (each area's
moved spot, by criteria) to Data/Spots.lua. A zone already there is
replaced. In the game the saved copies of what was baked are dropped at
login (Spots.lua), so they don't show as the player's own.
"""
import os
import re
import sys

from lupa import lua51

ADDON = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def lua_table(rt, src, name):
    rt.execute(src)
    return rt.globals()[name]


def to_py(t):
    if t is None or isinstance(t, (int, float, str, bool)):
        return t
    keys = list(t.keys())
    if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
        return [to_py(t[k]) for k in sorted(keys)]
    return {k: to_py(v) for k, v in t.items()}


def fmt_num(v):
    return ("%.4f" % v).rstrip("0").rstrip(".") if isinstance(v, float) else str(v)


def fmt_line(line):
    if isinstance(line, dict) and "circle" in line:
        c = line["circle"]
        return "{ circle = { %s } }" % ", ".join(fmt_num(v) for v in c)
    return "{ " + ", ".join(fmt_num(v) for v in line) + " }"


def read_existing(path, var):
    """The zones a data file has now, as text blocks keyed by ach."""
    if not os.path.exists(path):
        return {}
    text = open(path, encoding="utf-8").read()
    out = {}
    for m in re.finditer(r"\n    \[(\d+)\] = \{\n(.*?)\n    \},", text, re.S):
        out[int(m.group(1))] = m.group(0)
    return out


def write_lines(path, var, header, blocks):
    body = "".join(blocks[k] for k in sorted(blocks))
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(header + "\nlocal _, ns = ...\n\nns.%s = {%s\n}\n" % (var, body))


def header_of(path):
    text = open(path, encoding="utf-8").read()
    return text.split("\nlocal _, ns = ...")[0]


def main():
    saved, achs = sys.argv[1], [int(a) for a in sys.argv[2:]]
    rt = lua51.LuaRuntime()
    db = to_py(lua_table(rt, open(saved, encoding="utf-8").read(), "CompassForeverDB"))

    # which criteria belong to which zone
    ex = lua51.LuaRuntime()
    ex.execute("NS = {} function load(f) return f end")
    src = open(os.path.join(ADDON, "Data", "Exploration.lua"), encoding="utf-8").read()
    ex.execute("local f = loadstring(...) f('CompassForever', NS)", src)
    zones = to_py(ex.eval("NS.ZONES"))
    criteria_of = {z["ach"]: {n["criteria"] for n in z["nodes"]} for z in zones}

    for kind, var, fname in (("walls", "WALLS", "Walls.lua"), ("roads", "ROADS", "Roads.lua")):
        path = os.path.join(ADDON, "Data", fname)
        blocks = read_existing(path, var)
        mine = db.get(kind) or {}
        for ach in achs:
            lines = mine.get(ach) or []
            if not lines:
                continue
            body = "".join("\n        %s," % fmt_line(l) for l in lines)
            blocks[ach] = "\n    [%d] = {%s\n    }," % (ach, body)
            print(f"{kind}: zone {ach}, {len(lines)}")
        write_lines(path, var, header_of(path), blocks)

    path = os.path.join(ADDON, "Data", "Spots.lua")
    spots = {}
    if os.path.exists(path):
        for m in re.finditer(r"\[(\d+)\] = \{ ([\d.]+), ([\d.]+) \}", open(path, encoding="utf-8").read()):
            spots[int(m.group(1))] = (float(m.group(2)), float(m.group(3)))
    for ach in achs:
        n = 0
        for crit, xy in (db.get("spots") or {}).items():
            if crit in criteria_of.get(ach, ()):
                spots[crit] = (xy[0], xy[1])
                n += 1
        print(f"spots: zone {ach}, {n}")
    body = "".join("\n    [%d] = { %s, %s }," % (c, fmt_num(spots[c][0]), fmt_num(spots[c][1])) for c in sorted(spots))
    header = ("-- Compass Forever: Data/Spots.lua\n"
              "-- Where each area's spot really is, found by running the zone: by the\n"
              "-- area's criteria ID, x, y on its zone's map. Used in place of the spots\n"
              "-- picked from the terrain (Spots.lua). Written by tools/bake_edits.py.\n")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(header + "\nlocal _, ns = ...\n\nns.SPOTS = {%s\n}\n" % body)


if __name__ == "__main__":
    main()
