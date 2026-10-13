"""Copy hand-made walls, roads and zone lines from the saved settings into
the addon's data, for the zones named.

  python tools/bake_edits.py <CompassForever.lua saved variables> <zone ach> [...] [--replace]

Walls, roads and zone lines go to Data/Walls.lua, Data/Roads.lua and
Data/ZoneLines.lua, added to what a zone has built in already (the saved
lines are only the player's own); with --replace, in place of them (a
zone redone from scratch). In the game the saved
copies of what was baked are dropped at login (Edits.lua), so they don't
show as the player's own.
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
    args = sys.argv[1:]
    # --replace: a zone redone from scratch; its saved lines take the place
    # of what it has built in, rather than being added to them
    replace = "--replace" in args
    args = [a for a in args if a != "--replace"]
    saved, achs = args[0], [int(a) for a in args[1:]]
    rt = lua51.LuaRuntime()
    db = to_py(lua_table(rt, open(saved, encoding="utf-8").read(), "CompassForeverDB"))

    for kind, var, fname in (("walls", "WALLS", "Walls.lua"), ("roads", "ROADS", "Roads.lua"),
                             ("zonelines", "ZONELINES", "ZoneLines.lua")):
        path = os.path.join(ADDON, "Data", fname)
        blocks = read_existing(path, var)
        mine = db.get(kind) or {}
        for ach in achs:
            lines = mine.get(ach) or []
            if not lines:
                continue
            # The saved lines are only the player's own: at login the game
            # drops their copies of what's built in. So they're added to a
            # zone's built-in lines, not put in place of them.
            have = [] if replace else re.findall(r"\n        (\{.*\}),", blocks.get(ach, ""))
            new = [t for t in (fmt_line(l) for l in lines) if t not in have]
            body = "".join("\n        %s," % t for t in have + new)
            blocks[ach] = "\n    [%d] = {%s\n    }," % (ach, body)
            print(f"{kind}: zone {ach}, {len(have)} built in + {len(new)} new")
        write_lines(path, var, header_of(path), blocks)

    # a zone taken back out to be redrawn (unbake.py) is built in again
    import unbake
    rpath = os.path.join(ADDON, "Data", "Returned.lua")
    returned = unbake.read_returned(rpath)
    if any(a in returned for a in achs):
        for a in achs:
            if returned.pop(a, None):
                print(f"zone {a}: no longer waiting in Data/Returned.lua")
        unbake.write_returned(rpath, returned)


if __name__ == "__main__":
    main()
