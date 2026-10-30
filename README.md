# Docker Compose Helper
Personal docker compose management

## Setup

`dc` is the short command for `compose.sh`. The function and its Tab completion live in `dc.bash`, next to the script. On a new install, `~/.bashrc` gets one `source` line. That line stays put when the helper changes.

### New install

1. Clone this repo into the directory that holds your app folders, for example `/home/docker/docker`.
2. Copy `.env.example` to `.env` and set `APPS` to that directory.
3. Add the `dc` command to your shell. Use the directory from step 1:

```bash
/home/docker/docker/compose.sh -a bashrc
```

That checks `~/.bashrc` for `source /home/docker/docker/dc.bash` and asks before adding it. Enter means no.

4. Open a new shell.

```bash
dc list
dc up plex
dc logs plex --tail 100
dc ps plex
dc issue
dc issue plex
dc stats
dc top plex
dc exec plex -- bash
dc cp plex -- ./file plex:/tmp/file
dc key
dc key root@other-host
dc hosts
dc move plex other-host
dc tidy
dc df
dc prune
dc config plex
dc images
dc pull
```

`dc` takes an action, an optional service name, and any extra arguments are passed through to `docker compose`. The first Tab lists actions. The second Tab lists `all` and the service folders from `APPS` in `.env`. `dc logs plex -f` follows one service. Follow is refused when no service is named, because that would block on the first service. `dc pull` skips an image when its local digest matches the registry index or the platform manifest, and pulls the ones that differ. `dc issue` lists containers that are unhealthy, restarting, dead, or exited with a failure. Each one includes why, the next command, and a short log tail. `dc stats` shows CPU, memory, and network for running containers. `dc top plex` shows the processes in one service. `dc exec plex -- bash` runs a command in that service. `dc cp plex -- ./file plex:/tmp/file` copies a file into that service. The name before the colon is the service in the compose file. `dc key` creates an SSH key with an empty passphrase. `dc key root@other-host` asks before it installs that key, remembers `other-host` as that user, then checks that `dc move` can connect. `dc hosts` lists those short names and checks which ones still accept a connection. `dc move plex other-host` uses the saved user. `dc tidy` keeps the script, universal, and user settings at the top of `.env`, groups `_PORT_` keys by ascending port value, sorts the rest, and asks before it rewrites the file. `dc move plex root@other-host` copies that service to a host that has this script. The other host reports its own path. The compose file's variables are added to that host's `.env` when the key is missing. The service lands disabled there and is disabled here. The last question removes the local folder only when you answer yes. `dc df` shows Docker disk usage. `dc prune` shows that usage, then asks before it removes unused images and, separately, unused volumes. Help lists actions in Run, Check, Services, and Script. New actions are added in the `ActionSpec` list in `compose.sh`. Help text and `dc` tab completion both read that list. `dc up all` prints one line per service when its containers are already in that state. Compose's own output stays on screen when a container changes, a command fails, or the service takes more than a few seconds.

### Updates

```bash
dc update
dc repull
```

`dc version` asks before it installs a newer release. `dc update` downloads when the published version differs. `dc repull` pulls again even when the version already matches, then stops.

Without git, both commands download `compose.sh`, `dc.bash`, `docker-compose.yml`, `README.md`, `.env.example`, `.gitignore`, and `LICENSE`. Your `.env` stays as it is. On a git checkout of this repo, they pull the repo and update those files. Open a new shell afterward so the helper reloads. New actions show up in Tab completion without editing `~/.bashrc`.

## Service stub

`docker-compose.yml` is the template `dc create` copies into a new service folder. `STUB_FILE` in `.env` points at it. `dc create` replaces `{{SERVICE}}` and `{{IMAGE}}` with the service name and image. Those placeholders are quoted in `name`, `container_name`, `hostname`, and `image` so the braces stay intact.

The stub sets `network_mode: bridge`. Comment that line out when you add another service that needs to reach this one. Compose then puts both services on the project network, and the second service can reach this one at the hostname `app`. `network_mode: bridge` uses the default Docker bridge instead, which does not provide that name lookup and cannot be combined with a `networks:` list. Also comment it out to use the host network or another container's network.

## Changes

### 1.7.32 tidy organizes the env file and sorts ports
### 1.7.31 hosts lists the short names ready for move
### 1.7.30 key remembers a short host name for move
### 1.7.29 bashrc adds its source line when you say yes
### 1.7.28 receive keeps the move stream away from docker
### 1.7.27 move accepts the other host's script folder
### 1.7.26 key uses the host you typed, and move says when it is contacting that host
### 1.7.25 key installs the SSH key on a host when you say yes
### 1.7.24 key creates an SSH key and prints how to install it
### 1.7.23 move shows a progress bar while copying
### 1.7.22 move sends a service to another host
### 1.7.21 cp copies files and prune removes unused Docker data
### 1.7.20 help groups actions and adds stats, top, exec, and df
### 1.7.19 enabled services list above disabled ones
### 1.7.18 edit opens the editor on the terminal
### 1.7.17 issue lists containers that need attention
### 1.7.16 ps keeps blank ports from moving the service name
### 1.7.15 update downloads once and repull does not loop
### 1.7.14 ps lists every container from docker ps
### 1.7.13 Clearer banner, image rows, and ps table
### 1.7.12 One action list drives help and completion
### 1.7.11 Pull lists images that have updates
### 1.7.10 Lists group rows and line up columns
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
