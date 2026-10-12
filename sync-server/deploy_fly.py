#!/usr/bin/env python3
"""Deploy webby-sync to Fly without flyctl or a registry: a dart:3.9 machine gets the server sources as machine
files (fetched from GitHub at SHA) and compiles them at boot. Data lives on the webby_sync_data volume at /data.

    FLY_API_KEY=... python3 deploy_fly.py app       # once: create app, IPs, volume
    FLY_API_KEY=... python3 deploy_fly.py machine [SHA]   # create or update the machine (default: main)
    FLY_API_KEY=... python3 deploy_fly.py status
"""
import base64, json, os, sys, urllib.error, urllib.request

APP, ORG, REGION = "webby-sync", "personal", "iad"
TOKEN = os.environ["FLY_API_KEY"]


def call(method, path, body=None, base="https://api.machines.dev"):
    req = urllib.request.Request(base + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
    try:
        data = urllib.request.urlopen(req, timeout=60).read()
        return json.loads(data) if data else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path}: {e.code} {e.read()[:500]!r}")


def gql(query, variables):
    return call("POST", "/graphql", {"query": query, "variables": variables}, base="https://api.fly.io")


def sources(sha):
    raw = f"https://raw.githubusercontent.com/nandi-conda/webby/{sha}/sync-server/"
    return {p: base64.b64encode(urllib.request.urlopen(raw + p).read()).decode()
            for p in ["pubspec.yaml", "bin/server.dart", "lib/webby_sync_server.dart"]}


step = sys.argv[1]
if step == "app":
    print(call("POST", "/v1/apps", {"app_name": APP, "org_slug": ORG}))
    for kind in ["shared_v4", "v6"]:
        print(gql("mutation($i:AllocateIPAddressInput!){allocateIpAddress(input:$i){ipAddress{address type}}}",
                  {"i": {"appId": APP, "type": kind}}))
    print(call("POST", f"/v1/apps/{APP}/volumes", {"name": "webby_sync_data", "region": REGION, "size_gb": 1})["id"])
elif step == "machine":
    sha = sys.argv[2] if len(sys.argv) > 2 else "main"
    volume = call("GET", f"/v1/apps/{APP}/volumes")[0]["id"]
    config = {
        "image": "dart:3.9",
        "env": {"DATA_DIR": "/data", "PORT": "8080", "PUB_CACHE": "/tmp/pub"},
        "files": [{"guest_path": "/src/" + p, "raw_value": v} for p, v in sources(sha).items()],
        "init": {"entrypoint": ["/bin/sh", "-c"],
                 "cmd": ["cd /src && dart pub get && dart compile exe bin/server.dart -o /tmp/server && exec /tmp/server"]},
        "mounts": [{"volume": volume, "path": "/data"}],
        "services": [{"protocol": "tcp", "internal_port": 8080, "autostop": "off", "autostart": True,
                      "min_machines_running": 1,
                      "ports": [{"port": 80, "handlers": ["http"], "force_https": True},
                                {"port": 443, "handlers": ["tls", "http"]}]}],
        "checks": {"health": {"type": "http", "port": 8080, "path": "/healthz", "interval": "30s", "timeout": "5s",
                              "grace_period": "180s"}},
        "restart": {"policy": "always"},
        "guest": {"cpu_kind": "shared", "cpus": 1, "memory_mb": 512},
        "metadata": {"source_sha": sha},
    }
    machines = call("GET", f"/v1/apps/{APP}/machines")
    if machines:
        m = call("POST", f"/v1/apps/{APP}/machines/{machines[0]['id']}", {"config": config, "region": REGION})
    else:
        m = call("POST", f"/v1/apps/{APP}/machines", {"config": config, "region": REGION, "name": APP})
    print(m["id"], m["state"])
elif step == "status":
    for m in call("GET", f"/v1/apps/{APP}/machines"):
        print(m["id"], m["state"], m["config"].get("metadata", {}).get("source_sha"), m.get("checks"))
