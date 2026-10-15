"""Take zones back out of the built-in lines, to be redrawn in the game.

  python tools/unbake.py <zone ach> [...]

Each zone's walls, roads, zone lines and ledges move from Data/Walls.lua,
Data/Roads.lua, Data/ZoneLines.lua and Data/Ledges.lua to Data/Returned.lua. At login the
game copies them into the player's own lines, once, and clears the zone's
done mark (Edits.lua). Baking the zone again (bake_edits.py --replace)
takes it out of Data/Returned.lua.
"""
import os
import re
import sys

import bake_edits as b

ADDON = b.ADDON
KINDS = (("walls", "Walls.lua", "WALLS"), ("roads", "Roads.lua", "ROADS"), ("zonelines", "ZoneLines.lua", "ZONELINES"),
         ("ledges", "Ledges.lua", "LEDGES"))
HEADER = [
    "-- Compass Forever: Data/Returned.lua",
    "-- Zones taken back out of the built-in lines to be redrawn: at login",
    "-- their lines become the player's own again, once, to edit (Edits.lua);",
    "-- baked again, a zone comes out of here. Written by tools/unbake.py.",
    "",
    "local _, ns = ...",
    "",
]


def read_returned(path):
    """{ ach: (name, { kind: [line text] }) } from Data/Returned.lua."""
    out = {}
    if not os.path.exists(path):
        return out
    text = open(path, encoding="utf-8").read()
    for m in re.finditer(r"\n    \[(\d+)\] = \{ -- (.*?)\n(.*?)\n    \},", text, re.S):
        kinds = {}
        for k in re.finditer(r"        (\w+) = \{\n(.*?)\n        \},", m.group(3), re.S):
            kinds[k.group(1)] = re.findall(r"            (\{.*\}),", k.group(2))
        out[int(m.group(1))] = (m.group(2), kinds)
    return out


def write_returned(path, zones):
    lines = HEADER + ["ns.RETURNED = {"]
    for ach in sorted(zones):
        name, kinds = zones[ach]
        lines.append(f"    [{ach}] = {{ -- {name}")
        for kind, _, _ in KINDS:
            if kinds.get(kind):
                lines.append(f"        {kind} = {{")
                lines += [f"            {t}," for t in kinds[kind]]
                lines.append("        },")
        lines.append("    },")
    lines.append("}")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def zone_names():
    src = open(os.path.join(ADDON, "Data", "Exploration.lua"), encoding="utf-8").read()
    return {int(a): n for a, n in re.findall(r'\{ ach = (\d+), map = \d+, name = "(.*?)"', src)}


def main():
    achs = [int(a) for a in sys.argv[1:]]
    names = zone_names()
    path = os.path.join(ADDON, "Data", "Returned.lua")
    returned = read_returned(path)
    for ach in achs:
        kinds = returned.get(ach, (names.get(ach, "?"), {}))[1]
        for kind, fname, var in KINDS:
            dpath = os.path.join(ADDON, "Data", fname)
            blocks = b.read_existing(dpath, var)
            blk = blocks.pop(ach, None)
            if blk:
                kinds[kind] = kinds.get(kind, []) + re.findall(r"\n        (\{.*\}),", blk)
                b.write_lines(dpath, var, b.header_of(dpath), blocks)
        returned[ach] = (names.get(ach, "?"), kinds)
        print(f"{names.get(ach, ach)}: " + ", ".join(f"{len(v)} {k}" for k, v in kinds.items()))
    write_returned(path, returned)


if __name__ == "__main__":
    main()
