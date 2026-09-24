#!/usr/bin/env bash
#
# Build one dataset: OpenStreetMap PBF -> PostGIS -> data-only dump.
#
#   scripts/build.sh krakow
#   scripts/build.sh pl20
#
# The repository ends at the dump file. What happens to it afterwards — which
# database, which schema, when it starts being served — is the consumer's
# business, and this repo knows nothing about any consumer.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTRACT="${1:-krakow}"
POLY="$ROOT/poly/$EXTRACT.poly"
WORK="$ROOT/work"
BUILD_DATE="${BUILD_DATE:-$(date +%Y%m%d)}"
OUT="$ROOT/dataset/$EXTRACT/$BUILD_DATE"

SOURCE_URL="${SOURCE_URL:-https://download.geofabrik.de/europe/poland-latest.osm.pbf}"
SOURCE_PBF="${SOURCE_PBF:-$WORK/$(basename "$SOURCE_URL")}"

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5545}"
PGUSER="${PGUSER:-osmdata}"
PGPASSWORD="${PGPASSWORD:-osmdata}"
PGDATABASE="osm_build_$EXTRACT"
export PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE

# The consumer restores a data-only dump, which carries the source schema name
# inside it. Building into a fixed, obviously-not-production name keeps that
# contract explicit on both sides.
BUILD_SCHEMA="neighbourhood_import"

CONTAINER="osm-dataset-postgis"
DOCKER="$(command -v podman || command -v docker)"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo ">> $*"; }

for tool in osmium osm2pgsql psql pg_dump python3; do
    command -v "$tool" >/dev/null || die "$tool is not installed (brew install osmium-tool osm2pgsql libpq)"
done
[ -f "$POLY" ] || die "no polygon at $POLY"
[ -n "$DOCKER" ] || die "neither podman nor docker found"

mkdir -p "$WORK" "$OUT"

note "starting the working database"
"$DOCKER" start "$CONTAINER" >/dev/null 2>&1 || ( cd "$ROOT" && "$DOCKER" compose up -d )
# Not pg_isready: during initdb the container answers on a temporary socket that
# the published port does not reach yet, so it reports ready and the next command
# still dies on "server closed the connection unexpectedly". Ask over the port we
# are actually going to use.
for _ in $(seq 1 90); do
    psql -X -q -d postgres -c 'SELECT 1' >/dev/null 2>&1 && break
    sleep 1
done
psql -X -q -d postgres -c 'SELECT 1' >/dev/null 2>&1 \
    || die "the working database did not accept a connection on $PGHOST:$PGPORT"

if [ ! -f "$SOURCE_PBF" ]; then
    note "downloading $SOURCE_URL (this is the slow part, and it is cached in work/)"
    curl -fL --progress-bar -o "$SOURCE_PBF" "$SOURCE_URL"
fi

EXTRACT_PBF="$WORK/$EXTRACT.osm.pbf"
note "cutting $EXTRACT out of $(basename "$SOURCE_PBF")"
osmium extract --overwrite --polygon "$POLY" -o "$EXTRACT_PBF" "$SOURCE_PBF"

note "recreating $PGDATABASE"
psql -v ON_ERROR_STOP=1 -X -q -d postgres -c "DROP DATABASE IF EXISTS \"$PGDATABASE\"" >/dev/null
psql -v ON_ERROR_STOP=1 -X -q -d postgres -c "CREATE DATABASE \"$PGDATABASE\"" >/dev/null
psql -v ON_ERROR_STOP=1 -X -q -c "CREATE EXTENSION IF NOT EXISTS postgis" >/dev/null
psql -v ON_ERROR_STOP=1 -X -q -c "CREATE SCHEMA $BUILD_SCHEMA" >/dev/null

# Two osm2pgsql runs, two independent sets of tables. The default output gives
# shops and green space; the flex style gives what the default output throws
# away — route relations with their geometry and their ordered membership.
note "importing points and polygons"
osm2pgsql --create --slim --drop --latlong --cache 1500 --database "$PGDATABASE" "$EXTRACT_PBF"

note "importing public transport relations"
osm2pgsql --create --slim --drop --output=flex --style "$ROOT/lua/routes.lua" \
    --cache 1500 --database "$PGDATABASE" "$EXTRACT_PBF"

GEOJSON="$(python3 "$ROOT/scripts/poly_to_geojson.py" "$POLY")"

export PGOPTIONS="--search_path=$BUILD_SCHEMA,public"
note "building coverage"
psql -v ON_ERROR_STOP=1 -X -q \
    -v "geojson=$GEOJSON" -v "extract_name=$EXTRACT" -v "imported_on=$BUILD_DATE" \
    -f "$ROOT/sql/build_coverage.sql"
note "building poi"
psql -v ON_ERROR_STOP=1 -X -q -f "$ROOT/sql/build_poi.sql"
note "building transit"
psql -v ON_ERROR_STOP=1 -X -q -f "$ROOT/sql/build_transit.sql"
unset PGOPTIONS

note "dumping"
# pg_dump from inside the container, not from the host. A dump written by a newer
# pg_dump than the target server carries settings the server has never heard of
# ("unrecognized configuration parameter transaction_timeout"), and the host's
# libpq version is nobody's decision. The container's version is pinned in
# docker-compose.yml and matches what this data is restored into.
"$DOCKER" exec -e PGPASSWORD="$PGPASSWORD" "$CONTAINER" \
    pg_dump --data-only --format=custom --no-owner --no-privileges \
    --schema "$BUILD_SCHEMA" -U "$PGUSER" -d "$PGDATABASE" > "$OUT/neighbourhood.dump"

python3 "$ROOT/scripts/manifest.py" \
    --extract "$EXTRACT" \
    --imported-on "$BUILD_DATE" \
    --source-pbf "$SOURCE_PBF" \
    --schema "$BUILD_SCHEMA" \
    --output "$OUT/manifest.json"

note "done:"
ls -lh "$OUT"
