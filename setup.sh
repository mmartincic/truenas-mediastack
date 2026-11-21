#!/usr/bin/env bash
# =============================================================================
#  Mediastack installer for TrueNAS SCALE
#
#  Deploys Jellyfin, Jellyseerr, qBittorrent, Prowlarr, Radarr, Sonarr, Lidarr,
#  Bazarr and Byparr with Docker Compose, then wires everything together
#  through each app's API so the stack works as soon as the script finishes.
#
#  Usage (on TrueNAS, as an admin user):
#      sudo bash setup.sh
#
#  Safe to re-run: existing data, API keys and settings are kept; anything
#  missing is filled in again. Your answers (not passwords) are remembered in
#  <pool>/apps/mediastack/stack.conf.
# =============================================================================
set -Eeuo pipefail

blue=$'\033[1;34m'; green=$'\033[1;32m'; yellow=$'\033[1;33m'; red=$'\033[1;31m'; bold=$'\033[1m'; reset=$'\033[0m'
info() { printf '\n%s==>%s %s%s%s\n' "$blue" "$reset" "$bold" "$*" "$reset"; }
ok()   { printf ' %s✔%s %s\n' "$green" "$reset" "$*"; }
warn() { printf ' %s!%s %s\n' "$yellow" "$reset" "$*" >&2; }
die()  { printf '\n %s✖ %s%s\n' "$red" "$*" "$reset" >&2; exit 1; }
trap 'die "Failed at line $LINENO: $BASH_COMMAND"' ERR

# ---------------------------------------------------------------- prompts ----
ask() { # ask VAR "Prompt" "default"
  local __var=$1 __prompt=$2 __def=${3-} __ans=""
  read -rp "  $__prompt${__def:+ [$__def]}: " __ans || true
  printf -v "$__var" '%s' "${__ans:-$__def}"
}
ask_yn() { # ask_yn VAR "Prompt" y|n
  local __var=$1 __prompt=$2 __def=${3:-y} __ans="" __hint
  [[ $__def == y ]] && __hint="Y/n" || __hint="y/N"
  while :; do
    read -rp "  $__prompt [$__hint]: " __ans || true
    __ans=${__ans:-$__def}
    case ${__ans,,} in
      y|yes) printf -v "$__var" y; return ;;
      n|no)  printf -v "$__var" n; return ;;
    esac
  done
}
ask_secret() { # ask_secret VAR "Prompt" min_length   (min 0 = optional)
  local __var=$1 __prompt=$2 __min=${3:-0} __a="" __b=""
  while :; do
    read -rsp "  $__prompt: " __a || true; echo
    if [[ -z $__a && $__min -eq 0 ]]; then printf -v "$__var" ''; return; fi
    if (( ${#__a} < __min )); then warn "Must be at least $__min characters."; continue; fi
    read -rsp "  Repeat to confirm: " __b || true; echo
    if [[ $__a == "$__b" ]]; then printf -v "$__var" '%s' "$__a"; return; fi
    warn "Passwords didn't match, try again."
  done
}
detect_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

# --------------------------------------------------------- preflight ---------
[[ $EUID -eq 0 ]] || die "Run this as root:  sudo bash $0"
for c in docker python3; do command -v "$c" >/dev/null || die "'$c' was not found on this system."; done
docker info >/dev/null 2>&1 \
  || die "Docker isn't running. In the TrueNAS UI open Apps → Configuration → Choose Pool, then re-run."
docker compose version >/dev/null 2>&1 || die "The 'docker compose' plugin isn't available."

cat <<'BANNER'

  ┌──────────────────────────────────────────────────────────┐
  │  Mediastack setup                                        │
  │  Jellyfin · Jellyseerr · qBittorrent · Prowlarr · Radarr │
  │  Sonarr · Lidarr · Bazarr · Byparr                       │
  └──────────────────────────────────────────────────────────┘
  Press Enter to accept the [default] shown for each question.
BANNER

info "Storage"
ask MEDIA_ROOT "Pool / dataset path for media and app data" "/mnt/media"
MEDIA_ROOT=${MEDIA_ROOT%/}
[[ -d $MEDIA_ROOT ]] || die "$MEDIA_ROOT doesn't exist. Create the pool or dataset in TrueNAS first (Storage → Create Pool)."
STACK_DIR=$MEDIA_ROOT/apps/mediastack
CONF=$STACK_DIR/stack.conf
if [[ -f $CONF ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
  ok "Loaded your previous answers from $CONF"
fi

info "System"
ask HOST_IP "TrueNAS LAN IP address" "${HOST_IP:-$(detect_ip)}"
[[ -n $HOST_IP ]] || die "An IP address is required."
ask TZ   "Timezone" "${TZ:-Europe/Zagreb}"
ask PUID "User ID that owns the files (568 = TrueNAS 'apps' user)" "${PUID:-568}"
ask PGID "Group ID that owns the files" "${PGID:-568}"

info "Admin login (used for every web UI)"
ask ADMIN_USER "Username" "${ADMIN_USER:-admin}"
ask_secret ADMIN_PASS "Password (min 8 characters)" 8
ask ADMIN_EMAIL "Email for your Jellyseerr account (only used to log in)" "${ADMIN_EMAIL:-admin@mediastack.local}"

info "Media preferences"
ask META_COUNTRY "Metadata country code for Jellyfin" "${META_COUNTRY:-HR}"
ask SUB_LANGS "Subtitle languages (ISO 639-1, comma-separated)" "${SUB_LANGS:-en,hr}"
SUB_LANGS=${SUB_LANGS// /}
ask OS_USER "OpenSubtitles.com username (leave blank to skip)" "${OS_USER:-}"
OS_PASS=""
if [[ -n $OS_USER ]]; then ask_secret OS_PASS "OpenSubtitles.com password" 1; fi
ask_yn ADD_INDEXERS "Add public indexers (1337x, TPB, YTS, EZTV, LimeTorrents, Nyaa) to Prowlarr?" "${ADD_INDEXERS:-y}"
GPU_DEFAULT=${GPU:-y}; GPU=n
if [[ -e /dev/dri/renderD128 ]]; then
  ask_yn GPU "A GPU was found (/dev/dri). Give it to Jellyfin for hardware transcoding?" "$GPU_DEFAULT"
fi

cat <<EOF

  ${bold}Summary${reset}
    Data path ........ $MEDIA_ROOT
    Server ........... http://$HOST_IP
    Timezone ......... $TZ    (files owned by $PUID:$PGID)
    Admin user ....... $ADMIN_USER
    Subtitles ........ $SUB_LANGS  ${OS_USER:+(OpenSubtitles: $OS_USER)}
    Public indexers .. $ADD_INDEXERS     GPU for Jellyfin: $GPU
EOF
ask_yn GO "Start the installation?" y
[[ $GO == y ]] || die "Aborted, nothing was changed."

# --------------------------------------------------------- folders -----------
info "Creating folders"
APPS=(qbittorrent prowlarr radarr sonarr lidarr bazarr jellyseerr)
mkdir -p "$STACK_DIR" "$MEDIA_ROOT"/{downloads,movies,tv,music} "$MEDIA_ROOT/apps/jellyfin"/{config,cache}
for a in "${APPS[@]}"; do mkdir -p "$MEDIA_ROOT/apps/$a/config"; done
chown -R "$PUID:$PGID" "$MEDIA_ROOT/apps"
chown "$PUID:$PGID" "$MEDIA_ROOT"/{downloads,movies,tv,music}
chmod 775 "$MEDIA_ROOT"/{downloads,movies,tv,music}
ok "App configs in $MEDIA_ROOT/apps, media in $MEDIA_ROOT/{downloads,movies,tv,music}"

# Hardlinks only work inside one filesystem. Separate ZFS datasets break them.
dl_dev=$(stat -c %d "$MEDIA_ROOT/downloads")
for d in movies tv music; do
  [[ $(stat -c %d "$MEDIA_ROOT/$d") == "$dl_dev" ]] \
    || warn "$MEDIA_ROOT/$d is a separate dataset from downloads: hardlinks won't work and imports will be full copies."
done

# --------------------------------------------------------- API keys ----------
# Radarr/Sonarr/Lidarr/Prowlarr read config.xml on first start; seeding it with
# our own API key means the script can configure them without scraping files.
arr_key() { # arr_key app port
  local f="$MEDIA_ROOT/apps/$1/config/config.xml" k=""
  if [[ -f $f ]]; then
    k=$(sed -n 's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' "$f" | head -n1)
    [[ -n $k ]] || die "$f exists but has no <ApiKey>. Fix or delete it and re-run."
  else
    k=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
    cat >"$f" <<XML
<Config>
  <BindAddress>*</BindAddress>
  <Port>$2</Port>
  <ApiKey>$k</ApiKey>
  <UrlBase></UrlBase>
  <LaunchBrowser>False</LaunchBrowser>
</Config>
XML
    chown "$PUID:$PGID" "$f"
  fi
  printf '%s' "$k"
}
RADARR_KEY=$(arr_key radarr 7878)
SONARR_KEY=$(arr_key sonarr 8989)
LIDARR_KEY=$(arr_key lidarr 8686)
PROWLARR_KEY=$(arr_key prowlarr 9696)
ok "API keys ready"

# --------------------------------------------------------- compose -----------
info "Writing Docker Compose files to $STACK_DIR"
for f in docker-compose.yml docker-compose.override.yml; do
  if [[ -f $STACK_DIR/$f ]]; then cp "$STACK_DIR/$f" "$STACK_DIR/$f.bak"; fi
done

cat >"$STACK_DIR/.env" <<EOF
MEDIA_ROOT=$MEDIA_ROOT
HOST_IP=$HOST_IP
TZ=$TZ
PUID=$PUID
PGID=$PGID
EOF

cat >"$STACK_DIR/docker-compose.yml" <<'YAML'
# Generated by setup.sh. Re-run the script rather than editing by hand,
# or edit .env for paths/timezone/IDs.
name: mediastack

x-lsio-env: &lsio-env
  PUID: ${PUID}
  PGID: ${PGID}
  TZ: ${TZ}

services:

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    restart: unless-stopped
    environment:
      <<: *lsio-env
      WEBUI_PORT: 8080
    ports:
      - 8080:8080
      - 6881:6881
      - 6881:6881/udp
    volumes:
      - ${MEDIA_ROOT}/apps/qbittorrent/config:/config
      - ${MEDIA_ROOT}:/media

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    restart: unless-stopped
    environment: *lsio-env
    ports:
      - 9696:9696
    volumes:
      - ${MEDIA_ROOT}/apps/prowlarr/config:/config

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    restart: unless-stopped
    environment: *lsio-env
    ports:
      - 7878:7878
    volumes:
      - ${MEDIA_ROOT}/apps/radarr/config:/config
      - ${MEDIA_ROOT}:/media

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    restart: unless-stopped
    environment: *lsio-env
    ports:
      - 8989:8989
    volumes:
      - ${MEDIA_ROOT}/apps/sonarr/config:/config
      - ${MEDIA_ROOT}:/media

  lidarr:
    image: lscr.io/linuxserver/lidarr:latest
    container_name: lidarr
    restart: unless-stopped
    environment: *lsio-env
    ports:
      - 8686:8686
    volumes:
      - ${MEDIA_ROOT}/apps/lidarr/config:/config
      - ${MEDIA_ROOT}:/media

  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    restart: unless-stopped
    environment: *lsio-env
    ports:
      - 6767:6767
    volumes:
      - ${MEDIA_ROOT}/apps/bazarr/config:/config
      - ${MEDIA_ROOT}:/media

  byparr:
    image: ghcr.io/thephaseless/byparr:latest
    container_name: byparr
    restart: unless-stopped
    shm_size: 1gb
    environment:
      TZ: ${TZ}
    ports:
      - 8191:8191

  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    user: "${PUID}:${PGID}"
    environment:
      TZ: ${TZ}
      JELLYFIN_PublishedServerUrl: http://${HOST_IP}:8096
    ports:
      - 8096:8096
    volumes:
      - ${MEDIA_ROOT}/apps/jellyfin/config:/config
      - ${MEDIA_ROOT}/apps/jellyfin/cache:/cache
      - ${MEDIA_ROOT}:/media

  jellyseerr:
    image: fallenbagel/jellyseerr:latest
    container_name: jellyseerr
    restart: unless-stopped
    environment:
      TZ: ${TZ}
    ports:
      - 5055:5055
    volumes:
      - ${MEDIA_ROOT}/apps/jellyseerr/config:/app/config
YAML

if [[ $GPU == y ]]; then
  gids=$(stat -c %g /dev/dri/card* /dev/dri/renderD* 2>/dev/null | sort -u | sed 's/.*/      - "&"/')
  cat >"$STACK_DIR/docker-compose.override.yml" <<EOF
# GPU passthrough for Jellyfin (generated by setup.sh)
services:
  jellyfin:
    devices:
      - /dev/dri:/dev/dri
    group_add:
$gids
EOF
else
  rm -f "$STACK_DIR/docker-compose.override.yml"
fi
ok "docker-compose.yml written"

# Refuse to clobber same-named containers that belong to some other deployment.
for c in "${APPS[@]}" jellyfin byparr; do
  proj=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$c" 2>/dev/null || true)
  if docker inspect "$c" >/dev/null 2>&1 && [[ $proj != mediastack ]]; then
    die "A container named '$c' already exists and isn't part of this stack. Remove it first:  sudo docker rm -f $c"
  fi
done

info "Pulling images and starting containers (first run can take a few minutes)"
cd "$STACK_DIR"
docker compose pull
docker compose up -d --remove-orphans
ok "Containers started"

# Remember answers (never passwords) for the next run.
{
  for v in MEDIA_ROOT HOST_IP TZ PUID PGID ADMIN_USER ADMIN_EMAIL META_COUNTRY SUB_LANGS OS_USER ADD_INDEXERS GPU; do
    printf '%s=%q\n' "$v" "${!v}"
  done
} >"$CONF"
chmod 600 "$CONF"

# --------------------------------------------------------- configure ---------
info "Configuring the apps through their APIs"
export MEDIA_ROOT HOST_IP ADMIN_USER ADMIN_PASS ADMIN_EMAIL META_COUNTRY SUB_LANGS OS_USER OS_PASS \
       ADD_INDEXERS RADARR_KEY SONARR_KEY LIDARR_KEY PROWLARR_KEY

CONFIG_OK=y
if ! python3 -u - <<'PY'
import copy, json, os, re, subprocess, sys, time
import http.cookiejar, urllib.error, urllib.parse, urllib.request

E = os.environ
ROOT, IP = E["MEDIA_ROOT"], E["HOST_IP"]
USER, PW, EMAIL = E["ADMIN_USER"], E["ADMIN_PASS"], E["ADMIN_EMAIL"]
KEYS = {n: E[n.upper() + "_KEY"] for n in ("radarr", "sonarr", "lidarr", "prowlarr")}
LOCAL = "http://127.0.0.1"

G, Y, B, N = "\033[1;32m", "\033[1;33m", "\033[1;34m", "\033[0m"
def say(m):  print(f"   {m}", flush=True)
def good(m): print(f" {G}✔{N} {m}", flush=True)
def bad(m):  print(f" {Y}!{N} {m}", flush=True)


class ApiError(Exception):
    pass


class Api:
    def __init__(self, base, headers=None, cookies=False):
        self.base, self.headers = base, dict(headers or {})
        handlers = [urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())] if cookies else []
        self.opener = urllib.request.build_opener(*handlers)

    def call(self, method, path, body=None, form=None, params=None, timeout=60):
        url = self.base + path
        if params:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
        data, headers = None, dict(self.headers, Accept="application/json")
        if body is not None:
            data, headers["Content-Type"] = json.dumps(body).encode(), "application/json"
        elif form is not None:
            data = urllib.parse.urlencode(form, doseq=True).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=timeout) as r:
                status, text = r.status, r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            status, text = e.code, e.read().decode("utf-8", "replace")
        if not 200 <= status < 300:
            raise ApiError(f"{method} {path} -> HTTP {status}: {text[:300].strip()}")
        try:
            return json.loads(text) if text else None
        except ValueError:
            return text

    def get(self, p, **kw):  return self.call("GET", p, **kw)
    def post(self, p, body=None, **kw): return self.call("POST", p, body, **kw)
    def put(self, p, body=None, **kw):  return self.call("PUT", p, body, **kw)


def wait_until(what, fn, timeout=300):
    say(f"waiting for {what}…")
    end, last = time.time() + timeout, None
    while time.time() < end:
        try:
            r = fn()
            if r not in (None, False):
                return r
        except (OSError, ApiError, ValueError) as e:
            last = e
        time.sleep(3)
    raise ApiError(f"{what} wasn't ready after {timeout}s ({last})")


def probe(url):
    try:
        urllib.request.urlopen(url, timeout=5)
    except urllib.error.HTTPError:
        pass
    return True


def set_fields(obj, **values):
    for f in obj.get("fields", []):
        if f["name"] in values:
            f["value"] = values[f["name"]]
    return obj


def upsert(api, path, impl, name, fields, extra=None):
    """Create or update a Servarr 'provider' (download client, app, proxy…)."""
    existing = [x for x in api.get(path) if x.get("implementation") == impl]
    if existing:
        obj = existing[0]
    else:
        obj = next((s for s in api.get(path + "/schema") if s.get("implementation") == impl), None)
        if obj is None:
            raise ApiError(f"'{impl}' isn't offered by {path}/schema")
        obj = copy.deepcopy(obj)
    set_fields(obj, **fields)
    obj["name"] = name
    obj.update(extra or {})
    if existing:
        api.put(f"{path}/{obj['id']}", obj, params={"forceSave": "true"})
    else:
        api.post(path, obj, params={"forceSave": "true"})
    return obj


def set_arr_login(api):
    host = api.get("/config/host")
    host.update(authenticationMethod="forms", authenticationRequired="enabled",
                username=USER, password=PW, passwordConfirmation=PW)
    api.put(f"/config/host/{host['id']}", host)


RESULTS = []
def step(name, fn, *args):
    print(f"\n{B}==>{N} {name}", flush=True)
    try:
        r = fn(*args)
        RESULTS.append((name, True, ""))
        return r
    except Exception as e:  # keep going; report at the end
        bad(f"{name}: {e}")
        RESULTS.append((name, False, str(e)))
        return None


# ------------------------------------------------------------ qBittorrent --
def qb_temp_password():
    p = subprocess.run(["docker", "logs", "qbittorrent"], capture_output=True, text=True)
    m = re.findall(r"temporary password is provided for this session:\s*(\S+)", p.stdout + p.stderr)
    return m[-1] if m else None


def qbittorrent():
    qb = Api(f"{LOCAL}:8080", cookies=True)
    wait_until("qBittorrent web UI", lambda: probe(f"{LOCAL}:8080/"))

    def login(u, p):
        r = qb.post("/api/v2/auth/login", form={"username": u, "password": p})
        return isinstance(r, str) and r.strip().lower().startswith("ok")

    if login(USER, PW):
        say("already using your admin login")
    else:
        temp = wait_until("qBittorrent temporary password in logs", qb_temp_password, 120)
        if not login("admin", temp):
            raise ApiError("couldn't log in with your password or the temporary one. "
                           "Reset it in qBittorrent.conf, then re-run")
    qb.post("/api/v2/app/setPreferences", form={"json": json.dumps({
        "web_ui_username": USER,
        "web_ui_password": PW,
        "save_path": "/media/downloads/",
        "temp_path_enabled": False,
        "auto_tmm_enabled": False,
    })})
    good("login set, downloads save to /media/downloads")


# ------------------------------------------------------ Radarr/Sonarr/Lidarr --
def arr(name, port, ver, root):
    api = Api(f"{LOCAL}:{port}/api/{ver}", headers={"X-Api-Key": KEYS[name]})
    wait_until(name, lambda: api.get("/system/status"))
    set_arr_login(api)

    roots = [r["path"].rstrip("/") for r in api.get("/rootfolder")]
    if root not in roots:
        body = {"path": root}
        if name == "lidarr":
            qp = api.get("/qualityprofile")
            mps = api.get("/metadataprofile")
            mp = next((m for m in mps if m["name"] != "None"), mps[0])
            body.update(name="Music", defaultQualityProfileId=qp[0]["id"],
                        defaultMetadataProfileId=mp["id"], defaultMonitorOption="all",
                        defaultNewItemMonitorOption="all", defaultTags=[])
        api.post("/rootfolder", body)

    mm = api.get("/config/mediamanagement")
    mm["copyUsingHardlinks"] = True
    api.put(f"/config/mediamanagement/{mm['id']}", mm)

    upsert(api, "/downloadclient", "QBittorrent", "qBittorrent",
           {"host": "qbittorrent", "port": 8080, "username": USER, "password": PW},
           {"enable": True, "priority": 1})
    good(f"login set, root folder {root}, hardlinks on, qBittorrent connected")


# ---------------------------------------------------------------- Prowlarr --
PUBLIC_INDEXERS = [  # (Prowlarr definition, needs Cloudflare bypass)
    ("1337x", True), ("thepiratebay", False), ("yts", False),
    ("eztv", False), ("limetorrents", False), ("nyaasi", False),
]

def prowlarr():
    api = Api(f"{LOCAL}:9696/api/v1", headers={"X-Api-Key": KEYS["prowlarr"]})
    wait_until("prowlarr", lambda: api.get("/system/status"))
    set_arr_login(api)

    tag = next((t for t in api.get("/tag") if t["label"] == "flaresolverr"), None) \
        or api.post("/tag", {"label": "flaresolverr"})
    upsert(api, "/indexerProxy", "FlareSolverr", "Byparr",
           {"host": "http://byparr:8191/", "requestTimeout": 60}, {"tags": [tag["id"]]})
    say("Byparr added as Cloudflare bypass (applies to indexers tagged 'flaresolverr')")

    for impl, port in (("Radarr", 7878), ("Sonarr", 8989), ("Lidarr", 8686)):
        upsert(api, "/applications", impl, impl,
               {"prowlarrUrl": "http://prowlarr:9696", "baseUrl": f"http://{impl.lower()}:{port}",
                "apiKey": KEYS[impl.lower()]},
               {"syncLevel": "fullSync"})
    say("Radarr, Sonarr and Lidarr linked (full sync)")

    if E.get("ADD_INDEXERS") == "y":
        have = {i.get("definitionName") for i in api.get("/indexer")}
        todo = [(d, fs) for d, fs in PUBLIC_INDEXERS if d not in have]
        if todo:
            say("testing and adding public indexers (unreachable ones are skipped)…")
            schema = api.get("/indexer/schema", timeout=180)
            profile = api.get("/appprofile")[0]["id"]
            for d, fs in todo:
                s = next((x for x in schema if x.get("definitionName") == d), None)
                if s is None:
                    bad(f"indexer '{d}' not available in this Prowlarr version")
                    continue
                s = copy.deepcopy(s)
                s.update(enable=True, appProfileId=profile, priority=25,
                         tags=[tag["id"]] if fs else [])
                try:
                    api.post("/indexer", s, timeout=180)
                    good(f"indexer {s.get('name', d)} added")
                except Exception as e:
                    bad(f"indexer {s.get('name', d)} skipped: {str(e)[:150]}")
        api.post("/command", {"name": "ApplicationIndexerSync"})
    good("Prowlarr ready")


# ----------------------------------------------------------------- Bazarr --
def bazarr_key():
    base = f"{ROOT}/apps/bazarr/config/config"
    y = f"{base}/config.yaml"
    if os.path.exists(y):
        m = re.search(r"^auth:[ \t]*\n(?:[ \t]+.*\n)*?[ \t]+apikey:[ \t]*['\"]?([0-9A-Za-z]{16,})", open(y).read(), re.M)
        if m:
            return m.group(1)
    i = f"{base}/config.ini"
    if os.path.exists(i):
        m = re.search(r"^\[auth\][^\[]*?^apikey\s*=\s*(\w+)", open(i).read(), re.M | re.S)
        if m:
            return m.group(1)
    return None


def bazarr():
    key = wait_until("bazarr API key", bazarr_key, 180)
    api = Api(f"{LOCAL}:6767/api", headers={"X-API-KEY": key})
    wait_until("bazarr", lambda: api.get("/system/status"))
    langs = [l for l in E["SUB_LANGS"].lower().split(",") if l]
    profile = [{
        "profileId": 1, "name": "Default", "cutoff": None, "originalFormat": False, "tag": None,
        "mustContain": [], "mustNotContain": [],
        "items": [{"id": n + 1, "language": l, "audio_exclude": "False",
                   "audio_only_include": "False", "hi": "False", "forced": "False"}
                  for n, l in enumerate(langs)],
    }]
    form = {
        "settings-general-use_sonarr": "true",
        "settings-general-use_radarr": "true",
        "settings-sonarr-ip": "sonarr", "settings-sonarr-port": "8989",
        "settings-sonarr-apikey": KEYS["sonarr"], "settings-sonarr-base_url": "/",
        "settings-sonarr-ssl": "false",
        "settings-radarr-ip": "radarr", "settings-radarr-port": "7878",
        "settings-radarr-apikey": KEYS["radarr"], "settings-radarr-base_url": "/",
        "settings-radarr-ssl": "false",
        "settings-general-serie_default_enabled": "true",
        "settings-general-serie_default_profile": "1",
        "settings-general-movie_default_enabled": "true",
        "settings-general-movie_default_profile": "1",
        "languages-enabled": langs,
        "languages-profiles": json.dumps(profile),
        "settings-auth-type": "form",
        "settings-auth-username": USER,
        "settings-auth-password": PW,
    }
    if E.get("OS_USER"):
        form.update({
            "settings-general-enabled_providers": ["opensubtitlescom"],
            "settings-opensubtitlescom-username": E["OS_USER"],
            "settings-opensubtitlescom-password": E["OS_PASS"],
        })
    api.post("/system/settings", form=form)
    good(f"linked to Sonarr/Radarr, languages {', '.join(langs)}"
         + (", OpenSubtitles.com enabled" if E.get("OS_USER") else ""))


# --------------------------------------------------------------- Jellyfin --
JF_CLIENT = 'MediaBrowser Client="mediastack-setup", Device="setup.sh", DeviceId="mediastack-setup", Version="1.0.0"'

def jellyfin():
    jf = Api(f"{LOCAL}:8096", headers={"Authorization": JF_CLIENT})
    info = wait_until("jellyfin", lambda: jf.get("/System/Info/Public"))
    if not info.get("StartupWizardCompleted"):
        wait_until("jellyfin setup wizard", lambda: jf.get("/Startup/Configuration"))
        jf.post("/Startup/Configuration", {"UICulture": "en-US",
                                           "MetadataCountryCode": E["META_COUNTRY"].upper(),
                                           "PreferredMetadataLanguage": "en"})
        jf.get("/Startup/User")
        jf.post("/Startup/User", {"Name": USER, "Password": PW})
        jf.post("/Startup/RemoteAccess", {"EnableRemoteAccess": True, "EnableAutomaticPortMapping": False})
        jf.post("/Startup/Complete")
        say("setup wizard completed")
        time.sleep(3)

    auth = wait_until("jellyfin login", lambda: jf.post("/Users/AuthenticateByName",
                                                       {"Username": USER, "Pw": PW}), 60)
    ja = Api(f"{LOCAL}:8096", headers={"Authorization": f'{JF_CLIENT}, Token="{auth["AccessToken"]}"'})

    have = {f["Name"] for f in ja.get("/Library/VirtualFolders")}
    for name, ctype, path in (("Movies", "movies", "/media/movies"),
                              ("Shows", "tvshows", "/media/tv"),
                              ("Music", "music", "/media/music")):
        if name not in have:
            ja.post("/Library/VirtualFolders", {"LibraryOptions": {"PathInfos": [{"Path": path}]}},
                    params={"name": name, "collectionType": ctype, "refreshLibrary": "true"})
    say("libraries: Movies, Shows, Music")

    def jellyseerr_key():
        return next((k["AccessToken"] for k in ja.get("/Auth/Keys")["Items"]
                     if k.get("AppName") == "Jellyseerr"), None)
    key = jellyseerr_key()
    if not key:
        ja.post("/Auth/Keys", params={"app": "Jellyseerr"})
        key = jellyseerr_key()
    good(f"admin '{USER}' and libraries ready")
    return key


# ------------------------------------------------------------- Jellyseerr --
def pick_profile(api):
    profiles = api.get("/qualityprofile")
    for want in ("HD-1080p", "HD - 720p/1080p", "Any"):
        for p in profiles:
            if p["name"] == want:
                return p
    return profiles[0]


def jellyseerr(jf_key):
    if not jf_key:
        raise ApiError("skipped because the Jellyfin step failed")
    s = Api(f"{LOCAL}:5055/api/v1", cookies=True)
    pub = wait_until("jellyseerr", lambda: s.get("/settings/public"))
    if pub.get("initialized"):
        good("already set up, leaving it alone")
        return

    try:  # current API
        s.post("/auth/jellyfin", {"username": USER, "password": PW, "email": EMAIL,
                                  "hostname": "jellyfin", "port": 8096, "useSsl": False,
                                  "urlBase": "", "serverType": 2})
    except ApiError as first:
        try:  # older releases took a full URL
            s.post("/auth/jellyfin", {"username": USER, "password": PW, "email": EMAIL,
                                      "hostname": "http://jellyfin:8096"})
        except ApiError:
            raise first
    say("signed in with your Jellyfin admin")

    try:
        cur = s.get("/settings/jellyfin")
        cur.update(ip="jellyfin", port=8096, useSsl=False, urlBase="",
                   externalHostname=f"http://{IP}:8096", apiKey=jf_key)
        s.post("/settings/jellyfin", cur)
    except ApiError as e:
        bad(f"couldn't store Jellyfin API key / external URL ({e}). Not critical")

    libs = s.get("/settings/jellyfin/library", params={"sync": "true"})
    ids = [l["id"] for l in libs if l.get("type") in ("movie", "show")]
    if ids:
        s.get("/settings/jellyfin/library", params={"enable": ",".join(ids)})
    say(f"{len(ids)} Jellyfin libraries enabled")

    radarr_api = Api(f"{LOCAL}:7878/api/v3", headers={"X-Api-Key": KEYS["radarr"]})
    sonarr_api = Api(f"{LOCAL}:8989/api/v3", headers={"X-Api-Key": KEYS["sonarr"]})
    if not s.get("/settings/radarr"):
        p = pick_profile(radarr_api)
        s.post("/settings/radarr", {
            "name": "Radarr", "hostname": "radarr", "port": 7878, "apiKey": KEYS["radarr"],
            "useSsl": False, "baseUrl": "", "activeProfileId": p["id"], "activeProfileName": p["name"],
            "activeDirectory": "/media/movies", "is4k": False, "minimumAvailability": "released",
            "isDefault": True, "externalUrl": f"http://{IP}:7878", "syncEnabled": False,
            "preventSearch": False, "tags": []})
    if not s.get("/settings/sonarr"):
        p = pick_profile(sonarr_api)
        s.post("/settings/sonarr", {
            "name": "Sonarr", "hostname": "sonarr", "port": 8989, "apiKey": KEYS["sonarr"],
            "useSsl": False, "baseUrl": "", "activeProfileId": p["id"], "activeProfileName": p["name"],
            "activeDirectory": "/media/tv", "activeAnimeProfileId": p["id"],
            "activeAnimeProfileName": p["name"], "activeAnimeDirectory": "/media/tv",
            "is4k": False, "isDefault": True, "enableSeasonFolders": True,
            "externalUrl": f"http://{IP}:8989", "syncEnabled": False, "preventSearch": False,
            "tags": [], "animeTags": []})
    say("Radarr and Sonarr connected")
    s.post("/settings/initialize")
    good("setup finished")


# ------------------------------------------------------------------- main --
step("qBittorrent", qbittorrent)
step("Radarr", arr, "radarr", 7878, "v3", "/media/movies")
step("Sonarr", arr, "sonarr", 8989, "v3", "/media/tv")
step("Lidarr", arr, "lidarr", 8686, "v1", "/media/music")
step("Prowlarr", prowlarr)
step("Bazarr", bazarr)
jf_key = step("Jellyfin", jellyfin)
step("Jellyseerr", jellyseerr, jf_key)

print(f"\n{B}==>{N} Configuration results", flush=True)
for name, ok, err in RESULTS:
    print(f"   {G + '✔' if ok else Y + '✖'}{N} {name}" + ("" if ok else f"  ({err[:120]})"))
sys.exit(0 if all(ok for _, ok, _ in RESULTS) else 1)
PY
then
  CONFIG_OK=n
fi

# --------------------------------------------------------- summary -----------
ACCESS=$STACK_DIR/ACCESS.md
cat >"$ACCESS" <<EOF
# Mediastack access (generated $(date '+%Y-%m-%d %H:%M'))

Login for every UI: **$ADMIN_USER** / the password you entered during setup.
Jellyseerr signs in with your Jellyfin account.

| Service     | URL                          | Notes |
|-------------|------------------------------|-------|
| Jellyseerr  | http://$HOST_IP:5055         | Request movies & shows (daily use) |
| Jellyfin    | http://$HOST_IP:8096         | Watch |
| qBittorrent | http://$HOST_IP:8080         | Downloads in $MEDIA_ROOT/downloads |
| Prowlarr    | http://$HOST_IP:9696         | Indexers, syncs to Radarr/Sonarr/Lidarr |
| Radarr      | http://$HOST_IP:7878         | Movies → $MEDIA_ROOT/movies |
| Sonarr      | http://$HOST_IP:8989         | Shows → $MEDIA_ROOT/tv |
| Lidarr      | http://$HOST_IP:8686         | Music → $MEDIA_ROOT/music |
| Bazarr      | http://$HOST_IP:6767         | Subtitles: $SUB_LANGS |
| Byparr      | http://$HOST_IP:8191         | Cloudflare bypass used by Prowlarr |

## API keys
- Radarr:   $RADARR_KEY
- Sonarr:   $SONARR_KEY
- Lidarr:   $LIDARR_KEY
- Prowlarr: $PROWLARR_KEY

## Maintenance
    cd $STACK_DIR
    sudo docker compose pull && sudo docker compose up -d   # update everything
    sudo docker compose logs -f radarr                      # logs for one app
    sudo bash setup.sh                                      # re-apply configuration
EOF
chmod 600 "$ACCESS"

info "Done"
cat <<EOF

  ${bold}Open Jellyseerr to request things:${reset}   http://$HOST_IP:5055
  ${bold}Open Jellyfin to watch:${reset}             http://$HOST_IP:8096

  Every UI uses the login '${ADMIN_USER}' and the password you just set.
  URLs and API keys are saved in $ACCESS
EOF
if [[ $CONFIG_OK == n ]]; then
  warn "Some configuration steps failed (listed above). Fix the cause and run the script again."
  warn "Re-running is safe: finished steps are kept as they are."
  exit 1
fi
