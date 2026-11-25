#!/bin/bash
# World build for the TripAtlas borders server: wait for the planet download, cut it down to
# borders and places, import into a NEW Nominatim container, then check parity on LU and BE.
# usage: build_world.sh <container-name> <port>
#   first install: build_world.sh nominatim 8080
#   refresh:       build_world.sh nominatim-2027-05 8081   (then switch proxy_pass, see README)
set -euo pipefail
NAME=${1:?container name, e.g. nominatim-2027-05}
PORT=${2:?port, e.g. 8081}
cd /srv/osm
step() { echo "[$(date -u +%FT%TZ)] $*"; }

# A reused volume already holds the import-finished marker: the image would skip the import and
# serve the old database. Every build therefore gets a fresh container and volume.
if docker volume inspect "$NAME-db" >/dev/null 2>&1; then
  step "volume $NAME-db already exists; pick a new name (see README: refresh)"; exit 1
fi

step "waiting for planet download"
while systemctl is-active --quiet planet-download.service 2>/dev/null; do sleep 60; done
grep -q ': OK' planet-md5.txt || { step "PLANET CHECKSUM MISSING OR FAILED"; cat planet-md5.txt 2>/dev/null; exit 1; }
step "planet ok: $(ls -l planet-latest.osm.pbf | awk '{print $5}') bytes, data as of $(osmium fileinfo -g header.option.osmosis_replication_timestamp planet-latest.osm.pbf)"

step "cutting to borders and places"
/usr/bin/time -v /opt/tripatlas-geo/make_borders.sh planet-latest.osm.pbf "/srv/osm/borders-$NAME.osm.pbf" 2> "borders-$NAME-time.txt"
grep -E 'Elapsed|Maximum resident' "borders-$NAME-time.txt" || true
osmium fileinfo -e "borders-$NAME.osm.pbf" > "borders-$NAME.fileinfo.txt"
md5sum "borders-$NAME.osm.pbf" > "borders-$NAME.osm.pbf.md5"

step "importing into Nominatim ($NAME on 127.0.0.1:$PORT)"
/opt/tripatlas-geo/run_nominatim.sh "$NAME" "$PORT" "borders-$NAME.osm.pbf"
df -h / | tail -1
docker exec "$NAME" du -sh /var/lib/postgresql/16/main

step "parity with saved public answers"
cd /opt/tripatlas-geo/validate
python3 /opt/tripatlas-geo/strict_compare.py points-lu.json results-lu/public lu "http://127.0.0.1:$PORT" || true
python3 /opt/tripatlas-geo/strict_compare.py points-be.json results-be/public be "http://127.0.0.1:$PORT" || true
step "PIPELINE-DONE"
