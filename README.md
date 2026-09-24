# osm-dataset

Turns an OpenStreetMap extract into four thin tables plus a coverage polygon, and
hands them over as a single `pg_dump --data-only` file.

This repository is the published transformation method required by
**ODbL 1.0 §4.6**: the extract polygon, the import date, the `osm2pgsql` version
and every script that shapes the raw planet data into what an application serves.

It knows nothing about any consumer. The pipeline ends at the dump file; which
database it lands in, under which schema, and when it starts being served are
decisions on the other side of that file.

## Current release

The map at [lokumio.pl](https://lokumio.pl) is served from the `pl20` extract,
imported on **2026-09-22**.

| | |
|---|---|
| extract | `pl20` — the 20 largest Polish cities plus a 20 km buffer, `poly/pl20.poly` |
| imported | 2026-09-22 |
| `osm2pgsql` | 2.3.1 |
| source | `poland-latest.osm.pbf` (Geofabrik) |
| source downloaded | 2026-09-06 |

Naming the extract and the import date is what ODbL §4.6 asks for: the method is
only reproducible against the input it actually ran on. **Update this block on
every import** — nothing verifies it automatically, so a stale block is a silent
one.

## What comes out

```
dataset/<extract>/<YYYYMMDD>/neighbourhood.dump   # pg_dump --data-only --format=custom
dataset/<extract>/<YYYYMMDD>/manifest.json        # row counts, source PBF, tool versions
```

| Table | What it holds |
|---|---|
| `poi` | named shops, pharmacies and green space, with a centroid and a `geography` |
| `pt_stop` | deduplicated stop nodes with the modes actually served (`bus`, `tram`, `rail`) |
| `pt_line` | one row per route relation — one direction variant of a line — with its merged geometry |
| `pt_line_stop` | ordered stop membership of that variant, taken from the relation itself |
| `coverage` | the extract polygon, so an empty answer can be told apart from missing data |

`poi.subtype` keeps the **raw OSM tag** (`convenience`, `bakery`, `park`, …). The
decision about what counts as, say, "everyday shopping" belongs to whoever reads
the data — encoding it here would turn every change of mind into a multi-hour
re-import.

`manifest.json` carries the row counts per table. That is the point of it: the
consumer compares them with what actually landed before serving anything, so an
interrupted `COPY` stops being invisible.

## Running it

Needs `osmium-tool`, `osm2pgsql`, `libpq` (for `psql`/`pg_dump`), `python3`, and
podman or docker.

```bash
brew install osmium-tool osm2pgsql libpq

make dataset EXTRACT=krakow   # ~5 min,  ~80 MB working database
make dataset EXTRACT=pl20     # ~35 min, ~3.4 GB working database
make dataset-all
```

The first run downloads `poland-latest.osm.pbf` from Geofabrik into `work/` and
caches it. Override with `SOURCE_URL=` or `SOURCE_PBF=`.

Both extracts come off the **same pipeline** and differ only in the polygon under
`poly/`. Building the development set a different way would mean clicking through
it locally said nothing about production.

## How it works

1. `osmium extract --polygon poly/<extract>.poly` cuts the area out of the planet file.
2. `osm2pgsql` runs twice over that extract, into a throwaway database on port 5545:
   - the default output, for `planet_osm_point` / `planet_osm_polygon`;
   - the flex style `lua/routes.lua`, for route relations **with their geometry**
     and their ordered node membership — both of which the default output discards.
3. `sql/build_coverage.sql` stores the same polygon as a row, so coverage is
   versioned together with the data it describes.
4. `sql/build_poi.sql` and `sql/build_transit.sql` build the five thin tables in
   schema `neighbourhood_import`.
5. `pg_dump --data-only` writes the dump; `scripts/manifest.py` writes the manifest.

The ~3.4 GB of `planet_osm_*` scratch tables never leave this machine. Only the
five thin tables are dumped.

### Why the stops come from relations and not from geometry

Attaching line numbers to a stop by looking for route ways within 40 m is an
approximation, and on a 20-city extract it is also unusably slow — the bounding
box of a whole route covers half a city, so the spatial index filters nothing.
`lua/routes.lua` reads the actual relation membership instead, which is both
exact and fast.

### Why the schema is called `neighbourhood_import`

A `--data-only` dump in custom format records the source schema name inside
itself, and `pg_restore` cannot rewrite it. A fixed, obviously-not-production name
makes that contract explicit: the consumer creates `neighbourhood_import`, fills
it, and renames it to whatever it actually serves from.

### Why there is no DDL in the dump

The dump carries rows only. The table definitions live with the consumer, which
is what lets the consumer decide which columns end up in its database. The cost is
that the two definitions can drift: an **added** column upstream breaks the
restore loudly, because the `COPY` names a column the target table does not have;
a **removed** one passes silently and stays NULL. The manifest row counts and a
not-all-NULL check on the consumer side are what catch the second case.

## Licence

Source data © OpenStreetMap contributors, licensed under the
[Open Database License 1.0](https://opendatacommons.org/licenses/odbl/1-0/).

The tables built here are a Derivative Database under ODbL §4.4(b). Anything
produced from them and used publicly triggers §4.4(c); §4.6 allows the *method*
to be published instead of the database, and this repository is that method.

The scripts themselves are released under the MIT licence (see `LICENSE`). The
data is not, and cannot be — ODbL travels with it.

**No OpenStreetMap data ships in this repository.** `dataset/` and `work/` are
gitignored, so what you clone is the method and nothing else. The polygons under
`poly/` are ours: `krakow.poly` is a four-corner box, and `pl20.poly` was built
in PostGIS by buffering a hand-written list of city centres, not cut from OSM
boundaries. MIT therefore covers every file here — and stops at the output,
which is a Derivative Database under ODbL the moment these scripts produce it.
