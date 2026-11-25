#!/bin/bash
# Import a borders-only file into Nominatim 5.3.3 (admin style, reverse-only, frozen) and serve it
# on 127.0.0.1:<port>. The database lives in a named volume, so recreating the container does not
# re-import. No flatnode mount, PostgreSQL is not published, memory settings fit a 12 GB VM.
# usage: run_nominatim.sh <name> <port> <pbf file in /srv/osm>
set -euo pipefail
NAME=$1 PORT=$2 PBF=$3
docker rm -f "$NAME" >/dev/null 2>&1 || true
# No automatic restart during the import: a crash must not loop into a fresh multi-hour import.
docker run -d --name "$NAME" --restart no --shm-size=4g \
  -p "127.0.0.1:$PORT:8080" \
  -v /srv/osm:/data:ro \
  -v "$NAME-db:/var/lib/postgresql/16/main" \
  -e PBF_PATH="/data/$PBF" \
  -e IMPORT_STYLE=admin -e REVERSE_ONLY=true -e FREEZE=true \
  -e THREADS=8 -e GUNICORN_WORKERS=4 \
  -e POSTGRES_SHARED_BUFFERS=2GB -e POSTGRES_MAINTENANCE_WORK_MEM=768MB -e POSTGRES_AUTOVACUUM_WORK_MEM=512MB \
  -e POSTGRES_EFFECTIVE_CACHE_SIZE=6GB \
  -e NOMINATIM_PASSWORD="$(openssl rand -hex 16)" \
  mediagis/nominatim:5.3.3 >/dev/null
START=$(date +%s)
until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/status")" = "200" ]; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" != "true" ]; then
    echo "$NAME stopped"; docker logs --tail 50 "$NAME"; exit 1
  fi
  sleep 15
done
echo "$NAME ready after $(( $(date +%s) - START )) s"
# Imported (the import-finished marker is in the volume): from now on restart with the VM.
docker update --restart unless-stopped "$NAME" >/dev/null
docker exec "$NAME" sudo -u postgres psql -tAc "select 'db size: ' || pg_size_pretty(pg_database_size('nominatim'))"
