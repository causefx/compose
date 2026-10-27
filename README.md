# Docker Compose Helper
Personal docker compose management

## Setup

`dc` is the short command for `compose.sh`. The function and its Tab completion live in `dc.bash`, next to the script. On a new install, `~/.bashrc` gets one `source` line. That line stays put when the helper changes.

### New install

1. Clone this repo into the directory that holds your app folders, for example `/home/docker/docker`.
2. Copy `.env.example` to `.env` and set `APPS` to that directory.
3. Print the `source` line and add it to `~/.bashrc`. Use the directory from step 1:

```bash
/home/docker/docker/compose.sh -a bashrc >> ~/.bashrc
```

That command prints one line, `source /home/docker/docker/dc.bash`, using the path of the script you ran.

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

`dc` takes an action, an optional service name, and any extra arguments are passed through to `docker compose`. The first Tab lists actions. The second Tab lists `all` and the service folders from `APPS` in `.env`. `dc logs plex -f` follows one service. Follow is refused when no service is named, because that would block on the first service. `dc pull` skips an image when its local digest matches the registry index or the platform manifest, and pulls the ones that differ. `dc up all` prints one line per service when its containers are already in that state. Compose's own output stays on screen when a container changes, a command fails, or the service takes more than a few seconds.

### Updates

```bash
dc update
dc repull
```

`dc update` checks the published version and downloads when it differs. `dc repull` downloads again even when the version already matches.

Without git, both commands download `compose.sh`, `dc.bash`, `docker-compose.yml`, `README.md`, `.env.example`, `.gitignore`, and `LICENSE`. Your `.env` stays as it is. On a git checkout of this repo, they pull the repo and update those files. Open a new shell afterward so the helper reloads. New actions show up in Tab completion without editing `~/.bashrc`.

## Service stub

`docker-compose.yml` is the template `dc create` copies into a new service folder. `STUB_FILE` in `.env` points at it. `dc create` replaces `{{SERVICE}}` and `{{IMAGE}}` with the service name and image. Those placeholders are quoted in `name`, `container_name`, `hostname`, and `image` so the braces stay intact.

The stub sets `network_mode: bridge`. Comment that line out when you add another service that needs to reach this one. Compose then puts both services on the project network, and the second service can reach this one at the hostname `app`. `network_mode: bridge` uses the default Docker bridge instead, which does not provide that name lookup and cannot be combined with a `networks:` list. Also comment it out to use the host network or another container's network.

## Changes

### 1.7.9 Status marks on list, images, pull, and prompts
### 1.7.8 Pull reads RepoDigests when the list digest is blank
### 1.7.7 Batch actions print one line per service
### 1.7.6 Pull matches the index or platform digest
### 1.7.5 Pull skips images already at the registry digest
### 1.7.4 Added repull to re-download repo files
### 1.7.3 Non-git update refreshes every repo file
### 1.7.2 Quoted stub placeholders and bridge network_mode
### 1.7.1 Added bashrc action to print the dc.bash source line
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
