# Docker Compose Helper
Personal docker compose management

## Setup

`dc` is the short command for `compose.sh`. The function and its Tab completion live in `dc.bash`, next to the script. On a new install, `~/.bashrc` gets one `source` line. That line stays put when the helper changes.

### New install

1. Clone this repo into the directory that holds your app folders, for example `/home/docker/docker`.
2. Copy `.env.example` to `.env` and set `APPS` to that directory.
3. Add this line to `~/.bashrc`. Use the directory from step 1:

```bash
source /home/docker/docker/dc.bash
```

4. Open a new shell.

```bash
dc list
dc up plex
dc logs plex --tail 100
dc ps plex
dc config plex
dc images
dc pull
```

`dc` takes an action, an optional service name, and any extra arguments are passed through to `docker compose`. The first Tab lists actions. The second Tab lists `all` and the service folders from `APPS` in `.env`. `dc logs plex -f` follows one service. Follow is refused when no service is named, because that would block on the first service.

### Updates

```bash
dc update
```

That downloads a new `compose.sh` and a new `dc.bash`. On a git checkout of this repo, the same command pulls the repo and updates both files. Open a new shell afterward so the helper reloads. New actions show up in Tab completion without editing `~/.bashrc`.

## Changes

### 1.7.0 One command runner, logs/ps/config, and update checks only on version and update
### 1.6.0 Added images and pull actions, and a sourced dc.bash helper
### 1.5.0 Updated edit function to check disabled services
### 1.4.5 Added Env action and fixed edit action
### 1.4.0 Fixed list action and added edit action
### 1.3.0 Better help menu, Ports action
### 1.2.1 Added gitignore file
### 1.2.0 Better CLI responses
### 1.1.1 Fixed listing of running containers
### 1.1.0 Added new list visual, run version check on start of script
### 1.0.1 Add note about being up-to-date on version check
### 1.0.0 First release
