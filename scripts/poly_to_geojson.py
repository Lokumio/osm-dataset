#!/usr/bin/env python3
"""Convert an Osmosis .poly file into a GeoJSON MultiPolygon.

The same polygon does two jobs: osmium cuts the extract with it, and it lands in
the `coverage` table so the application can tell "nothing here" apart from "no
data for this area". Deriving one from the other keeps them from drifting.

Format: a name line, then one or more sections, each a section name (a leading
"!" marks a hole), a list of "lon lat" pairs, and END. A final END closes the file.
"""

import json
import sys
from typing import Any, Dict, List, Tuple

Ring = List[Tuple[float, float]]


def parse_poly(text: str) -> Tuple[List[Ring], List[Ring]]:
    lines = [line.strip() for line in text.splitlines()]
    outers: List[Ring] = []
    holes: List[Ring] = []
    index = 1  # line 0 is the file name

    while index < len(lines):
        header = lines[index]
        index += 1
        if header == "END" or not header:
            continue
        is_hole = header.startswith("!")
        ring: Ring = []
        while index < len(lines) and lines[index] != "END":
            if lines[index]:
                longitude, latitude = lines[index].split()
                ring.append((float(longitude), float(latitude)))
            index += 1
        index += 1  # consume END
        if len(ring) < 3:
            continue
        if ring[0] != ring[-1]:
            ring.append(ring[0])
        (holes if is_hole else outers).append(ring)

    return outers, holes


def ring_contains(outer: Ring, point: Tuple[float, float]) -> bool:
    inside = False
    for (x1, y1), (x2, y2) in zip(outer, outer[1:]):
        if (y1 > point[1]) != (y2 > point[1]):
            crossing = x1 + (point[1] - y1) / (y2 - y1) * (x2 - x1)
            if point[0] < crossing:
                inside = not inside
    return inside


def to_multipolygon(outers: List[Ring], holes: List[Ring]) -> Dict[str, Any]:
    polygons: List[List[Ring]] = [[outer] for outer in outers]
    for hole in holes:
        for polygon in polygons:
            if ring_contains(polygon[0], hole[0]):
                polygon.append(hole)
                break
    return {
        "type": "MultiPolygon",
        "coordinates": [[[list(point) for point in ring] for ring in polygon] for polygon in polygons],
    }


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: poly_to_geojson.py <file.poly>")
    outers, holes = parse_poly(open(sys.argv[1], encoding="utf-8").read())
    if not outers:
        raise SystemExit(f"{sys.argv[1]} contains no outer ring")
    json.dump(to_multipolygon(outers, holes), sys.stdout)


if __name__ == "__main__":
    main()
