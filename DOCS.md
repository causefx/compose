# Docker Compose Helper Documentation

Personal bash helper for one-folder-per-service Docker Compose layouts. The short command is `dc`. It wraps `compose.sh`, which lives next to `dc.bash` and your `.env`.

Setup is in [README.md](README.md). Version history is in [CHANGELOG.md](CHANGELOG.md).

```bash
dc <action> [service] [-- extra args]
compose.sh -a <action> [-s service] [-e /path/to/.env] [-- extra args]
```

Tab completion lists actions first, then `all` and service folder names from `APPS`.

---

## Concepts

### Layout

- **APPS** — directory of service folders (set in `.env`)
- Each service is a folder under `APPS`, for example `APPS/plex/`
- **Enabled** — folder contains `COMPOSE_FILE` (default `docker-compose.yml`)
- **Disabled** — compose file renamed to `COMPOSE_FILE_DISABLED`
- **Stub** — `STUB_FILE` template used by `create` (usually the repo `docker-compose.yml`)
- **Env** — project `.env` next to `compose.sh` (never overwritten by update)

### Service name

Most commands take an optional service folder name (`plex`, `organizr`). `all` or no name (after confirm) loops every service folder. Some commands never take a service: `key`, `nextport`, `schedule`, `docs`, `bashrc`, `hosts`, `path`, `tidy`, `restore`, `df`, `prune`, `version`, `update`, `repull`, `help`.

### Marks

Status lines use the same marks across the UI:

| Mark | Meaning |
|------|---------|
| ✔ | success / ok / enabled path |
| ✘ | failure |
| ! | warning |
| · | info |
| ↓ | pull / download |
| ? | prompt |

### Non-interactive runs

When `COMPOSE_NONINTERACTIVE=1` (set by scheduled cron jobs), prompts are skipped. `pull` then pulls enabled-service images only.

---

## Run

### up

Create and start containers (`docker compose up -d`).

```bash
dc up plex
dc up all
dc up
```

With no service name, asks whether to loop all services. Batch mode prints one brief line per service when nothing changes; Compose output stays on screen when something changes or fails.

### down

Stop and remove containers and networks for the service.

```bash
dc down plex
dc down all
```

### start

Start existing containers without recreating them.

```bash
dc start plex
```

### stop

Stop running containers.

```bash
dc stop plex
```

### restart

Restart service containers.

```bash
dc restart plex
```

### build

Build service image(s) from the compose file.

```bash
dc build plex
```

### pause

Pause running containers.

```bash
dc pause plex
```

### unpause

Unpause paused containers.

```bash
dc unpause plex
```

### exec

Run a command inside a service container. Needs a service name and a command after `--`.

```bash
dc exec plex -- bash
dc exec plex -- ls /config
```

Resolves the compose service name from `config --services` (prefers a name matching the folder). Uses a real TTY when available; otherwise `exec -T`. Disabled services are refused.

### cp

Copy files to or from a service with `docker compose cp`. Needs a service folder and at least two path arguments. The name before `:` is the compose service name.

```bash
dc cp plex -- ./file plex:/tmp/file
dc cp plex -- plex:/config/file ./file
```

Prefers an enabled compose file; a disabled file is allowed with a warning.

---

## Check

### list

List service folders with their Compose project status. Enabled services first; if both groups exist, a dim `disabled` label separates the second group.

```bash
dc list
```

### ps

Show containers in a table: service, name, status, ports. Empty published ports stay aligned (unit separator parsing). Status is colorized (unhealthy/restarting yellow, up/healthy green, exited/dead red).

```bash
dc ps
dc ps plex
```

### issue

List containers that need attention: unhealthy, restarting, dead, created-never-started, or exited with a real failure. Skips healthy/running, clean exits (0), normal SIGTERM (143), and plain 137 stops that are not OOM and have zero restarts.

Each block includes a short hint, a suggested next command (`dc logs`, `dc start`, `dc up`, or docker equivalents), and a short log tail (except created). Exit code stays 0 when issues are found.

```bash
dc issue
dc issue plex
```

### logs

Show service logs. Extra args pass through to Compose (`--tail`, `-f`, and so on). Follow (`-f` / `--follow`) requires a service name so a batch loop cannot block on the first service.

```bash
dc logs plex --tail 100
dc logs plex -f
```

### top

Show processes in a container (`docker compose top`). Pass-through to Compose.

```bash
dc top plex
```

### stats

One-shot CPU, memory, and network for running containers only (`docker stats --no-stream`). Optional service filter.

```bash
dc stats
dc stats plex
```

### images

List compose images and tags for each service folder. Enabled rows first, then disabled. Tag `-` is highlighted.

```bash
dc images
dc images plex
```

### pull

Pull images that differ from the registry. Compares local digests to the registry index or platform manifest. Skips images that already match. Lists updates with ↓ marks, then pulls them.

Interactive prompts:

- Pull unique images from enabled services? `[Y/n]`
- Also pull images only used by disabled services? `[y/N]`

Scheduled / non-interactive runs pull **enabled** images only and skip questions.

```bash
dc pull
dc pull plex
```

### config

Render the compose file(s) (`docker compose config`). Useful to verify interpolation from `.env`.

```bash
dc config plex
```

### ports

Show `*_PORT_*` keys from `.env`, grouped by service prefix.

```bash
dc ports
```

### nextport

Print the next free host port. Starts at `STARTING_PORT` from `.env` (default **5000**). Skips other `*_PORT_*` values and TCP ports already listening. `STARTING_PORT` itself is not treated as in use. An explicit start must be at or above the floor.

```bash
dc nextport
dc nextport 8080
```

### df

Show Docker disk usage (`docker system df`).

```bash
dc df
```

### prune

Host-wide cleanup. Shows `docker system df`, then asks twice (Enter = no):

1. `docker system prune -a -f` and builder prune
2. `docker volume prune -f` (volumes still attached to any container, including stopped ones, stay)

Shows df again if something was removed.

```bash
dc prune
```

---

## Services

### enable

Rename the disabled compose file to the enabled name so Compose can manage it.

```bash
dc enable plex
```

### disable

Rename the enabled compose file to the disabled name.

```bash
dc disable plex
```

### create

Create a new service folder from the stub. Asks for the service name (if missing) and image. Writes a **disabled** compose file with `{{SERVICE}}` and `{{IMAGE}}` replaced. Edit it, then `dc enable` / `dc up`.

```bash
dc create
dc create myapp
```

### remove

Remove a service. Asks before deleting the folder (double confirm). Stops/removes containers if they exist.

```bash
dc remove plex
```

### edit

Open the service compose file in an editor (nano preferred, then vim). Works when stdin is not a TTY by attaching to `/dev/tty` when available. Edits the enabled file, or the disabled file if that is what exists.

```bash
dc edit plex
```

### env

Open the project `.env` in the same editor path as `edit`.

```bash
dc env
```

### tidy

Rewrite `.env` into clean sections after you confirm:

1. Script Settings (`APPS`, compose filenames, stub, `STARTING_PORT`, …)
2. Universal Settings
3. User Specific Settings (`PUID`, `PGID`, `TZ`)
4. Ports — every `*_PORT_*` key, sorted by port value ascending
5. Your category comments (for example `# Minio`) with their keys kept together
6. Other — leftover keys, A–Z

Duplicate keys keep the last value. Saves the previous file as `.env.bak`.

```bash
dc tidy
```

### restore

Restore `.env` from `.env.bak` created by `tidy`. Asks before replacing.

```bash
dc restore
```

### move

Copy a service folder to another host that also runs this script.

```bash
dc move plex root@other-host
dc move plex other-host
```

Flow:

1. Contact the host over SSH (BatchMode, public key only — no password prompt)
2. Discover remote `compose.sh` and `APPS` from that host’s `dc.bash` source line
3. Show size, destination, env keys, skipped outside mounts
4. Confirm move; optionally stop running containers first
5. Pack with a progress bar, send with a progress bar
6. Remote `receive` writes the folder **disabled** and merges missing `.env` keys
7. Disable the service on the source; ask whether to delete the local folder (default no)

`dc key root@host` can remember a short name so later moves use `dc move plex host`. Short names live in `~/.ssh/compose-hosts` and a managed block in `~/.ssh/config`.

Does not copy: bind mounts outside the service folder, named volumes, or the image (the other host pulls on start).

### receive

Internal action used by `move` on the destination. Saves the stdin stream before Docker starts so the transfer is not consumed. Not meant for daily use.

```bash
compose.sh -a receive -s plex   # fed by move over SSH
```

---

## Script

### version

Print the local version. If a newer GitHub release exists, asks whether to install it.

```bash
dc version
```

### update

Download when the published version differs. Same file set as a non-git update. `.env` is never overwritten.

```bash
dc update
```

### repull

Re-download repo files even when the version already matches, then stop (does not loop). On a git checkout of this repo, pulls the remote instead.

Files refreshed without git: `compose.sh`, `dc.bash`, `README.md`, `DOCS.md`, `docker-compose.yml`, `.env.example`, `.gitignore`, `LICENSE`.

```bash
dc repull
```

### bashrc

Check `~/.bashrc` for `source …/dc.bash`. If missing, show the line and ask before appending it.

```bash
dc bashrc
/path/to/compose.sh -a bashrc
```

### key

Create or reuse an SSH key for `move` (`~/.ssh/id_ed25519` preferred, empty passphrase when creating).

```bash
dc key
dc key root@other-host
```

With a host: ask before `ssh-copy-id`, then verify BatchMode connect. Remembers `host` → `user@host` for short-name moves. Without a host: print the install command and a sample `ssh-copy-id` line.

### hosts

List short host names saved by `key`, show `connects as`, and probe whether `move` can connect (✔ ok / ✘ fail).

```bash
dc hosts
```

### path

Print raw paths (used by move discovery):

```text
script=/path/to/compose.sh
apps=/path/to/apps
```

```bash
dc path
```

### schedule

Manage user crontab entries for this helper. Lines are tagged `# compose-schedule:ACTION`.

```bash
dc schedule
dc schedule add pull 0 4 * * *
dc schedule remove pull
```

- **list** (default) — show managed jobs and log paths
- **add ACTION m h dom mon dow** — five cron fields; asks before writing
- **remove ACTION** — asks before deleting

Allowed actions: `pull`, `update`, `tidy`, `issue`, `images`, `ports`, `df`, `hosts`, `nextport`, `version`, `list`, `ps`.

Cron runs with `COMPOSE_NONINTERACTIVE=1`. Logs go to `logs/schedule-ACTION.log` next to the script. Requires `crontab` on the host.

### docs

Show this documentation.

```bash
dc docs
dc docs pull
dc docs move
dc docs schedule
```

With no topic, opens `DOCS.md` in `less` / `more` when available, otherwise prints it. With a topic, prints that command’s section.

### help

Print grouped action list (Run, Check, Services, Script) and usage examples.

```bash
dc help
compose.sh -h
```

---

## Environment reference

From `.env.example` and script usage:

| Variable | Role |
|----------|------|
| `APPS` | Root of service folders |
| `COMPOSE_FILE` | Enabled compose filename |
| `COMPOSE_FILE_DISABLED` | Disabled compose filename |
| `STUB_FILE` | Template for `create` |
| `STARTING_PORT` | Floor for `nextport` (default 5000) |
| `COMPOSE_VERSION` | Compose file version hint in stub/env |
| `PUID` / `PGID` / `TZ` | Common container user/timezone |
| `TIME` / `DOCKER_SOCK` | Common volume snippets |
| `DOCKERLOGGING_*` | Logging defaults |
| `*_PORT_*` | Published ports tracked by `ports`, `nextport`, `tidy` |

---

## SSH and move checklist

1. `dc key root@other-host` — create/install key, remember short name  
2. `dc hosts` — confirm ✔ ok  
3. Ensure the other host has this script and `dc bashrc` sourced  
4. `dc move servicename other-host`  

Password SSH is not used (`BatchMode=yes`). Use keys only.
