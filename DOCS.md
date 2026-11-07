# Docker Compose Helper Documentation

Personal bash helper for one-folder-per-service Docker Compose layouts. The short command is `dc`. It wraps `compose.sh`, which lives next to `dc.bash` and your `.env`.

Setup is in [README.md](README.md). Version history is in [CHANGELOG.md](CHANGELOG.md).

```bash
dc <action> [service] [-- extra args]
compose.sh -a <action> [-s service] [-e /path/to/.env] [-- extra args]
```

Tab completion lists actions first, then `all` and service folder names from `APPS`. For `dc move SERVICE`, the next word completes short host names from `~/.ssh/compose-hosts`.

---

## Concepts

### Layout

- **APPS** — directory of service folders (set in `.env`)
- Each service is a folder under `APPS`, for example `APPS/plex/`
- **Enabled** — folder contains `COMPOSE_FILE` (default `docker-compose.yml`)
- **Disabled** — compose file renamed to `COMPOSE_FILE_DISABLED`
- **Archived** — disabled service folder moved under `ARCHIVE` (default `APPS/.archive/`); hidden from normal run/list loops until unarchived
- **Stub** — `STUB_FILE` template used by `create` (usually the repo `docker-compose.yml`)
- **Env** — project `.env` next to `compose.sh` (never overwritten by update). Read with a parser, not `source`, so values are never run as shell code. Unquoted and double-quoted values expand `$VAR` / `${VAR}` like Compose; single-quoted values stay literal.
- **Backups** — tidy and non-git update copies go under `.backup/` next to the file (for example `.backup/.env.bak`, `.backup/compose.sh.bak`). Legacy `*.bak` beside the file still works for `tidy --undo`.
- **Service env files** — any `.env`, `.env.*`, or `*.env` in a service folder is also passed to Compose (after the project `.env`). Later files can override earlier keys. Skips `*.bak`, `*.example`, and `*.sample`.

### Service name

Most commands take an optional service folder name (`plex`, `organizr`). `all` or no name (after confirm) loops every service folder. With no name, `down`, `stop`, and `restart` default to **no** (`[y/N]`); other loops default to yes. Some commands never take a service: `nextport`, `df`, `clean`, `where`, `unused`, `tidy`, `update`, `host`, `setup`, `schedule`, `docs`, `help`. For those, the next word is an option or subcommand (`dc update --check`, `dc host add root@other-host`).

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

When `COMPOSE_NONINTERACTIVE=1` (set by scheduled cron jobs), prompts are skipped. `images --pull` then pulls enabled-service images only, and `update` installs a newer version without asking.

---

## Run

### up

Create and start containers (`docker compose up -d`).

```bash
dc up plex
dc up all
dc up
```

`up` can be scheduled. The job runs every enabled service; services already running stay unchanged.

With no service name, asks whether to loop all services. Batch mode prints one brief line per service when nothing changes; Compose output stays on screen when something changes or fails. Loads the project `.env` plus any env files in that service’s folder. If the named service is **disabled**, asks to enable it and continue (`start`, `restart`, and `build` do the same).

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

List service folders with Compose project status and an **env** column (`yes` when the folder has a service env file, `-` otherwise). Enabled first, then dim `disabled`, then dim `archived`. Footer counts all three.

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
dc images --pull
dc images plex --pull
```

With `--pull`, pull images that differ from the registry. Compares local digests to the registry index or platform manifest. Skips images that already match. Lists updates with ↓ marks, then pulls them.

Interactive prompts with `--pull`:

- Pull unique images from enabled services? `[Y/n]`
- Also pull images only used by disabled services? `[y/N]`

Scheduled / non-interactive runs pull **enabled** images only and skip questions.

### config

Render the compose file(s) (`docker compose config`). Useful to verify interpolation from `.env`.

```bash
dc config plex
```

### cmd

Print a shell-quoted `docker compose` (or `docker-compose`) line for a service: `--file`, every `--env-file` (project then service folder, same chain as a real run), then `up -d`. Works for enabled or disabled (and archived) compose files. stdout is only that line so you can copy or pipe it. Pass extra args after `--` to replace `up -d`.

```bash
dc cmd plex
dc cmd plex -- down
dc cmd plex -- config
```

### ports

Show `*_PORT_*` keys from the project `.env` and every service-folder env file, grouped by service prefix.

```bash
dc ports
```

### nextport

Print the next free host port. Starts at `STARTING_PORT` from `.env` (default **5000**). Skips other `*_PORT_*` values from the project and service env files, plus TCP ports already listening. `STARTING_PORT` itself is not treated as in use. An explicit start must be at or above the floor.

```bash
dc nextport
dc nextport 8080
```

### df

Show Docker disk usage (`docker system df`).

```bash
dc df
```

### clean

Host-wide cleanup. Shows `docker system df`, then asks twice (Enter = no):

1. Unused images, build cache, stopped containers, and networks (`docker system prune -a -f`)
2. Every volume not attached to a container, **named ones too** (`docker volume prune --all -f` on Docker 23+, `docker volume prune -f` on older Docker). Data in those volumes is deleted. Volumes attached to any container, including stopped ones, always stay.

Shows df again if something was removed.

```bash
dc clean
dc clean --yes
dc schedule add clean --yes 0 3 '*' '*' 0
```

`--yes` answers yes to both questions, so it runs from a schedule. Without `--yes`, a scheduled or non-interactive run removes nothing.

---

## Services

### enable

Rename the disabled compose file to the enabled name so Compose can manage it.

```bash
dc enable plex
```

### disable

Rename the enabled compose file to the disabled name. If the service is running, asks to stop and remove it first; answering no leaves it enabled so `dc` can still manage those containers.

```bash
dc disable plex
```

### archive

Move a service folder into `ARCHIVE` (default `APPS/.archive/`). Stays out of normal `list`/run loops until unarchived. With no service name, lists archived services. `all` archives every currently disabled service after confirm.

- **Up** (containers still present) — refused; stop first (`dc down`, then `dc disable`)
- **Enabled but down** — asks to disable, then archives
- **Already disabled** — asks to archive as before

```bash
dc archive
dc archive plex
dc archive all
```

### unarchive

Move an archived service folder back under `APPS`. It remains **disabled** until you `dc enable`. With no service name, lists archived services. `all` restores every archived service after confirm.

```bash
dc unarchive
dc unarchive plex
dc unarchive all
```

### create

Create a new service folder from the stub. Asks for the service name (if missing) and image. Writes a **disabled** compose file with `{{SERVICE}}` and `{{IMAGE}}` replaced. Service names use letters, numbers, dot, dash, or underscore; image refs use letters, numbers, and `. _ / : @ -`. Edit it, then `dc enable` / `dc up`.

```bash
dc create
dc create myapp
```

### add

Append another app (Compose service) to an existing service folder’s compose file. Does not create a new `APPS/` folder.

```bash
dc add plex
```

Asks for a compose service key (e.g. `tautulli`) and image. Appends a stub-like block with `container_name` `{folder}-{key}`, volume `${APPS}/{folder}/{key}`, shared `PUID`/`PGID`/`TZ`/logging, and a `${KEY_PORT_80}` placeholder. Then suggests `envs fill` / `edit`, and offers `up` when the stack is enabled. Archived services must be unarchived first.

### remove

Remove a service. Asks before deleting the folder (double confirm). Stops/removes containers if they exist.

```bash
dc remove plex
```

### rename

Rename a service folder (under `APPS` or `ARCHIVE`) and safely rewrite related names.

```bash
dc rename pihole dns
```

Flow:

1. Resolve the current folder (apps or archived); refuse if the new name already exists  
2. Plan compose rewrites (`name` / `container_name` / `hostname`, `${APPS}/old` paths)  
3. Plan optional env key renames for the `OLDNAME_` → `NEWNAME_` prefix (hyphens become underscores, e.g. `paperless-ngx` → `PAPERLESS_NGX_`)  
4. For each candidate env key, skip rename if another service references or defines it (same scan idea as `where`); list those keys  
5. Warn about outside bind mounts that still point at absolute paths  
6. Ask whether to rename safe env keys (`[y/N]`); then confirm the folder rename  
7. If enabled and running, `down` and leave the compose file **disabled**  
8. `mv` the folder; apply compose rewrites; apply env key rewrites only when you said yes

Ends disabled (or still archived). Then `dc enable` / `dc up`, or `dc unarchive` when archived.

### edit

Open the service compose file in an editor (nano preferred, then vim). Works when stdin is not a TTY by attaching to `/dev/tty` when available. Edits the enabled file, or the disabled file if that is what exists.

```bash
dc edit plex
```

### env

Open an env file in the same editor path as `edit`.

```bash
dc env
dc env plex
```

With no service name, opens the project `.env`. With a service name, opens that folder’s `.env`, or asks before creating it.

### envs

List `${VAR}` / `$VAR` names referenced in a service’s compose file as a table with a **from** column: `shared` (project `.env`) or `service` (that folder’s env file). Rows sort by source (`shared`, then `service`, then unset), then name A–Z. Last file wins when both define the key. Add `values` for an expanded value column (nested refs like `${MEDIA}/photos` resolve the same way Compose does). Unset keys show `-`.

`fill` creates `$APPS/<service>/.env` if needed and appends every unset compose var as `KEY=` (empty value), then offers to open the editor.

```bash
dc envs plex
dc envs plex values
dc envs plex fill
```

### where

Show which services reference an env var. Scans every service’s compose file and service env files for `${VAR}` / `$VAR`. Notes when the project `.env` defines it. Table columns: service, enabled/disabled state, and **in** (`compose`, `env`, or both). Sorted by service name A–Z.

```bash
dc where MEDIA
dc where PUID
```

### unused

List env keys that are assigned but not referenced by any service: compose `${VAR}` / `$VAR`, plus nested refs inside env values (project `.env` and service env files). Scans enabled, disabled, **and archived** services. Loads defined keys first, then walks each compose once to build the referenced set; unused is defined minus referenced.

Never flagged:

- Script settings: `APPS`, `ARCHIVE`, `COMPOSE_FILE`, `COMPOSE_FILE_DISABLED`, `STUB_FILE`, `STARTING_PORT`
- Keys Compose or the Docker CLI read from the environment: any `COMPOSE_*` (for example `COMPOSE_HTTP_TIMEOUT`, `COMPOSE_VERSION`), `DOCKER_CLIENT_TIMEOUT`, `DOCKER_HOST`, `DOCKER_CONTEXT`, `DOCKER_CONFIG`, `DOCKER_BUILDKIT`, `DOCKER_DEFAULT_PLATFORM`, `DOCKER_TLS_VERIFY`, `DOCKER_CERT_PATH`

Table columns: **key** and **from** (`shared`, a service name, or both). Sorted by key A–Z. Shows a spinner on the terminal while scanning.

After the table, asks whether to remove those keys (`[y/N]`, default no). On yes, each file it will edit is first copied to `.backup/<name>.bak`; if a backup fails, nothing is removed. `dc tidy --undo` puts the project `.env` back from that backup.

```bash
dc unused
```

### tidy

Rewrite `.env` into clean sections after you confirm:

1. Script Settings (`APPS`, `ARCHIVE`, compose filenames, stub, `STARTING_PORT`, …)
2. Universal Settings
3. User Specific Settings (`PUID`, `PGID`, `TZ`)
4. Ports — every `*_PORT_*` key, sorted by port value ascending
5. Your category comments (for example `# Minio`) with their keys kept together
6. Other — leftover keys, A–Z

Duplicate keys keep the last value. Saves the previous file as `.backup/.env.bak` (next to the env file’s directory).

```bash
dc tidy
dc tidy --undo
```

`--undo` restores `.env` from that backup (`.backup/.env.bak`, or a legacy `.env.bak` beside the file). Asks before replacing.

### move

Copy a service folder to another host that also runs this script. Works for **enabled**, **disabled**, and **archived** services.

```bash
dc move plex root@other-host
dc move plex other-host
dc move apollo other-host          # archived stays archived
```

| Source on this host | Lands on other host |
|---------------------|---------------------|
| Enabled / disabled under `APPS` | Disabled under `APPS` |
| Archived under `ARCHIVE` | Archived under that host’s `ARCHIVE` |

Flow:

1. Contact the host over SSH (BatchMode, public key only — no password prompt)
2. Discover remote `compose.sh` and `APPS` from that host’s `dc.bash` source line
3. Show size, destination, env keys from the project `.env` **and** that service’s env files (last wins), skipped outside mounts (and that an archived move stays archived)
4. Abort before confirm if any path under the service folder is not readable by the current user (typical root-owned container data)
5. Confirm move; for APPS services, optionally stop running containers first (skipped when already archived)
6. Pack with a progress bar, send with a progress bar (`COMPOSE-MOVE 2` stream)
7. Remote `receive` writes the folder disabled under `APPS`, or under `ARCHIVE` when the source was archived; merges missing project `.env` keys (service env files travel inside the folder)
8. On APPS sources: disable locally if it was enabled; ask whether to delete the local folder. On archived sources: ask whether to remove from this archive.

Both hosts need a current script (protocol `COMPOSE-MOVE 2`). `dc host add root@host` can remember a short name so later moves use `dc move plex host` (tab-completes those names). Short names live in `~/.ssh/compose-hosts` and a managed block in `~/.ssh/config`.

Does not copy: bind mounts outside the service folder, named volumes, or the image (the other host pulls on start after unarchive/enable).

### receive

Internal action used by `move` on the destination. Saves the stdin stream before Docker starts so the transfer is not consumed. Not meant for daily use.

```bash
compose.sh -a receive -s plex   # fed by move over SSH
```

### path

Internal action used by `move` discovery on the other host. Not listed in help. Prints raw paths:

```text
script=/path/to/compose.sh
apps=/path/to/apps
```

```bash
compose.sh -a path
```

---

## Script

### update

Print the local version and check GitHub. If a higher version exists, asks whether to install it (`[y/N]`). Scheduled / non-interactive runs install without asking. A local build ahead of GitHub does not prompt. `.env` is never overwritten.

```bash
dc update
dc update --check
dc update --force
```

- `--check` — report the version and whether a newer one exists; never installs
- `--force` — re-download repo files even when the version already matches, then stop (does not loop)

On a git checkout of this repo, update pulls the remote instead. Files refreshed without git: `compose.sh`, `dc.bash`, `README.md`, `DOCS.md`, `CHANGELOG.md`, `docker-compose.yml`, `.env.example`, `.gitignore`, `LICENSE`. After installing, the new script runs `update --check` once to show its version.

Releases use **major.feature.fix**: feature bumps the middle number and resets fix to `0`; fixes bump the last number; breaking changes bump major.

### host

Manage the hosts `move` can send services to.

```bash
dc host add
dc host add root@other-host
dc host list
dc host
```

- **add [user@host]** — create or reuse an SSH key (`~/.ssh/id_ed25519` preferred, empty passphrase when creating). With a host: ask before `ssh-copy-id`, then verify BatchMode connect, and remember `host` → `user@host` for short-name moves. Without a host: print the install command and a sample `ssh-copy-id` line.
- **list** (default) — list saved short host names, show `connects as`, and probe whether `move` can connect (✔ ok / ✘ fail). While each host is checked, a spinner shows `checking HOST (n/total)`.

### setup

Check `~/.bashrc` for `source …/dc.bash`. If missing, show the line and ask before appending it. Works before `.env` exists, so a new install can run it first.

```bash
dc setup
/path/to/compose.sh -a setup
```

### schedule

Manage user crontab entries for this helper. Lines are tagged `# compose-schedule:ACTION [options]`. One schedule per action.

```bash
dc schedule
dc schedule logs
dc schedule add images --pull 0 4 '*' '*' '*'
dc schedule add update 0 5 '*' '*' 0
dc schedule remove images
```

- **list** (default) — show managed jobs and cron times; one footer line points at the log directory and `dc schedule logs`
- **logs** — table of action, when, and log basename; full directories listed under the table (counts when a job logs outside the default `.logs/`)
- **add ACTION [options] m h dom mon dow** — options from that action (for example `images --pull`, `clean --yes`, `update --check`, `host list`), then five cron fields; asks before writing
- **remove ACTION** — asks before deleting; also removes jobs for actions that no longer exist

Allowed actions: `up`, `list`, `ps`, `issue`, `images`, `ports`, `nextport`, `df`, `clean`, `tidy`, `update`, `host`. A scheduled `up` runs every enabled service, for example `dc schedule add up '*/15' '*' '*' '*' '*'`.

Jobs from older versions that use `pull`, `hosts`, or `version` are marked on `dc schedule`, which offers to rewrite them as `images --pull`, `host list`, and `update --check` (keeping the time, env file, and paths).

Cron runs with `COMPOSE_NONINTERACTIVE=1`. Logs go to `.logs/schedule-ACTION.log` next to the script. Jobs added before 2.2.1 log to `logs/`; `dc schedule` offers to point them at `.logs/` and moves their log files. Requires `crontab` on the host.

### docs

Show this documentation.

```bash
dc docs
dc docs images
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
| `ARCHIVE` | Root for archived services (default `APPS/.archive`) |
| `COMPOSE_FILE` | Enabled compose filename |
| `COMPOSE_FILE_DISABLED` | Disabled compose filename |
| `STUB_FILE` | Template for `create` |
| `STARTING_PORT` | Floor for `nextport` (default 5000) |
| `COMPOSE_VERSION` | Compose file version hint in stub/env |
| `PUID` / `PGID` / `TZ` | Common container user/timezone |
| `TIME` / `DOCKER_SOCK` | Common volume snippets |
| `DOCKERLOGGING_*` | Logging defaults |
| `*_PORT_*` | Published ports tracked by `ports`, `nextport`, `tidy` (project + service env files) |

---

## SSH and move checklist

1. `dc host add root@other-host` — create/install key, remember short name  
2. `dc host list` — confirm ✔ ok  
3. Ensure the other host has this script and ran `dc setup` (dc.bash sourced)  
4. `dc move servicename other-host`  

Password SSH is not used (`BatchMode=yes`). Use keys only.
