-- osm2pgsql flex style: public transport routes + stops.
--
-- Extracts three raw tables that keep what the default "pgsql" output throws away:
--   pt_stop_raw   - every node that can act as a stop (platform / stop_position)
--   pt_route_raw  - one row per route relation, WITH its merged geometry
--   pt_member_raw - ordered (relation, seq, node) membership - the exact truth,
--                   no 40 m spatial-join guessing
--
-- Run:  osm2pgsql --output=flex --style=routes.lua --slim --drop -C 1500 -d geodata <file>.osm.pbf

local MODES = { bus = true, tram = true, trolleybus = true }

local pt_stop = osm2pgsql.define_table({
    name = 'pt_stop_raw',
    ids = { type = 'node', id_column = 'osm_id' },
    columns = {
        { column = 'name', type = 'text' },
        { column = 'highway', type = 'text' },
        { column = 'railway', type = 'text' },
        { column = 'public_transport', type = 'text' },
        { column = 'route_ref', type = 'text' },
        { column = 'geom', type = 'point', projection = 4326, not_null = true },
    },
})

local pt_route = osm2pgsql.define_table({
    name = 'pt_route_raw',
    ids = { type = 'relation', id_column = 'osm_id' },
    columns = {
        { column = 'ref', type = 'text' },
        { column = 'mode', type = 'text' },
        { column = 'name', type = 'text' },
        { column = 'from_stop', type = 'text' },
        { column = 'to_stop', type = 'text' },
        { column = 'operator', type = 'text' },
        { column = 'geom', type = 'multilinestring', projection = 4326 },
    },
})

local pt_member = osm2pgsql.define_table({
    name = 'pt_member_raw',
    ids = { type = 'relation', id_column = 'relation_id' },
    columns = {
        { column = 'seq', type = 'int' },
        { column = 'node_id', type = 'int8' },
        { column = 'role', type = 'text' },
    },
})

local function is_stop_node(tags)
    return tags.highway == 'bus_stop'
        or tags.railway == 'tram_stop'
        or tags.railway == 'station'
        or tags.railway == 'halt'
        or tags.public_transport == 'platform'
        or tags.public_transport == 'stop_position'
end

function osm2pgsql.process_node(object)
    if not is_stop_node(object.tags) then
        return
    end
    pt_stop:insert({
        name = object.tags.name,
        highway = object.tags.highway,
        railway = object.tags.railway,
        public_transport = object.tags.public_transport,
        route_ref = object.tags.route_ref,
        geom = object:as_point(),
    })
end

function osm2pgsql.process_relation(object)
    local tags = object.tags
    if tags.type ~= 'route' or not MODES[tags.route] then
        return
    end
    if not tags.ref then
        return
    end

    -- Merged geometry of all member ways = the drawn line on the map.
    pt_route:insert({
        ref = tags.ref,
        mode = tags.route,
        name = tags.name,
        from_stop = tags.from,
        to_stop = tags.to,
        operator = tags.operator,
        geom = object:as_multilinestring():line_merge(),
    })

    -- Ordered stop membership. Roles in PL data: "stop", "stop_exit_only",
    -- "stop_entry_only", "platform", "platform_exit_only", "platform_entry_only".
    local seq = 0
    for _, member in ipairs(object.members) do
        if member.type == 'n'
            and (member.role:sub(1, 4) == 'stop' or member.role:sub(1, 8) == 'platform') then
            seq = seq + 1
            pt_member:insert({
                seq = seq,
                node_id = member.ref,
                role = member.role,
            })
        end
    end
end
