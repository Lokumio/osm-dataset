-- The extract polygon, stored alongside the data it describes.
--
-- It is the fifth table and not a constant on the consumer side on purpose: add
-- cities to the extract and the coverage has to widen in the same transaction,
-- or a freshly imported city answers "no data for this area".
--
-- Called with: psql -v geojson=... -v extract_name=... -v imported_on=...

DROP TABLE IF EXISTS coverage;

CREATE TABLE coverage (
    extract_name text NOT NULL,
    imported_on  date NOT NULL,
    geom         geometry(MultiPolygon, 4326) NOT NULL
);

INSERT INTO coverage (extract_name, imported_on, geom)
SELECT :'extract_name',
       :'imported_on'::date,
       ST_Multi(ST_SetSRID(ST_GeomFromGeoJSON(:'geojson'), 4326));

CREATE INDEX coverage_geom_idx ON coverage USING gist (geom);
ANALYZE coverage;

SELECT 'coverage' AS what, count(*), extract_name, imported_on FROM coverage GROUP BY 3, 4;
