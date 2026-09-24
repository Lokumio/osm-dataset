-- Thin POI table: everything a person might walk to, with the raw tag kept.
--
--   category  the OpenStreetMap KEY   (shop / amenity / leisure / tourism)
--   subtype   the OpenStreetMap VALUE (supermarket / restaurant / park / …)
--
-- Deciding here that a bakery is "everyday shopping" and a dentist is "health"
-- would make every change of mind a multi-hour re-import. The consumer groups the
-- raw pairs at query time instead, so regrouping is a deploy.
--
-- Everything named is kept except pure street furniture: a bench, a waste basket
-- and a parking space are not places anyone walks to, and they outnumber the
-- places that are.

SET jit = off;

DROP TABLE IF EXISTS poi;

CREATE TABLE poi (
    id       bigint NOT NULL,
    category text NOT NULL,
    subtype  text,
    name     text,
    lat      double precision NOT NULL,
    lng      double precision NOT NULL,
    geog     geography(Geometry, 4326) NOT NULL
);

CREATE TEMP VIEW excluded_subtype AS
SELECT unnest(ARRAY[
    -- street furniture and infrastructure
    'parking', 'parking_space', 'parking_entrance', 'bicycle_parking',
    'motorcycle_parking', 'bicycle_repair_station', 'charging_station',
    'vending_machine', 'recycling', 'waste_basket', 'waste_disposal',
    'waste_transfer_station', 'bench', 'shelter', 'drinking_water', 'toilets',
    'telephone', 'clock', 'fountain', 'grit_bin', 'hunting_stand', 'water_point',
    'watering_place', 'letter_box', 'post_box', 'parcel_locker', 'lounger',
    'street_lamp', 'surveillance', 'traffic_signals',
    -- signage and boundaries rather than destinations
    'information', 'checkpoint', 'picnic_site', 'viewpoint', 'wilderness_hut',
    -- accommodation: not a neighbourhood amenity for somebody buying a flat
    'hotel', 'hostel', 'motel', 'guest_house', 'apartment', 'chalet',
    'caravan_site', 'camp_site',
    -- land use that happens to be tagged leisure
    'common', 'outdoor_seating', 'bleachers', 'firepit', 'slipway'
]) AS subtype;

INSERT INTO poi (id, category, subtype, name, lat, lng, geog)
SELECT row_number() OVER () AS id, category, subtype, name, lat, lng, geog
FROM (
    SELECT 'shop' AS category, shop AS subtype, name,
           ST_Y(ST_Centroid(way)) AS lat, ST_X(ST_Centroid(way)) AS lng,
           way::geography AS geog
    FROM planet_osm_point WHERE shop IS NOT NULL
    UNION ALL
    SELECT 'shop', shop, name, ST_Y(ST_Centroid(way)), ST_X(ST_Centroid(way)), way::geography
    FROM planet_osm_polygon WHERE shop IS NOT NULL

    UNION ALL
    SELECT 'amenity', amenity, name, ST_Y(ST_Centroid(way)), ST_X(ST_Centroid(way)), way::geography
    FROM planet_osm_point WHERE amenity IS NOT NULL
    UNION ALL
    SELECT 'amenity', amenity, name, ST_Y(ST_Centroid(way)), ST_X(ST_Centroid(way)), way::geography
    FROM planet_osm_polygon WHERE amenity IS NOT NULL

    UNION ALL
    SELECT 'leisure', leisure, name, ST_Y(ST_Centroid(way)), ST_X(ST_Centroid(way)), way::geography
    FROM planet_osm_point WHERE leisure IS NOT NULL
    UNION ALL
    SELECT 'leisure', leisure, name, ST_Y(ST_Centroid(way)), ST_X(ST_Centroid(way)), way::geography
    FROM planet_osm_polygon WHERE leisure IS NOT NULL

    UNION ALL
    SELECT 'tourism', tourism, name, ST_Y(ST_Centroid(way)), ST_X(ST_Centroid(way)), way::geography
    FROM planet_osm_point WHERE tourism IS NOT NULL
    UNION ALL
    SELECT 'tourism', tourism, name, ST_Y(ST_Centroid(way)), ST_X(ST_Centroid(way)), way::geography
    FROM planet_osm_polygon WHERE tourism IS NOT NULL
) source
WHERE name IS NOT NULL
  AND subtype IS NOT NULL
  AND subtype NOT IN (SELECT subtype FROM excluded_subtype);

ALTER TABLE poi ADD PRIMARY KEY (id);
CREATE INDEX poi_geog_idx ON poi USING gist (geog);
ANALYZE poi;

SELECT category, count(*) FROM poi GROUP BY 1 ORDER BY 2 DESC;
