-- How often does a border with a place=* tag lack its linked place node, while a place node of
-- the same name and type lies inside it? For such places the server answers with the node, and
-- the app draws a dashed circle instead of the border (Havana's Diez de Octubre is one).
-- Read-only; takes a few minutes on the world database:
--   docker exec -i nominatim sudo -u postgres psql -d nominatim -tA -F" | " < linkcheck.sql
-- November 2026 world build: 48469 | 32837 | 124
SET statement_timeout = 900000;
WITH b AS (
  SELECT place_id, osm_id, name->'name' AS nm, extratags->'place' AS ptype, geometry, rank_search
  FROM placex
  WHERE class = 'boundary' AND type = 'administrative' AND osm_type = 'R'
    AND extratags ? 'place' AND rank_search BETWEEN 5 AND 16 AND name ? 'name'
)
SELECT count(*) AS boundaries_with_place_tag,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM placex l WHERE l.linked_place_id = b.place_id)) AS with_linked_node,
       count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM placex l WHERE l.linked_place_id = b.place_id)
                          AND EXISTS (
          SELECT 1 FROM placex n WHERE n.class = 'place' AND n.osm_type = 'N' AND n.type = b.ptype
            AND n.rank_search < 26
            AND lower(n.name->'name') = lower(b.nm) AND n.linked_place_id IS NULL
            AND ST_Covers(b.geometry, n.geometry))) AS unlinked_but_matching_node
FROM b;
