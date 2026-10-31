# Docker Compose Helper

Personal docker compose management. The short command is `dc`.

## Documentation

- **[DOCS.md](DOCS.md)** — full command reference (`dc docs`, `dc docs pull`)
- **[CHANGELOG.md](CHANGELOG.md)** — version history

## Setup

`dc` is defined in `dc.bash`, next to `compose.sh`. On a new install, `~/.bashrc` gets one `source` line. That line stays put when the helper changes.

### New install

1. Clone this repo into the directory that holds your app folders, for example `/home/docker/docker`.
2. Copy `.env.example` to `.env` and set `APPS` to that directory.
3. Add the `dc` command to your shell:

```bash
/home/docker/docker/compose.sh -a bashrc
```

That checks `~/.bashrc` for `source /home/docker/docker/dc.bash` and asks before adding it. Enter means no.

4. Open a new shell.

```bash
dc list
dc up plex
dc help
dc docs
```

`dc` takes an action, an optional service name, and extra arguments after `--` for Compose. Tab completion lists actions, then `all` and service folders from `APPS`.

### Updates

```bash
dc version
dc update
dc repull
```

`dc version` asks before installing a newer release. `dc update` downloads when the published version differs. `dc repull` downloads again even when the version already matches.

Without git, those commands refresh `compose.sh`, `dc.bash`, `README.md`, `DOCS.md`, `CHANGELOG.md`, `docker-compose.yml`, `.env.example`, `.gitignore`, and `LICENSE`. Your `.env` is never overwritten. On a git checkout of this repo, they pull the remote instead. Open a new shell afterward so the helper reloads.

## Service stub

`docker-compose.yml` is the template `dc create` copies into a new service folder. `STUB_FILE` in `.env` points at it. `dc create` replaces `{{SERVICE}}` and `{{IMAGE}}` with the service name and image.

The stub sets `network_mode: bridge`. Comment that line out when another service needs to reach this one on the Compose project network (hostname `app`), or when you use host networking.
