# TrueNAS Mediastack

One script that deploys a complete, self-hosted media stack on **TrueNAS SCALE** with Docker Compose. It asks a few questions and then configures every app through its API, so you don't have to click through any setup wizards.

| Service | Port | Role |
|---|---|---|
| [Jellyseerr](https://github.com/Fallenbagel/jellyseerr) | 5055 | Request movies and shows (the UI you use day to day) |
| [Jellyfin](https://jellyfin.org) | 8096 | Media server |
| [qBittorrent](https://www.qbittorrent.org) | 8080 | Download client |
| [Prowlarr](https://prowlarr.com) | 9696 | Indexer manager |
| [Radarr](https://radarr.video) | 7878 | Movies |
| [Sonarr](https://sonarr.tv) | 8989 | TV shows |
| [Lidarr](https://lidarr.audio) | 8686 | Music |
| [Bazarr](https://www.bazarr.media) | 6767 | Subtitles |
| [Byparr](https://github.com/ThePhaseless/Byparr) | 8191 | Cloudflare bypass for indexers |

## Requirements

- TrueNAS SCALE 24.10 (Electric Eel) or newer, with **Apps enabled** (Apps → Configuration → Choose Pool)
- A pool or dataset for media and app data, by default `/mnt/media`
- SSH access with an admin user that can use `sudo`

## Install

```bash
# from your computer
scp setup.sh admin@<truenas-ip>:/tmp/

# on TrueNAS
ssh admin@<truenas-ip>
sudo bash /tmp/setup.sh
```

Or straight from GitHub, run on TrueNAS:

```bash
curl -fsSLo /tmp/setup.sh https://raw.githubusercontent.com/mmartincic/truenas-mediastack/main/setup.sh
sudo bash /tmp/setup.sh
```

### What it asks

| Question | Default |
|---|---|
| Data path | `/mnt/media` |
| TrueNAS LAN IP | detected automatically |
| Timezone | `Europe/Zagreb` |
| File owner UID / GID | `568` / `568` (TrueNAS `apps` user) |
| Admin username and password | `admin` / *(you choose; used for every web UI)* |
| Jellyseerr email | `admin@mediastack.local` |
| Jellyfin metadata country | `HR` |
| Subtitle languages | `en,hr` |
| OpenSubtitles.com login | optional |
| Add public indexers? | yes |
| GPU passthrough to Jellyfin | asked only if `/dev/dri` exists |

## What gets configured

- **Folders**: `apps/<app>/config` for each app, plus `downloads`, `movies`, `tv` and `music`, all owned by the UID/GID you chose.
- **qBittorrent**: swaps the temporary password for your login and sets the save path to `/media/downloads`.
- **Radarr / Sonarr / Lidarr**: your login, a root folder, hardlinks enabled, and qBittorrent as the download client.
- **Prowlarr**: your login, Byparr as the FlareSolverr proxy, Radarr, Sonarr and Lidarr linked with full sync, plus optional public indexers (1337x, The Pirate Bay, YTS, EZTV, LimeTorrents, Nyaa). Any indexer that fails its connection test is skipped.
- **Bazarr**: connected to Sonarr and Radarr, with a default language profile and optionally OpenSubtitles.com.
- **Jellyfin**: setup wizard completed, admin user created, Movies, Shows and Music libraries added, and an API key made for Jellyseerr.
- **Jellyseerr**: signed in with your Jellyfin admin, libraries enabled, Radarr and Sonarr added as defaults.

When it finishes, the script prints a pass/fail line for each app and writes the URLs and API keys to `<data path>/apps/mediastack/ACCESS.md`.

## Re-running

You can run the script again at any time. It keeps existing data, API keys and settings, fills in anything that's missing, and remembers your answers (never passwords) in `apps/mediastack/stack.conf`. If a step failed, fix the cause and run it again.

## Folder layout

```
/mnt/media/
├── apps/
│   ├── mediastack/        docker-compose.yml, .env, stack.conf, ACCESS.md
│   ├── jellyfin/          config + cache
│   └── <app>/config       qbittorrent, prowlarr, radarr, sonarr, lidarr, bazarr, jellyseerr
├── downloads/             qBittorrent saves here
├── movies/                Radarr
├── tv/                    Sonarr
└── music/                 Lidarr
```

Every container sees the pool at `/media`. That gives all of them the same paths, so imports are instant hardlinks rather than copies. **Keep `downloads`, `movies`, `tv` and `music` in the same dataset**, because hardlinks can't cross ZFS datasets. The script warns you if they're on different ones.

## Maintenance

```bash
cd /mnt/media/apps/mediastack
sudo docker compose pull && sudo docker compose up -d   # update all images
sudo docker compose logs -f radarr                      # follow one app's logs
sudo docker compose restart sonarr                      # restart one app
```

## Notes

- Only Jellyfin (8096) and Jellyseerr (5055) need to be reachable from outside your network. Keep the rest on your LAN.
- qBittorrent connects directly, without a VPN. To add one, put a [gluetun](https://github.com/qdm12/gluetun) container in front of it.
- Public indexers come and go. Add or remove them in Prowlarr, and the changes sync to the other apps automatically.
