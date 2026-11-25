"""Strict parity check: saved public-server answers vs our server, for the app's exact query.
Compares the OSM object and the exact GeoJSON (place_id and importance differ between installs
and are not read by the app).

usage: python3 strict_compare.py <points.json> <public-answers-dir> <country-code|*> <base-url> [delay-s]
  country-code: only points the public server places in that country; '*' compares every point.
  delay-s: pause between requests (0 is fine through the public URL: nginx allows 30/s per address, burst 30).
"""
import json
import sys
import time
import urllib.request

PARAMS = "format=jsonv2&zoom=10&polygon_geojson=1&polygon_threshold=0.0005"


def fetch(base, p):
    # Same parameter order as CityBoundaryService.requestURL: nginx accepts only that exact string.
    url = (f"{base}/reverse?format=jsonv2&lat={p['lat']:.5f}&lon={p['lon']:.5f}"
           f"&zoom=10&polygon_geojson=1&polygon_threshold=0.0005")
    req = urllib.request.Request(url, headers={"User-Agent": "TripAtlas-parity-check/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def main():
    points = json.load(open(sys.argv[1]))
    folder, country, base = sys.argv[2], sys.argv[3], sys.argv[4]
    delay = float(sys.argv[5]) if len(sys.argv) > 5 else 0.0
    compared = same = 0
    diffs = []
    for p in points:
        pub = json.load(open(f"{folder}/{p['id']}.json"))
        if country != "*" and (pub.get("address") or {}).get("country_code") != country:
            continue
        compared += 1
        ours = fetch(base, p)
        if delay:
            time.sleep(delay)
        a = (pub.get("osm_type"), pub.get("osm_id"), json.dumps(pub.get("geojson"), sort_keys=True))
        b = (ours.get("osm_type"), ours.get("osm_id"), json.dumps(ours.get("geojson"), sort_keys=True))
        if a == b:
            same += 1
        else:
            diffs.append((p["id"], p.get("label"), a[:2], b[:2], "same geometry" if a[2] == b[2] else "geometry differs"))
    print(f"{country}: {same}/{compared} points with the same object and identical GeoJSON")
    for d in diffs[:30]:
        print("  DIFF", d)
    return 0 if same == compared and compared > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
