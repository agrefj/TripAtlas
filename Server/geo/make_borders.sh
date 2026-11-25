#!/bin/bash
# Cut an OSM file down to what a zoom-10 reverse lookup needs (validated against the public
# server on Luxembourg and Belgium):
#  - boundary=administrative and every place=*, with all referenced ways and nodes;
#  - plus named-landuse areas of the 7 kinds Nominatim's admin style imports, but only those
#    with a wikidata tag: Nominatim uses them to link (hide) duplicate place nodes.
# usage: make_borders.sh <input.osm.pbf> <output.osm.pbf>
set -euo pipefail
IN=$1 OUT=$2
TMP=$(mktemp -d "$(dirname "$OUT")/borders-tmp.XXXX")
trap 'rm -rf "$TMP"' EXIT
osmium tags-filter --progress -O -o "$TMP/admin.osm.pbf" "$IN" nwr/boundary=administrative nwr/place
osmium tags-filter --progress -O -o "$TMP/landuse.osm.pbf" "$IN" \
  nwr/landuse=residential,farm,farmyard,industrial,commercial,allotments,retail
osmium tags-filter -O -o "$TMP/landuse-wd.osm.pbf" "$TMP/landuse.osm.pbf" nwr/wikidata
osmium merge -O -o "$OUT" "$TMP/admin.osm.pbf" "$TMP/landuse-wd.osm.pbf"
osmium fileinfo -e "$OUT" | grep -E 'Number of (nodes|ways|relations)|File size' || true
ls -l "$OUT"
