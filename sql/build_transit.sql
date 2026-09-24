-- App-facing transit tables, built from the flex import (lua/routes.lua).
--
--   pt_line       one row per route relation = one direction variant of a line
--   pt_line_stop  ordered stops of that variant, from the relation itself
--   pt_stop       deduplicated stop nodes, with the modes actually served
--
-- Scope comes from the extract polygon in `coverage`, so the same file builds
-- Kraków and pl20. A line is kept when its geometry touches the polygon, and its
-- stops are kept in full — drawing a route must not stop at the border.

SET jit = off;

DROP TABLE IF EXISTS pt_line_stop, pt_line, pt_stop CASCADE;

CREATE TEMP VIEW extract_area AS SELECT geom FROM coverage LIMIT 1;

------------------------------------------------------------------------------
-- 1. Lines
------------------------------------------------------------------------------
CREATE TABLE pt_line AS
SELECT r.osm_id AS id,
       r.ref,
       r.mode,
       r.name,
       r.from_stop,
       r.to_stop,
       r.operator,
       round(ST_Length(r.geom::geography)::numeric) AS length_m,
       0 AS stop_count,
       r.geom
FROM pt_route_raw r, extract_area a
WHERE r.mode IN ('bus', 'tram')
  AND r.ref IS NOT NULL
  AND r.geom IS NOT NULL
  AND NOT ST_IsEmpty(r.geom)
  AND ST_Intersects(r.geom, a.geom);

ALTER TABLE pt_line ADD PRIMARY KEY (id);

------------------------------------------------------------------------------
-- 2. Ordered stops per line
--
-- A route relation lists every physical stop twice: once as a "stop" member (the
-- node on the roadway) and once as a "platform" member (the pole passengers
-- stand at). Keep the platform; fall back to the stop_position only where no
-- platform was mapped within 30 m.
------------------------------------------------------------------------------
CREATE TEMP TABLE member_geom AS
SELECT m.relation_id,
       m.seq,
       m.node_id,
       (m.role LIKE 'platform%') AS is_platform,
       s.geom
FROM pt_member_raw m
JOIN pt_line l ON l.id = m.relation_id
JOIN pt_stop_raw s ON s.osm_id = m.node_id;

CREATE INDEX member_geom_rel ON member_geom (relation_id);
CREATE INDEX member_geom_geom ON member_geom USING gist (geom);
ANALYZE member_geom;

CREATE TABLE pt_line_stop AS
WITH kept AS (
    SELECT g.*
    FROM member_geom g
    WHERE g.is_platform
       OR NOT EXISTS (
            SELECT 1
            FROM member_geom p
            WHERE p.relation_id = g.relation_id
              AND p.is_platform
              AND ST_DWithin(p.geom::geography, g.geom::geography, 30)
          )
)
SELECT relation_id                                                    AS line_id,
       row_number() OVER (PARTITION BY relation_id ORDER BY seq)::int AS seq,
       node_id                                                        AS stop_osm_id
FROM kept;

CREATE INDEX pt_line_stop_line_idx ON pt_line_stop (line_id, seq);
CREATE INDEX pt_line_stop_stop_idx ON pt_line_stop (stop_osm_id);

-- One line number has several variants; clicking it draws the widest one. The
-- count is a build-time fact, so the consumer never aggregates this table per
-- stop at query time.
UPDATE pt_line l
SET stop_count = counted.n
FROM (SELECT line_id, count(*)::int AS n FROM pt_line_stop GROUP BY line_id) counted
WHERE l.id = counted.line_id;

-- A variant with no stop members left after deduplication can never be drawn
-- usefully and would only dilute the widest-variant rule.
DELETE FROM pt_line WHERE stop_count = 0;
DELETE FROM pt_line_stop WHERE line_id NOT IN (SELECT id FROM pt_line);

------------------------------------------------------------------------------
-- 3. Stops
--
-- Kept when inside the extract polygon (so the radius search sees them) or when
-- a kept line stops there (so a drawn line always has all of its markers).
------------------------------------------------------------------------------
CREATE TABLE pt_stop AS
SELECT s.osm_id,
       s.name,
       CASE
           WHEN s.railway IN ('station', 'halt') THEN 'rail'
           WHEN s.railway = 'tram_stop' THEN 'tram'
           WHEN s.highway = 'bus_stop' THEN 'bus'
           ELSE NULL
       END                            AS tag_mode,
       ST_Y(s.geom)                   AS lat,
       ST_X(s.geom)                   AS lng,
       s.geom::geography(Point, 4326) AS geog,
       NULL::text[]                   AS modes
FROM pt_stop_raw s, extract_area a
WHERE ST_Intersects(s.geom, a.geom)
   OR s.osm_id IN (SELECT stop_osm_id FROM pt_line_stop);

ALTER TABLE pt_stop ADD PRIMARY KEY (osm_id);

-- Modes served, derived from the lines — more reliable than the node's own tag.
UPDATE pt_stop s
SET modes = served.modes
FROM (
    SELECT ls.stop_osm_id, array_agg(DISTINCT l.mode ORDER BY l.mode) AS modes
    FROM pt_line_stop ls
    JOIN pt_line l ON l.id = ls.line_id
    GROUP BY ls.stop_osm_id
) served
WHERE s.osm_id = served.stop_osm_id;

-- Rail is the case the tag has to carry: routes.lua collects bus and tram route
-- relations, so a station served only by trains has no line to derive from.
UPDATE pt_stop SET modes = ARRAY[tag_mode] WHERE modes IS NULL AND tag_mode IS NOT NULL;

-- A stop nothing serves and nothing tags is not a stop anyone can use.
DELETE FROM pt_stop WHERE modes IS NULL;

CREATE INDEX pt_stop_geog_idx ON pt_stop USING gist (geog);
CREATE INDEX pt_stop_modes_idx ON pt_stop USING gin (modes);

ANALYZE pt_line;
ANALYZE pt_line_stop;
ANALYZE pt_stop;

SELECT 'pt_line' AS what, count(*) FROM pt_line
UNION ALL SELECT 'pt_line_stop', count(*) FROM pt_line_stop
UNION ALL SELECT 'pt_stop', count(*) FROM pt_stop
UNION ALL SELECT 'pt_stop rail', count(*) FROM pt_stop WHERE 'rail' = ANY(modes);
