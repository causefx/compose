#!/bin/bash
VERSION=v2.2.1
### ChangeNotes: schedule logs move to .logs.
set -o pipefail
GITHUB="https://github.com/causefx/compose"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/causefx/compose/main"
GITHUB_RAWURL="$GITHUB_RAW_BASE/compose.sh"
SCRIPT_ARGS=( "$@" )
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_WORKING_DIR="$(dirname "$SCRIPT_PATH")"

LATEST_RELEASE=""
LATEST_CHANGES=""
EXTRA_ARGS=()
DockerCmd=()
declare -A PROJECT_STATUS=()
PROJECT_STATUS_LOADED=0
declare -a CTR_SVC=() CTR_NAME=() CTR_STATUS=() CTR_PORTS=()
# Env file values live in ENV_VAL, not shell variables, so a key like VERSION
# cannot overwrite script state. SHELL_ENV is the exported environment at start,
# the fallback for ${VAR} expansion.
declare -A ENV_VAL=() SHELL_ENV=()
while IFS= read -r _env_name; do
    SHELL_ENV["$_env_name"]="${!_env_name}"
done < <(compgen -e)
unset _env_name

### Colors:
c_red="\033[0;31m"
c_green="\033[0;32m"
c_yellow="\033[0;33m"
c_blue="\033[0;34m"
c_teal="\033[0;36m"
c_dim="\033[2m"
c_bold="\033[1m"
c_reset="\033[0m"

Banner() {
    local title=" ${*^^} "
    local fill=$(( 44 - ${#title} ))
    local bar
    if (( fill < 8 )); then
        fill=8
    fi
    printf -v bar '%*s' "$fill" ''
    bar="${bar// /━}"
    printf "\n%b%s%s%b\n" "${c_bold}${c_teal}" "$title" "$bar" "$c_reset"
}

Say() {
    local kind="$1"
    shift
    local color="$c_teal" mark="·" stream=1
    case "$kind" in
        ok) color="$c_green"; mark="✔" ;;
        warn) color="$c_yellow"; mark="!" ;;
        bad) color="$c_red"; mark="✘" ;;
        baderr) color="$c_red"; mark="✘"; stream=2 ;;
        info) color="$c_teal"; mark="·" ;;
    esac
    printf "  %b%s%b  %s\n" "$color" "$mark" "$c_reset" "$*" >&"$stream"
}

NonInteractive() {
    # Scheduled jobs set this. Do not key off stdout: Ask runs inside $(), so
    # stdout is a pipe even on a normal terminal.
    [[ "${COMPOSE_NONINTERACTIVE:-0}" == 1 ]] && return 0
    if { : </dev/tty >/dev/tty; } 2>/dev/null; then
        return 1
    fi
    [[ -t 0 ]] && return 1
    return 0
}

Ask() {
    local reply
    if [[ "${COMPOSE_NONINTERACTIVE:-0}" == 1 ]]; then
        printf '%s' ""
        return 0
    fi
    printf "  %b?%b  %s " "$c_teal" "$c_reset" "$1" >&2
    if { : </dev/tty >/dev/tty; } 2>/dev/null; then
        IFS= read -r reply </dev/tty || reply=""
    elif [[ -t 0 ]]; then
        IFS= read -r reply || reply=""
    else
        reply=""
    fi
    printf '%s' "$reply"
}

# Sets STATUS_COLOR for a container status (no subshell).
StatusColor() {
    STATUS_COLOR="$c_dim"
    case "${1,,}" in
        *unhealthy*|*restarting*|*paused*|*created*) STATUS_COLOR="$c_yellow" ;;
        up\ *|*running*|*healthy*) STATUS_COLOR="$c_green" ;;
        *exited*|*stopped*|*dead*) STATUS_COLOR="$c_red" ;;
    esac
}

ColumnWidth() {
    local max="$1"
    shift
    local item
    for item in "$@"; do
        if (( ${#item} > max )); then
            max=${#item}
        fi
    done
    printf '%s' "$max"
}

# Add an action here. Help, dispatch, scheduling, and dc.bash read this list.
# name|flags|function|function args|options|description
# flags: s = next dc word is the service name
#        j = can be scheduled (dc schedule add)
#        d = probe for docker compose before running
#        h = hidden from help, completion, and schedule add
# options: words the action accepts after its name or service; drive help,
#          dc tab completion, and which options a schedule may pass.
ActionSpec() {
    cat <<'EOF'
# @actions
# @group Run
up|sjd|RunCompose|up -d||Create and start containers
down|sd|RunCompose|down||Stop and remove containers, networks
start|sd|RunCompose|start||Start service(s)
stop|sd|RunCompose|stop||Stop service(s)
restart|sd|RunCompose|restart||Restart service container(s)
build|sd|RunCompose|build||Build service image(s)
pause|sd|RunCompose|pause||Pause service(s)
unpause|sd|RunCompose|unpause||Unpause service(s)
exec|sd|Exec|||Run a command in a service
cp|sd|Cp|||Copy files to or from a service
# @group Check
list|sjd|List|||List services and env files
ps|sjd|Ps|||Show container(s)
issue|sjd|Issue|||Show containers that need attention
logs|sd|Logs|||Show service logs
top|sd|RunCompose|top||Show processes in a container
stats|sd|Stats|||Show CPU, memory, and network
images|sjd|ShowImages|list|--pull|List compose images; --pull pulls updates
config|sd|RunCompose|config||Render compose file(s)
cmd|sd|Cmd|||Print docker compose up with env files
ports|sj|CheckPorts|||Show ports from all env files
nextport|j|NextPort|||Show the next free host port
df|j|Disk|||Show Docker disk usage
clean|j|Clean||--yes|Remove unused images, cache, containers, networks, and volumes
# @group Services
enable|sd|Toggle|enable||Enable service(s)
disable|sd|Toggle|disable||Disable service(s)
archive|sd|Archive|||Archive disabled service(s)
unarchive|sd|Unarchive|||Restore archived service(s)
create|s|Create|||Create service
add|sd|Add|||Add an app to a service compose file
remove|sd|Remove|||Remove service
rename|sd|Rename|||Rename a service folder and env keys
move|sd|Move|||Move a service to another host
receive|s|Receive|||Receive a service from another host
edit|s|EditFile|||Edit service
env|s|EditEnv|||Edit project or service env file
envs|s|Envs||values fill|List or fill env vars for a service
where||Where|||Show where an env var is used
unused||Unused|||List unused env vars and ask to remove
tidy|j|TidyEnv||--undo|Organize the env file; --undo restores the backup
# @group Script
update|j|UpdateScript||--check --force|Check for and install a newer version
host|j|Host||add list|Add a host for move, or list saved hosts
setup||Setup||bashrc|Add the dc.bash source line to ~/.bashrc
schedule||Schedule||list add remove|Manage scheduled compose actions
docs||Docs|||Show command documentation
help||Help|||This help menu
path|h|Path|||Print script and APPS paths
version|h|UpdateScript|--check||Display version
pull|hsd|ShowImages|pull||Old name for images --pull
hosts|h|Hosts|||Old name for host list
prune|h|Clean|||Old name for clean
# @end
EOF
}

EachAction() {
    local line
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        printf '%s\n' "$line"
    done < <(ActionSpec)
}

# Sets ACT_FLAGS, ACT_FN, ACT_ARGS, ACT_OPTS, ACT_DESC for action $1. Exit 1 if unknown.
ActionLookup() {
    local name flags fn args opts desc
    ACT_FLAGS="" ACT_FN="" ACT_ARGS="" ACT_OPTS="" ACT_DESC=""
    while IFS='|' read -r name flags fn args opts desc; do
        [[ "$name" == "$1" ]] || continue
        ACT_FLAGS="$flags" ACT_FN="$fn" ACT_ARGS="$args" ACT_OPTS="$opts" ACT_DESC="$desc"
        return 0
    done < <(EachAction)
    return 1
}

# ActionHasFlag <action> <flag>
ActionHasFlag() {
    ActionLookup "$1" || return 1
    [[ "$ACT_FLAGS" == *"$2"* ]]
}

# ActionHasOption <action> <word>: word is in the action's options column.
ActionHasOption() {
    ActionLookup "$1" || return 1
    [[ -n "$2" && " $ACT_OPTS " == *" $2 "* ]]
}

# Prints the names of visible actions whose flags contain $1, space separated.
ActionsWithFlag() {
    local name flags out=""
    while IFS='|' read -r name flags _; do
        [[ "$flags" == *h* ]] && continue
        [[ "$flags" == *"$1"* ]] && out+="$name "
    done < <(EachAction)
    printf '%s' "${out% }"
}

Help() {
    local line name flags fn args opts desc group shown
    local first=1
    Banner "help"
    printf "  %bcompose.sh -a <action> [-s service] [-- extra args]%b\n" "$c_dim" "$c_reset"
    printf "  %b-e <file>%b   env file, default %s\n" "$c_dim" "$c_reset" "$SCRIPT_WORKING_DIR/.env"
    printf "  %bexample%b     compose.sh -a logs -s plex -- --tail 100\n" "$c_dim" "$c_reset"
    printf "  %bexample%b     compose.sh -a move -s plex -- root@other-host\n" "$c_dim" "$c_reset"
    printf "  %bexample%b     compose.sh -a host -- add root@other-host\n" "$c_dim" "$c_reset"
    printf "  %bexample%b     compose.sh -a schedule -- add images --pull 0 4 '*' '*' '*'\n" "$c_dim" "$c_reset"
    printf "  %bexample%b     compose.sh -a docs -- images\n" "$c_dim" "$c_reset"
    Banner "actions"
    while IFS= read -r line; do
        if [[ "$line" == "# @group "* ]]; then
            group="${line#\# @group }"
            [[ "$first" -eq 0 ]] && printf "\n"
            first=0
            printf "  %b%s%b\n" "$c_dim" "${group^^}" "$c_reset"
            continue
        fi
        [[ -z "$line" || "$line" == \#* ]] && continue
        IFS='|' read -r name flags fn args opts desc <<< "$line"
        [[ "$flags" == *h* ]] && continue
        shown=""
        [[ -n "$opts" ]] && shown="  [${opts// /|}]"
        printf "  %b%-10s%b  %s%b%s%b\n" "$c_teal" "$name" "$c_reset" "$desc" "$c_dim" "$shown" "$c_reset"
    done < <(ActionSpec)
}

while getopts "ha:f:s:e:" options; do
  case "${options}" in
    a) action=${OPTARG} ;;
    f|s) folder=${OPTARG} ;;
    e) envFile=${OPTARG} ;;
    h|*) Help ; exit 0 ;;
  esac
done
shift $((OPTIND-1))
if [[ "${1:-}" == "--" ]]; then
  shift
fi
EXTRA_ARGS=("$@")

RECEIVE_STREAM=""
if [[ "${action:-}" == "receive" || "${action:-}" == "Receive" ]]; then
    RECEIVE_STREAM="$(mktemp)" || exit 1
    trap 'rm -f "$RECEIVE_STREAM"' EXIT
    cat >"$RECEIVE_STREAM" || exit 1
fi

LowerCaseArguments() {
    action="${action,,}"
    # where takes an env var name; keep its case (MEDIA ≠ media).
    if [[ "$action" != "where" ]]; then
        folder="${folder,,}"
    fi
}


CheckEnv() {
    if [ -z "$envFile" ]; then
        envFile="$SCRIPT_WORKING_DIR/.env"
    fi

    if [ ! -f "$envFile" ]; then
        Say bad "Env file does not exist: $envFile"
        exit 1
    fi

    LoadEnvValues "$envFile" settings
}

RequireVar() {
    local name
    for name in "$@"; do
        if [[ -z "${!name}" ]]; then
            Say bad "Variable not set: $name"
            exit 1
        fi
    done
}

CheckEnvVariables() {
    RequireVar COMPOSE_FILE COMPOSE_FILE_DISABLED STUB_FILE APPS
    if [[ -z "${ARCHIVE:-}" ]]; then
        ARCHIVE="$APPS/.archive"
    fi
}

ServiceDirs() {
    local had=0 dir
    shopt -q nullglob && had=1
    shopt -s nullglob
    for dir in "$APPS"/*/; do
        [[ -d "$dir" ]] && printf '%s\n' "$dir"
    done
    [[ "$had" -eq 1 ]] || shopt -u nullglob
}

ArchiveDir() {
    printf '%s\n' "${ARCHIVE%/}"
}

ArchivedServiceDirs() {
    local root had=0 dir
    root="$(ArchiveDir)"
    [[ -d "$root" ]] || return 0
    shopt -q nullglob && had=1
    shopt -s nullglob
    for dir in "$root"/*/; do
        [[ -d "$dir" ]] && printf '%s\n' "$dir"
    done
    [[ "$had" -eq 1 ]] || shopt -u nullglob
}

CheckDockerCompose() {
    [[ ${#DockerCmd[@]} -gt 0 ]] && return 0
    if docker compose version </dev/null &>/dev/null; then
        DockerCmd=(docker compose)
    elif docker-compose version </dev/null &>/dev/null || docker-compose -v </dev/null &>/dev/null; then
        DockerCmd=(docker-compose)
    else
        Say bad "No docker binaries available, exiting."
        exit 1
    fi
}

LoadProjectStatus() {
    local json name status
    local -a names=() statuses=()
    local i

    if [[ "$PROJECT_STATUS_LOADED" -eq 1 ]]; then
        return 0
    fi
    PROJECT_STATUS=()
    PROJECT_STATUS_LOADED=1
    CheckDockerCompose
    json="$("${DockerCmd[@]}" ls -a --format json 2>/dev/null || true)"
    [[ -n "$json" ]] || return 0

    while IFS= read -r name; do
        [[ -n "$name" ]] && names+=("$name")
    done < <(printf '%s\n' "$json" | grep -oE '"Name":[[:space:]]*"[^"]*"' | sed -E 's/^"Name":[[:space:]]*"([^"]*)"$/\1/')
    while IFS= read -r status; do
        [[ -n "$status" ]] && statuses+=("$status")
    done < <(printf '%s\n' "$json" | grep -oE '"Status":[[:space:]]*"[^"]*"' | sed -E 's/^"Status":[[:space:]]*"([^"]*)"$/\1/')

    if [[ ${#names[@]} -ne ${#statuses[@]} ]]; then
        return 0
    fi
    for i in "${!names[@]}"; do
        PROJECT_STATUS["${names[$i]}"]="${statuses[$i]}"
    done
}

CheckStatus() {
    local name="$1"
    local status
    CheckFolderSupplied "$name"
    LoadProjectStatus
    status="${PROJECT_STATUS[$name]:-}"
    if [[ "$status" =~ (running|paused|stopped|exited|restarting|created|dead) ]]; then
        return 0
    fi
    return 1
}

ReturnStatus() {
    local name="$1"
    CheckFolderSupplied "$name"
    LoadProjectStatus
    if [[ -n "${PROJECT_STATUS[$name]:-}" ]]; then
        printf '%s' "${PROJECT_STATUS[$name]}"
    else
        printf '%s' " - "
    fi
}

CheckFolderSupplied() {
    if [ -z "$1" ]; then
        Say bad "Service name not supplied."
        exit 1
    fi
}

CheckFolderSuppliedNoExit() {
    if [ -n "$1" ]; then
        return 0
    else
        return 1
    fi
}

# Action Functions
CheckAction() {
    local renamed
    if [[ -z "${action:-}" ]]; then
        Say bad "Invalid option. Run compose.sh -h for available actions."
        exit 1
    fi
    if ! ActionLookup "$action"; then
        if renamed="$(ActionRenamed "$action")"; then
            Say bad "$action is now $renamed."
            Say info "dc $renamed"
            exit 1
        fi
        Say bad "Invalid option. Run compose.sh -h for available actions."
        Help
        exit 1
    fi
    if ! declare -F "$ACT_FN" >/dev/null; then
        Say bad "Unknown handler: $ACT_FN"
        exit 1
    fi
    # Hidden old names (pull, hosts, version) still run so existing cron jobs keep working.
    if [[ "$ACT_FLAGS" == *h* ]] && renamed="$(ActionRenamed "$action")"; then
        Say warn "$action is now $renamed. The old name still works for now."
    fi
    # Older dc.bash passed the first word as -s for actions that take none.
    if [[ "$ACT_FLAGS" != *s* && -n "${folder:-}" && " $ACT_OPTS " == *" $folder "* ]]; then
        EXTRA_ARGS=("$folder" "${EXTRA_ARGS[@]}")
        folder=""
    fi
    # shellcheck disable=SC2086
    "$ACT_FN" $ACT_ARGS
    return 0
}

RunCompose() {
    Banner "$action"
    RunServices "$folder" "$@" "${EXTRA_ARGS[@]}"
}

# UpdateScript [--check|--force]: options also come from EXTRA_ARGS.
UpdateScript() {
    local arg mode=""
    for arg in "$@" "${EXTRA_ARGS[@]}"; do
        case "$arg" in
            --check|--force)
                if [[ -n "$mode" && "$mode" != "$arg" ]]; then
                    Say bad "Use --check or --force, not both."
                    exit 1
                fi
                mode="$arg"
                ;;
            *)
                Say bad "Update takes --check or --force."
                Say info "dc update"
                Say info "dc update --check"
                Say info "dc update --force"
                exit 1
                ;;
        esac
    done
    Banner "update"
    Say ok "$VERSION"
    case "$mode" in
        --check) CheckVersion check ;;
        --force) Update ;;
        *)
            if NonInteractive; then
                CheckVersion apply
            else
                CheckVersion ask
            fi
            ;;
    esac
}

# Exit 0 when $1 is a higher vMAJOR.MINOR.PATCH than $2.
VersionIsNewer() {
    local left="${1#v}" right="${2#v}"
    local l1=0 l2=0 l3=0 r1=0 r2=0 r3=0
    IFS=. read -r l1 l2 l3 _ <<< "${left}.0.0.0"
    IFS=. read -r r1 r2 r3 _ <<< "${right}.0.0.0"
    [[ "$l1" =~ ^[0-9]+$ && "$l2" =~ ^[0-9]+$ && "$l3" =~ ^[0-9]+$ ]] || return 1
    [[ "$r1" =~ ^[0-9]+$ && "$r2" =~ ^[0-9]+$ && "$r3" =~ ^[0-9]+$ ]] || return 1
    ((10#$l1 > 10#$r1)) && return 0
    ((10#$l1 < 10#$r1)) && return 1
    ((10#$l2 > 10#$r2)) && return 0
    ((10#$l2 < 10#$r2)) && return 1
    ((10#$l3 > 10#$r3))
}

CheckVersion() {
    local mode="$1"
    local answer head line

    LATEST_RELEASE=""
    LATEST_CHANGES=""
    head="$(curl -fsS -r 0-200 "$GITHUB_RAWURL" 2>/dev/null || true)"
    while IFS= read -r line; do
        line="${line//$'\r'/}"
        case "$line" in
            VERSION=*)
                LATEST_RELEASE="${line#VERSION=}"
                LATEST_RELEASE="${LATEST_RELEASE//\"/}"
                ;;
            "### ChangeNotes: "*) LATEST_CHANGES="${line#"### ChangeNotes: "}" ;;
        esac
    done <<< "$head"

    if [[ -z "$LATEST_RELEASE" ]]; then
        Say warn "Could not check for updates."
        return 1
    fi

    if [[ "$VERSION" == "$LATEST_RELEASE" ]] || ! VersionIsNewer "$LATEST_RELEASE" "$VERSION"; then
        Say ok "Already up to date."
        return 0
    fi

    Say warn "New version available: $VERSION → $LATEST_RELEASE"
    [[ -n "$LATEST_CHANGES" ]] && Say info "Change notes: $LATEST_CHANGES"
    case "$mode" in
        apply)
            Update
            return
            ;;
        check)
            Say info "dc update"
            return 0
            ;;
    esac
    answer="$(Ask "Would you like to update? [y/N]")"
    [[ "$answer" =~ ^[yY] ]] && Update
}

DownloadFile() {
  local url="$1"
  local dest="$2"
  if [[ -n "$(builtin type -P curl)" ]]; then
    curl -fsSL "$url" -o "$dest"
    return $?
  elif [[ -n "$(builtin type -P wget)" ]]; then
    wget -q "$url" -O "$dest"
    return $?
  fi
  return 127
}

RelaunchUpdated() {
  local -a args=("-a" "update")
  local i n
  n=${#SCRIPT_ARGS[@]}
  i=0
  while [[ "$i" -lt "$n" ]]; do
    if [[ "${SCRIPT_ARGS[$i]}" == "-e" && $((i + 1)) -lt "$n" ]]; then
      args+=("-e" "${SCRIPT_ARGS[$((i + 1))]}")
    fi
    i=$((i + 1))
  done
  args+=("--" "--check")
  exec "$SCRIPT_PATH" "${args[@]}"
  exit 1
}

# Directory for .bak files next to a path (…/.backup).
BackupDirFor() {
    local file="$1"
    printf '%s/.backup\n' "$(dirname "$file")"
}

# Path for a backup copy: dir/.backup/basename.bak
BackupPathFor() {
    local file="$1"
    local bdir
    bdir="$(BackupDirFor "$file")"
    mkdir -p "$bdir" || return 1
    printf '%s/%s.bak\n' "$bdir" "$(basename "$file")"
}

# Prefer .backup/name.bak; fall back to legacy name.bak beside the file.
ResolveBackupPath() {
    local file="$1"
    local modern legacy
    modern="$(BackupDirFor "$file")/$(basename "$file").bak"
    legacy="${file}.bak"
    if [[ -f "$modern" ]]; then
        printf '%s\n' "$modern"
        return 0
    fi
    if [[ -f "$legacy" ]]; then
        printf '%s\n' "$legacy"
        return 0
    fi
    printf '%s\n' "$modern"
    return 1
}

UpdateCurl() {
  local -a repo_files=(
    compose.sh
    dc.bash
    README.md
    DOCS.md
    CHANGELOG.md
    docker-compose.yml
    .env.example
    .gitignore
    LICENSE
  )
  local -a tmps=()
  local name tmp dest bak i

  if [[ -z "$(builtin type -P curl)" && -z "$(builtin type -P wget)" ]]; then
    Say bad "curl/wget not available. Download the update manually: $GITHUB"
    return
  fi

  Say info "Downloading the update."

  for name in "${repo_files[@]}"; do
    tmp="$(mktemp)" || { [[ ${#tmps[@]} -gt 0 ]] && rm -f "${tmps[@]}"; return; }
    tmps+=("$tmp")
    if ! DownloadFile "$GITHUB_RAW_BASE/$name" "$tmp"; then
      rm -f "${tmps[@]}"
      Say bad "Download failed for $name. No files were changed."
      return
    fi
  done

  for name in "${repo_files[@]}"; do
    dest="$SCRIPT_WORKING_DIR/$name"
    if [[ -f "$dest" ]]; then
      bak="$(BackupPathFor "$dest")" || {
        rm -f "${tmps[@]}"
        Say bad "Could not create backup folder. No files were changed."
        return
      }
      if ! cp "$dest" "$bak"; then
        rm -f "${tmps[@]}"
        Say bad "Could not back up $name. No files were changed."
        return
      fi
    fi
  done

  for i in "${!repo_files[@]}"; do
    name="${repo_files[$i]}"
    dest="$SCRIPT_WORKING_DIR/$name"
    if ! cp "${tmps[$i]}" "$dest"; then
      for name in "${repo_files[@]}"; do
        dest="$SCRIPT_WORKING_DIR/$name"
        bak="$(ResolveBackupPath "$dest" 2>/dev/null || true)"
        if [[ -n "$bak" && -f "$bak" ]]; then
          cp "$bak" "$dest"
        fi
      done
      rm -f "${tmps[@]}"
      Say bad "Could not install the update."
      return
    fi
  done

  chmod +x "$SCRIPT_PATH"
  rm -f "${tmps[@]}"
  Say ok "Updated."
  RelaunchUpdated
}

Update() {
  local repo_url="" before="" after=""
  if [[ -n "$(builtin type -P git)" ]]; then
    repo_url="$(git -C "$SCRIPT_WORKING_DIR" remote get-url origin 2>/dev/null || true)"
  fi
  if [[ "$repo_url" == *causefx/compose* ]]; then
    Say info "Pulling the latest version."
    before="$(git -C "$SCRIPT_WORKING_DIR" rev-parse HEAD 2>/dev/null || true)"
    if ! git -C "$SCRIPT_WORKING_DIR" pull --force; then
      Say bad "Git error, manually pull/clone."
      return
    fi
    after="$(git -C "$SCRIPT_WORKING_DIR" rev-parse HEAD 2>/dev/null || true)"
    if [[ -n "$before" && "$before" == "$after" ]]; then
      Say ok "Already on the latest version."
      return 0
    fi
    Say ok "Updated."
    RelaunchUpdated
  fi
  UpdateCurl
}

# Exit 0 when the folder has a service env file (same filter as EnvFilesInDir, no subshell).
HasServiceEnv() {
    local dir="${1%/}" f had=0 rc=1
    shopt -q nullglob && had=1
    shopt -s nullglob
    for f in "$dir"/.env "$dir"/.env.* "$dir"/*.env; do
        [[ -f "$f" ]] || continue
        case "$f" in
            *.bak|*.example|*.sample|*.swp|*~) continue ;;
        esac
        [[ -n "${envFile:-}" && "$f" -ef "$envFile" ]] && continue
        rc=0
        break
    done
    [[ "$had" -eq 1 ]] || shopt -u nullglob
    return "$rc"
}

List() {
    local dir path status env_label env_color width row kind prev="" mark mark_color
    local -a names=() en_rows=() dis_rows=() ar_rows=()
    Banner "list"
    LoadProjectStatus
    while IFS= read -r dir; do
        path="${dir%/}"
        path="${path##*/}"
        status="${PROJECT_STATUS[$path]:-}"
        [[ -n "$status" ]] || status="no container"
        env_label="-"
        HasServiceEnv "$dir" && env_label="yes"
        if [ -f "$dir/$COMPOSE_FILE" ]; then
            en_rows+=("enabled|$path|$env_label|$status")
            names+=("$path")
        fi
        if [ -f "$dir/$COMPOSE_FILE_DISABLED" ]; then
            dis_rows+=("disabled|$path|$env_label|$status")
            names+=("$path")
        fi
    done < <(ServiceDirs)
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        path="${dir%/}"
        path="${path##*/}"
        env_label="-"
        HasServiceEnv "$dir" && env_label="yes"
        ar_rows+=("archived|$path|$env_label|archived")
        names+=("$path")
    done < <(ArchivedServiceDirs)
    if [[ ${#names[@]} -eq 0 ]]; then
        Say info "No services."
        return
    fi
    width="$(ColumnWidth 7 "${names[@]}")"
    printf "%b     %-*s  │  %-*s  │  %s%b\n" "$c_dim" \
        "$width" "service" \
        3 "env" \
        "containers" "$c_reset"
    for row in "${en_rows[@]}" "${dis_rows[@]}" "${ar_rows[@]}"; do
        IFS='|' read -r kind path env_label status <<<"$row"
        [[ -n "$prev" && "$kind" != "$prev" ]] && printf "\n  %b%s%b\n" "$c_dim" "$kind" "$c_reset"
        prev="$kind"
        case "$kind" in
            enabled) mark="✔"; mark_color="$c_green"; StatusColor "$status" ;;
            disabled) mark="✘"; mark_color="$c_red"; StatusColor "$status" ;;
            *) mark="▢"; mark_color="$c_dim"; STATUS_COLOR="$c_dim" ;;
        esac
        env_color="$c_dim"
        [[ "$env_label" == "yes" ]] && env_color="$c_teal"
        printf "  %b%s%b  %-*s  %b│%b  %b%-*s%b  %b│%b  %b%s%b\n" \
            "$mark_color" "$mark" "$c_reset" \
            "$width" "$path" \
            "$c_dim" "$c_reset" \
            "$env_color" 3 "$env_label" "$c_reset" \
            "$c_dim" "$c_reset" \
            "$STATUS_COLOR" "$status" "$c_reset"
    done
    printf "\n"
    Say info "${#en_rows[@]} enabled · ${#dis_rows[@]} disabled · ${#ar_rows[@]} archived"
}

Toggle() {
    local action="$1"
    local folder="${2:-$folder}"
    local fileName newFileName removeAnswer
    if [[ "$action" == "enable" ]]; then
        Say ok "Enabling $folder"
    else
        Say warn "Disabling $folder"
    fi
    CheckFolderSupplied "$folder"
    if ! ValidServiceName "$folder"; then
        Say bad "Invalid service name."
        exit 1
    fi
    if [[ "$action" == "enable" ]]; then
        fileName="$COMPOSE_FILE_DISABLED"
        newFileName="$COMPOSE_FILE"
    else
        fileName="$COMPOSE_FILE"
        newFileName="$COMPOSE_FILE_DISABLED"
    fi
    RequireComposeFile "$APPS/$folder"

    if [[ -f "$APPS/$folder/$fileName" ]]; then
        if [[ "$action" == "disable" ]] && CheckStatus "$folder"; then
            removeAnswer="$(Ask "Service is running. Stop and remove it? [y/N]")"
            if [[ "$removeAnswer" != [yY] ]]; then
                Say info "Left $folder enabled so dc can still manage its containers."
                return 0
            fi
            Say warn "Stopping and removing containers."
            if ! RunOneCompose "$APPS/$folder/$COMPOSE_FILE" down; then
                Say bad "Could not stop $folder. Left it enabled."
                exit 1
            fi
            Say ok "Service removed."
        fi
        if ! mv -- "$APPS/$folder/$fileName" "$APPS/$folder/$newFileName"; then
            Say bad "Could not rename the compose file."
            exit 1
        fi
    fi
    if [[ "$action" == "enable" ]]; then
        Say ok "Service enabled."
    else
        Say warn "Service disabled."
    fi
}

ListArchived() {
    local dir path env_label env_color width i
    local -a names=() envs=()

    while IFS='|' read -r path env_label; do
        [[ -n "$path" ]] || continue
        names+=("$path")
        envs+=("$env_label")
    done < <(
        while IFS= read -r dir; do
            [[ -n "$dir" ]] || continue
            path="${dir%/}"
            path="${path##*/}"
            if HasServiceEnv "$dir"; then
                printf '%s|yes\n' "$path"
            else
                printf '%s|-\n' "$path"
            fi
        done < <(ArchivedServiceDirs) | LC_ALL=C sort -t '|' -k1,1
    )
    if [[ ${#names[@]} -eq 0 ]]; then
        Say info "No archived services."
        Say info "Archive root: $(ArchiveDir)"
        return 0
    fi
    width="$(ColumnWidth 7 "${names[@]}")"
    printf "%b  %-*s  │  %s%b\n" "$c_dim" "$width" "service" "env" "$c_reset"
    for i in "${!names[@]}"; do
        if [[ "${envs[$i]}" == "yes" ]]; then
            env_label="yes"
            env_color="$c_teal"
        else
            env_label="-"
            env_color="$c_dim"
        fi
        printf "  %b%s%b  %-*s  %b│%b  %b%s%b\n" \
            "$c_dim" "▢" "$c_reset" \
            "$width" "${names[$i]}" \
            "$c_dim" "$c_reset" \
            "$env_color" "$env_label" "$c_reset"
    done
    printf "\n"
    Say info "${#names[@]} archived · $(ArchiveDir)"
}

ArchiveOne() {
    local name="$1" mode="${2:-}"
    local src dest root answer

    if ! ValidServiceName "$name"; then
        Say bad "Archive needs a service name."
        Say info "dc archive plex"
        Say info "dc archive all"
        return 1
    fi
    src="$APPS/$name"
    root="$(ArchiveDir)"
    dest="$root/$name"
    if [[ -d "$dest" && ! -d "$src" ]]; then
        Say info "Already archived: $name"
        Say info "dc unarchive $name"
        return 1
    fi
    if [[ ! -d "$src" ]]; then
        Say bad "Service does not exist."
        return 1
    fi
    if [[ -f "$src/$COMPOSE_FILE" ]]; then
        Say bad "Service is enabled. Disable it first."
        Say info "dc disable $name"
        return 1
    fi
    if [[ ! -f "$src/$COMPOSE_FILE_DISABLED" ]]; then
        Say bad "Service has no disabled compose file."
        return 1
    fi
    if [[ -e "$dest" ]]; then
        Say bad "Archive already has $name."
        return 1
    fi
    if [[ "$mode" != "noask" ]]; then
        answer="$(Ask "Archive disabled service $name? [y/N]")"
        if [[ "$answer" != [yY] ]]; then
            Say info "Left $name in place."
            return 0
        fi
    fi
    mkdir -p "$root" || {
        Say bad "Could not create archive directory."
        return 1
    }
    if ! mv -- "$src" "$dest"; then
        Say bad "Could not move $name to archive."
        return 1
    fi
    Say ok "Archived $name."
    [[ "$mode" == "noask" ]] || Say info "dc unarchive $name"
    return 0
}

UnarchiveOne() {
    local name="$1" mode="${2:-}"
    local src dest root answer

    if ! ValidServiceName "$name"; then
        Say bad "Unarchive needs a service name."
        Say info "dc unarchive plex"
        Say info "dc unarchive all"
        return 1
    fi
    root="$(ArchiveDir)"
    src="$root/$name"
    dest="$APPS/$name"
    if [[ ! -d "$src" ]]; then
        Say bad "Archived service does not exist."
        return 1
    fi
    if [[ -e "$dest" ]]; then
        Say bad "Service already exists under APPS: $name"
        return 1
    fi
    if [[ "$mode" != "noask" ]]; then
        answer="$(Ask "Unarchive $name as disabled? [y/N]")"
        if [[ "$answer" != [yY] ]]; then
            Say info "Left $name archived."
            return 0
        fi
    fi
    mkdir -p "$APPS" || {
        Say bad "Could not use APPS directory."
        return 1
    }
    if ! mv -- "$src" "$dest"; then
        Say bad "Could not move $name back to APPS."
        return 1
    fi
    Say ok "Unarchived $name (still disabled)."
    [[ "$mode" == "noask" ]] || Say info "dc enable $name"
    return 0
}

# BulkServiceAction <one_fn> <done_word> <question> <empty_msg> <names...>
# Asks once, then runs "<one_fn> <name> noask" for each name.
BulkServiceAction() {
    local fn="$1" done_word="$2" question="$3" empty_msg="$4"
    shift 4
    local name answer ok=0 fail=0
    if [[ $# -eq 0 ]]; then
        Say info "$empty_msg"
        return 0
    fi
    Say info "$# service(s)"
    answer="$(Ask "$question [y/N]")"
    if [[ "$answer" != [yY] ]]; then
        Say info "Left services in place."
        return 0
    fi
    for name in "$@"; do
        if "$fn" "$name" noask; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi
    done
    Say info "$ok $done_word · $fail skipped"
}

Archive() {
    local dir name
    local -a targets=()

    Banner "archive"
    if [[ -z "${folder:-}" ]]; then
        ListArchived
        return 0
    fi
    if [[ "$folder" != "all" ]]; then
        ArchiveOne "$folder"
        return
    fi
    while IFS= read -r dir; do
        name="${dir%/}"
        name="${name##*/}"
        [[ -f "$dir/$COMPOSE_FILE_DISABLED" && ! -f "$dir/$COMPOSE_FILE" ]] && targets+=("$name")
    done < <(ServiceDirs)
    BulkServiceAction ArchiveOne archived "Archive all disabled services?" \
        "No disabled services to archive." "${targets[@]}"
}

Unarchive() {
    local dir name
    local -a targets=()

    Banner "unarchive"
    if [[ -z "${folder:-}" ]]; then
        ListArchived
        return 0
    fi
    if [[ "$folder" != "all" ]]; then
        UnarchiveOne "$folder"
        return
    fi
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        name="${dir%/}"
        name="${name##*/}"
        targets+=("$name")
    done < <(ArchivedServiceDirs)
    BulkServiceAction UnarchiveOne unarchived "Unarchive all as disabled?" \
        "No archived services." "${targets[@]}"
}

# Sets CHILD_DIR to the real path of parent/name when it is a directory that
# resolves inside parent (no symlink escape). Exit 1 otherwise.
SafeChildDir() {
    local parent="$1" name="$2" real_parent target
    CHILD_DIR=""
    [[ -n "$name" && "$name" != *"/"* && "$name" != *".."* && "$name" != "." ]] || return 1
    [[ -d "$parent/$name" ]] || return 1
    real_parent="$(cd -P "$parent" && pwd -P)" || return 1
    target="$(cd -P "$parent/$name" && pwd -P)" || return 1
    [[ "$target" == "$real_parent"/* ]] || return 1
    CHILD_DIR="$target"
}

# Prints the real path of an APPS service folder, with errors on stderr.
ServiceDir() {
    local name="$1"
    if [[ -z "$name" || "$name" == *"/"* || "$name" == *".."* || "$name" == "." ]]; then
        Say baderr "Invalid service name."
        return 1
    fi
    if [[ ! -d "$APPS" ]]; then
        Say baderr "APPS directory does not exist."
        return 1
    fi
    if [[ ! -d "$APPS/$name" ]]; then
        Say baderr "Service does not exist."
        return 1
    fi
    if ! SafeChildDir "$APPS" "$name"; then
        Say baderr "Refusing to use a path outside $APPS."
        return 1
    fi
    printf '%s\n' "$CHILD_DIR"
}

# Prints: /abs/path|apps   or   /abs/path|archive
# Prefers APPS when both somehow exist.
ResolveServiceRoot() {
    local name="$1"
    if [[ -d "${APPS:-}/$name" ]]; then
        SafeChildDir "$APPS" "$name" || return 1
        printf '%s|apps\n' "$CHILD_DIR"
        return 0
    fi
    SafeChildDir "$(ArchiveDir)" "$name" || return 1
    printf '%s|archive\n' "$CHILD_DIR"
}

# Sets SVC_COMPOSE to the enabled compose file in a service folder, else the
# disabled one, and SVC_ENABLED to 1 or 0. Exit 1 when neither exists.
FindComposeFile() {
    local root="${1%/}"
    SVC_COMPOSE=""
    SVC_ENABLED=0
    if [[ -f "$root/$COMPOSE_FILE" ]]; then
        SVC_COMPOSE="$root/$COMPOSE_FILE"
        SVC_ENABLED=1
        return 0
    fi
    if [[ -f "$root/$COMPOSE_FILE_DISABLED" ]]; then
        SVC_COMPOSE="$root/$COMPOSE_FILE_DISABLED"
        return 0
    fi
    return 1
}

ServiceComposeFile() {
    FindComposeFile "$1" || return 1
    printf '%s\n' "$SVC_COMPOSE"
}

# FindComposeFile, or say the service does not exist and exit 1.
RequireComposeFile() {
    FindComposeFile "$1" && return 0
    Say bad "Service does not exist."
    exit 1
}

Remove() {
    local name="${1:-$folder}"
    local target compose_file="" removeAnswer removeAnswerConfirm

    CheckFolderSupplied "$name"
    if ! target="$(ServiceDir "$name")"; then
        exit 1
    fi
    Banner "remove"
    Say warn "Removing service folder: $target"

    FindComposeFile "$target" && compose_file="$SVC_COMPOSE"
    if [[ -n "$compose_file" ]] && CheckStatus "$name"; then
        Say warn "Service is running. Stopping it now."
        RunOneCompose "$compose_file" down
    fi

    removeAnswer="$(Ask "Delete the service folder $target? [y/N]")"
    if [[ "$removeAnswer" == [yY] ]]; then
        removeAnswerConfirm="$(Ask "This cannot be undone. Delete it? [y/N]")"
        if [[ "$removeAnswerConfirm" == [yY] ]]; then
            Say warn "Deleting folder."
            rm -r -- "$target"
            Say ok "Folder deleted."
        else
            Say info "Keeping folder."
        fi
    else
        Say info "Keeping folder."
    fi
}

# Folder name → ENV prefix (paperless-ngx → PAPERLESS_NGX).
ServiceEnvPrefix() {
    local n="$1"
    n="${n^^}"
    n="${n//-/_}"
    printf '%s\n' "$n"
}

declare -A IDX_CREFS=() IDX_EREFS=() IDX_DEFS=() IDX_STATE=()
IDX_NAMES=()
IDX_LOADED=0

# Every key assigned in an env file (no filtering), one awk pass.
EnvFileDefinedKeys() {
    [[ -f "$1" ]] || return 0
    awk '
        {
            sub(/\r$/, "")
            sub(/^[[:space:]]+/, "")
            sub(/^export[[:space:]]+/, "")
            if (match($0, /^[A-Za-z_][A-Za-z0-9_]*=/)) print substr($0, 1, RLENGTH - 1)
        }
    ' "$1"
}

IndexOneService() {
    local dir="${1%/}" loc="$2"
    local name compose_file state f
    local -a crefs=() erefs=() defs=() part=()
    name="${dir##*/}"
    [[ -n "${IDX_STATE[$name]+x}" ]] && return 0
    FindComposeFile "$dir" || return 0
    compose_file="$SVC_COMPOSE"
    state=disabled
    [[ "$SVC_ENABLED" -eq 1 ]] && state=enabled
    [[ "$loc" == "archive" ]] && state=archived
    mapfile -t crefs < <(ComposeVarNames "$compose_file")
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        mapfile -t part < <(EnvFileRefNames "$f")
        erefs+=("${part[@]}")
        mapfile -t part < <(EnvFileDefinedKeys "$f")
        defs+=("${part[@]}")
    done < <(EnvFilesInDir "$dir")
    IDX_NAMES+=("$name")
    IDX_STATE["$name"]="$state"
    IDX_CREFS["$name"]=" ${crefs[*]} "
    IDX_EREFS["$name"]=" ${erefs[*]} "
    IDX_DEFS["$name"]=" ${defs[*]} "
}

# One pass over every service (APPS, then ARCHIVE): compose refs, env-value
# refs, and defined env keys. Look keys up with " $key " matches.
BuildServiceIndex() {
    local dir
    [[ "$IDX_LOADED" -eq 1 ]] && return 0
    IDX_LOADED=1
    while IFS= read -r dir; do
        [[ -n "$dir" ]] && IndexOneService "$dir" apps
    done < <(ServiceDirs)
    while IFS= read -r dir; do
        [[ -n "$dir" ]] && IndexOneService "$dir" archive
    done < <(ArchivedServiceDirs)
}

# Print other service names that reference or define $key (skip $self folder).
VarExternalUsers() {
    local key="$1" self="$2" name
    BuildServiceIndex
    for name in "${IDX_NAMES[@]}"; do
        [[ "$name" == "$self" ]] && continue
        if [[ "${IDX_CREFS[$name]}" == *" $key "* || "${IDX_EREFS[$name]}" == *" $key "* || "${IDX_DEFS[$name]}" == *" $key "* ]]; then
            printf '%s\n' "$name"
        fi
    done
}

# Keys in project + this service env files starting with PREFIX_.
CollectPrefixedEnvKeys() {
    local prefix="$1" compose_file="$2"
    local file line key
    local -A seen=()

    ScanFile() {
        local f="$1"
        [[ -f "$f" ]] || return 0
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line//$'\r'/}"
            [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
            key="${BASH_REMATCH[1]}"
            [[ "$key" == "${prefix}_"* ]] || continue
            [[ -n "${seen[$key]+x}" ]] && continue
            seen["$key"]=1
            printf '%s\n' "$key"
        done < "$f"
    }

    if [[ -n "${envFile:-}" && -f "$envFile" ]]; then
        ScanFile "$envFile"
    fi
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        ScanFile "$file"
    done < <(ServiceEnvFiles "$compose_file")
}

ReplaceEnvKeyInText() {
    local text="$1" oldk="$2" newk="$3"
    local result="" rest match
    rest="$text"
    while [[ -n "$rest" ]]; do
        if [[ "$rest" == \$\$* ]]; then
            result+='$$'
            rest="${rest:2}"
            continue
        fi
        if [[ "$rest" =~ ^\$\{$oldk\} ]]; then
            result+="\${${newk}}"
            rest="${rest:$((${#oldk} + 3))}"
            continue
        fi
        if [[ "$rest" =~ ^\$$oldk([^A-Za-z0-9_]|$) ]]; then
            match="${BASH_REMATCH[0]}"
            result+="\$${newk}${match:$((${#oldk} + 1))}"
            rest="${rest:${#match}}"
            continue
        fi
        result+="${rest:0:1}"
        rest="${rest:1}"
    done
    printf '%s' "$result"
}

RewriteEnvKeyInFile() {
    local file="$1" oldk="$2" newk="$3"
    local tmp line pre key val
    [[ -f "$file" ]] || return 0
    tmp="$(mktemp)" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        if [[ "$line" =~ ^([[:space:]]*)([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            pre="${BASH_REMATCH[1]}"
            key="${BASH_REMATCH[2]}"
            val="${BASH_REMATCH[3]}"
            [[ "$key" == "$oldk" ]] && key="$newk"
            val="$(ReplaceEnvKeyInText "$val" "$oldk" "$newk")"
            printf '%s%s=%s\n' "$pre" "$key" "$val" >>"$tmp"
        else
            printf '%s\n' "$line" >>"$tmp"
        fi
    done < "$file"
    mv "$tmp" "$file"
}

RemoveEnvKeyInFile() {
    local file="$1" want="$2"
    local tmp line key
    [[ -f "$file" ]] || return 0
    tmp="$(mktemp)" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            key="${BASH_REMATCH[1]}"
            [[ "$key" == "$want" ]] && continue
        fi
        printf '%s\n' "$line" >>"$tmp"
    done < "$file"
    mv "$tmp" "$file"
}

RewriteComposeServiceName() {
    local file="$1" old="$2" new="$3"
    local tmp line indent key raw q
    [[ -f "$file" ]] || return 0
    tmp="$(mktemp)" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        line="${line//\$\{APPS\}\/${old}/\$\{APPS\}\/${new}}"
        if [[ "$line" =~ ^([[:space:]]*)(name|container_name|hostname):[[:space:]]*(.*)$ ]]; then
            indent="${BASH_REMATCH[1]}"
            key="${BASH_REMATCH[2]}"
            raw="${BASH_REMATCH[3]}"
            raw="${raw%"${raw##*[![:space:]]}"}"
            q=""
            if [[ "$raw" == \"*\" && "$raw" == *\" ]]; then
                q='"'
                raw="${raw:1:${#raw}-2}"
            elif [[ "$raw" == \'*\' && "$raw" == *\' ]]; then
                q="'"
                raw="${raw:1:${#raw}-2}"
            fi
            if [[ "$raw" == "$old" ]]; then
                printf '%s%s: %s%s%s\n' "$indent" "$key" "$q" "$new" "$q" >>"$tmp"
                continue
            fi
        fi
        printf '%s\n' "$line" >>"$tmp"
    done < "$file"
    mv "$tmp" "$file"
}

RewriteComposeEnvKeys() {
    local file="$1"
    shift
    local tmp line oldk newk pair
    local -a pairs=("$@")
    [[ -f "$file" ]] || return 0
    [[ ${#pairs[@]} -eq 0 ]] && return 0
    tmp="$(mktemp)" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        for pair in "${pairs[@]}"; do
            oldk="${pair%%=*}"
            newk="${pair#*=}"
            line="$(ReplaceEnvKeyInText "$line" "$oldk" "$newk")"
        done
        printf '%s\n' "$line" >>"$tmp"
    done < "$file"
    mv "$tmp" "$file"
}

Rename() {
    local old new resolved loc src dest parent compose_file enabled=0 answer run_state
    local old_prefix new_prefix key new_key line ef
    local -a env_rename=() env_skip=() skipped=() external=()
    local -a rewrite_pairs=()

    Banner "rename"
    old="${folder:-}"
    new="${EXTRA_ARGS[0]:-}"
    new="${new,,}"
    if ! ValidServiceName "$old"; then
        Say bad "Rename needs the current service name."
        Say info "dc rename old-name new-name"
        exit 1
    fi
    if [[ ${#EXTRA_ARGS[@]} -ne 1 ]] || ! ValidServiceName "$new"; then
        Say bad "Rename needs one new service name."
        Say info "dc rename old-name new-name"
        exit 1
    fi
    if [[ "$old" == "$new" ]]; then
        Say info "Names are the same."
        return 0
    fi
    if ! resolved="$(ResolveServiceRoot "$old")"; then
        Say bad "Service does not exist."
        exit 1
    fi
    src="${resolved%%|*}"
    loc="${resolved##*|}"
    if [[ "$loc" == "archive" ]]; then
        parent="$(ArchiveDir)"
    else
        parent="$APPS"
    fi
    dest="$parent/$new"
    if [[ -e "$APPS/$new" || -e "$(ArchiveDir)/$new" ]]; then
        Say bad "Target name already exists."
        exit 1
    fi
    if ! compose_file="$(ServiceComposeFile "$src")"; then
        Say bad "Service does not exist."
        exit 1
    fi
    [[ -f "$src/$COMPOSE_FILE" ]] && enabled=1

    old_prefix="$(ServiceEnvPrefix "$old")"
    new_prefix="$(ServiceEnvPrefix "$new")"
    BuildServiceIndex
    LoadEnvMap "$compose_file"
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        new_key="${new_prefix}_${key#"${old_prefix}_"}"
        if [[ "$new_key" == "$key" ]]; then
            continue
        fi
        external=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && external+=("$line")
        done < <(VarExternalUsers "$key" "$old")
        if [[ ${#external[@]} -gt 0 ]]; then
            env_skip+=("$key")
            Say warn "$key also used in: ${external[*]}"
            continue
        fi
        if [[ -n "${ENV_MAP_LINE[$new_key]:-}" ]]; then
            Say warn "Skip $key → $new_key · target key already set."
            env_skip+=("$key")
            continue
        fi
        env_rename+=("$key|$new_key")
    done < <(CollectPrefixedEnvKeys "$old_prefix" "$compose_file" | LC_ALL=C sort -u)

    while IFS= read -r line; do
        [[ -n "$line" ]] && skipped+=("$line")
    done < <(SkippedMounts "$compose_file" "$src")

    Say info "From: $src ($loc)"
    Say info "To:   $dest"
    if [[ "$enabled" -eq 1 ]]; then
        Say info "State: enabled → will end disabled"
    elif [[ "$loc" == "archive" ]]; then
        Say info "State: archived"
    else
        Say info "State: disabled"
    fi
    Say info "Compose: rewrite name paths"
    if [[ ${#env_rename[@]} -gt 0 ]]; then
        Say info "Env keys that can rename (${#env_rename[@]}):"
        for line in "${env_rename[@]}"; do
            printf "    %s → %s\n" "${line%%|*}" "${line#*|}"
        done
    fi
    if [[ ${#env_skip[@]} -gt 0 ]]; then
        Say warn "Env keys left unchanged if renamed: ${env_skip[*]}"
        Say info "dc where KEY"
    fi
    if [[ ${#skipped[@]} -gt 0 ]]; then
        Say warn "Outside mounts stay as written:"
        printf '    %s\n' "${skipped[@]}"
    fi
    if [[ ${#env_rename[@]} -gt 0 ]]; then
        answer="$(Ask "Also rename env keys ${old_prefix}_ → ${new_prefix}_? [y/N]")"
        if [[ "$answer" != [yY] ]]; then
            env_rename=()
            Say info "Keeping env key names."
        fi
    fi
    answer="$(Ask "Rename $old to $new? [y/N]")"
    if [[ "$answer" != [yY] ]]; then
        Say info "Left $old unchanged."
        return 0
    fi

    if [[ "$enabled" -eq 1 && "$loc" == "apps" ]]; then
        run_state="$(ReturnStatus "$old")"
        run_state="${run_state,,}"
        if [[ "$run_state" == *running* || "$run_state" == *restarting* || "$run_state" == *paused* ]]; then
            Say warn "Stopping $old."
            RunOneCompose "$compose_file" down || {
                Say bad "Could not stop $old."
                exit 1
            }
        fi
        if [[ -f "$src/$COMPOSE_FILE" ]]; then
            mv -- "$src/$COMPOSE_FILE" "$src/$COMPOSE_FILE_DISABLED" || {
                Say bad "Could not disable $old before rename."
                exit 1
            }
            compose_file="$src/$COMPOSE_FILE_DISABLED"
            Say warn "Disabled $old."
        fi
    fi

    if ! mv -- "$src" "$dest"; then
        Say bad "Could not move folder to $new."
        exit 1
    fi
    compose_file="$(ServiceComposeFile "$dest")" || {
        Say bad "Renamed folder but compose file is missing."
        exit 1
    }

    RewriteComposeServiceName "$compose_file" "$old" "$new"
    for line in "${env_rename[@]}"; do
        key="${line%%|*}"
        new_key="${line#*|}"
        rewrite_pairs+=("${key}=${new_key}")
    done
    if [[ ${#rewrite_pairs[@]} -gt 0 ]]; then
        RewriteComposeEnvKeys "$compose_file" "${rewrite_pairs[@]}"
        if [[ -n "${envFile:-}" && -f "$envFile" ]]; then
            for line in "${env_rename[@]}"; do
                key="${line%%|*}"
                new_key="${line#*|}"
                RewriteEnvKeyInFile "$envFile" "$key" "$new_key"
            done
        fi
        while IFS= read -r ef; do
            [[ -n "$ef" ]] || continue
            for line in "${env_rename[@]}"; do
                key="${line%%|*}"
                new_key="${line#*|}"
                RewriteEnvKeyInFile "$ef" "$key" "$new_key"
            done
        done < <(ServiceEnvFiles "$compose_file")
    fi

    Say ok "Renamed $old → $new."
    if [[ "$loc" == "archive" ]]; then
        Say info "Still archived. dc unarchive $new"
    else
        Say info "Disabled. dc enable $new"
        Say info "dc up $new"
    fi
}

ComposeLineStatus() {
    local line="$1"
    local status
    line="${line//$'\r'/}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && return 1
    if [[ "$line" =~ ^\[[^]]+\][[:space:]]+[A-Za-z]+[[:space:]]+[0-9]+/[0-9]+[[:space:]]*$ ]]; then
        return 1
    fi
    if [[ "$line" =~ Resource[[:space:]]+is[[:space:]]+still[[:space:]]+in[[:space:]]+use ]]; then
        printf '%s' "InUse"
        return 0
    fi
    if [[ "$line" =~ [[:space:]][0-9]+([.][0-9]+)?s[[:space:]]*$ ]]; then
        line="${line% *}"
        line="${line%"${line##*[![:space:]]}"}"
    fi
    if [[ ! "$line" =~ (Container|Network|Volume|Image)[[:space:]] ]]; then
        return 2
    fi
    status="${line##* }"
    if [[ ! "$status" =~ ^[A-Za-z]+$ ]]; then
        return 2
    fi
    printf '%s' "$status"
    return 0
}

ComposeStatusAllowed() {
    local verb="$1"
    local status="$2"
    local ok=""
    case "$verb" in
        up|start|unpause) ok=" Running Healthy " ;;
        restart) ok=" Started Running Healthy " ;;
        stop) ok=" Stopped " ;;
        pause) ok=" Paused " ;;
        down) ok=" Removed InUse " ;;
        *) return 1 ;;
    esac
    [[ "$ok" == *" $status "* ]]
}

ComposeOutputSteady() {
    local verb="$1"
    local file="$2"
    local line status code count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        code=0
        status="$(ComposeLineStatus "$line")" || code=$?
        if [[ "$code" -eq 1 ]]; then
            continue
        fi
        if [[ "$code" -ne 0 ]]; then
            return 1
        fi
        ComposeStatusAllowed "$verb" "$status" || return 1
        if [[ "$status" != "InUse" ]]; then
            count=$((count+1))
        fi
    done < <(tr '\r' '\n' < "$file")
    [[ "$count" -gt 0 ]]
}

ComposeSteadyLabel() {
    local verb="$1"
    local file="$2"
    local line status code key n
    local -A tally=()
    local order=(running healthy restarted started stopped paused removed)
    while IFS= read -r line || [[ -n "$line" ]]; do
        code=0
        status="$(ComposeLineStatus "$line")" || code=$?
        [[ "$code" -eq 0 ]] || continue
        [[ "$status" == "InUse" ]] && continue
        if [[ "$verb" == "restart" && "$status" == "Started" ]]; then
            key="restarted"
        else
            key="${status,,}"
        fi
        tally["$key"]=$((${tally[$key]:-0}+1))
    done < <(tr '\r' '\n' < "$file")
    local joined=""
    for key in "${order[@]}"; do
        n="${tally[$key]:-0}"
        [[ "$n" -gt 0 ]] || continue
        if [[ -z "$joined" ]]; then
            joined="$n $key"
        else
            joined="$joined, $n $key"
        fi
    done
    if [[ -z "$joined" ]]; then
        printf '%s' "done"
        return 0
    fi
    printf '%s' "$joined"
}

EnvFilesInDir() {
    local dir="$1"
    local f had_null=0
    local -a candidates=() found=()
    local -A seen=()

    [[ -d "$dir" ]] || return 0
    shopt -q nullglob && had_null=1
    shopt -s nullglob
    candidates=("$dir"/.env "$dir"/.env.* "$dir"/*.env)
    [[ "$had_null" -eq 1 ]] || shopt -u nullglob
    for f in "${candidates[@]}"; do
        [[ -f "$f" ]] || continue
        case "$f" in
            *.bak|*.example|*.sample|*.swp|*~) continue ;;
        esac
        if [[ -n "${envFile:-}" && "$f" -ef "$envFile" ]]; then
            continue
        fi
        [[ -n "${seen[$f]+x}" ]] && continue
        seen["$f"]=1
        found+=("$f")
    done
    if [[ ${#found[@]} -eq 0 ]]; then
        return 0
    fi
    printf '%s\n' "${found[@]}" | LC_ALL=C sort -u
}

ServiceEnvFiles() {
    EnvFilesInDir "$(dirname "$1")"
}

AllEnvFiles() {
    local dir f
    local -A seen=()
    if [[ -n "${envFile:-}" && -f "$envFile" ]]; then
        printf '%s\n' "$envFile"
        seen["$envFile"]=1
    fi
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            [[ -n "${seen[$f]+x}" ]] && continue
            if [[ -n "${envFile:-}" && "$f" -ef "$envFile" ]]; then
                continue
            fi
            seen["$f"]=1
            printf '%s\n' "$f"
        done < <(EnvFilesInDir "$dir")
    done < <(ServiceDirs)
}

AppendEnvFileArgs() {
    local -n _env_args=$1
    local compose_file="$2"
    local f
    _env_args+=(--env-file "$envFile")
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        _env_args+=(--env-file "$f")
    done < <(ServiceEnvFiles "$compose_file")
}

RunOneCompose() {
    local file="$1"
    shift
    local -a args=(--file "$file")
    CheckDockerCompose
    AppendEnvFileArgs args "$file"
    "${DockerCmd[@]}" "${args[@]}" "$@"
}

Cmd() {
    local name resolved root compose_file part first=1
    local -a args=() run=()

    name="${folder:-}"
    if ! ValidServiceName "$name"; then
        Say baderr "cmd needs a service name."
        Say baderr "dc cmd plex"
        exit 1
    fi
    if ! resolved="$(ResolveServiceRoot "$name")"; then
        Say baderr "Service does not exist."
        exit 1
    fi
    root="${resolved%%|*}"
    if ! compose_file="$(ServiceComposeFile "$root")"; then
        Say baderr "Service does not exist."
        exit 1
    fi

    args=(--file "$compose_file")
    AppendEnvFileArgs args "$compose_file"
    if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
        run=("${EXTRA_ARGS[@]}")
    else
        run=(up -d)
    fi

    for part in "${DockerCmd[@]}" "${args[@]}" "${run[@]}"; do
        if [[ "$first" -eq 1 ]]; then
            printf '%q' "$part"
            first=0
        else
            printf ' %q' "$part"
        fi
    done
    printf '\n'
}

RunComposeBrief() {
    local index="$1"
    local total="$2"
    local name="$3"
    local file="$4"
    shift 4
    local verb="${1:-}"
    local outfile pid start now status=0 shown_live=0 spin='|/-\' tick=0
    local label

    BRIEF_KIND=changed
    outfile="$(mktemp)" || {
        RunOneCompose "$file" "$@"
        return
    }
    RunOneCompose "$file" "$@" >"$outfile" 2>&1 &
    pid=$!
    start=$SECONDS
    while kill -0 "$pid" 2>/dev/null; do
        now=$SECONDS
        if [[ $((now - start)) -ge 3 ]]; then
            printf "\r\033[K%b── %s ──%b\n" "$c_yellow" "$name" "$c_reset"
            if tail --pid="$pid" -n +1 -f "$outfile" 2>/dev/null; then
                shown_live=1
            fi
            break
        fi
        if [[ -t 1 ]]; then
            tick=$(( (tick + 1) % 4 ))
            printf "\r  %b%s%b  %3d/%-3d  %s" "$c_teal" "${spin:tick:1}" "$c_reset" "$index" "$total" "$name"
        fi
        sleep 0.05
    done
    if [[ "$shown_live" -eq 0 && -t 1 ]]; then
        printf "\r\033[K"
    fi
    wait "$pid" || status=$?
    if [[ "$status" -ne 0 ]]; then
        BRIEF_KIND=failed
        printf "  %b✘%b  %3d/%-3d  %s\n" "$c_red" "$c_reset" "$index" "$total" "$name"
        [[ "$shown_live" -eq 1 ]] || cat "$outfile"
        rm -f "$outfile"
        return "$status"
    fi
    if [[ "$shown_live" -eq 0 ]] && ComposeOutputSteady "$verb" "$outfile"; then
        BRIEF_KIND=steady
        label="$(ComposeSteadyLabel "$verb" "$outfile")"
        printf "  %b✔%b  %b%3d/%-3d%b  %-${ROW_NAME_WIDTH:-16}s  %b│%b  %b%s%b\n" \
            "$c_green" "$c_reset" "$c_dim" "$index" "$total" "$c_reset" "$name" \
            "$c_dim" "$c_reset" "$c_dim" "$label" "$c_reset"
        rm -f "$outfile"
        return 0
    fi
    BRIEF_KIND=changed
    if [[ "$shown_live" -eq 0 ]]; then
        printf "  %b↑%b  %3d/%-3d  %s\n" "$c_yellow" "$c_reset" "$index" "$total" "$name"
        cat "$outfile"
    fi
    rm -f "$outfile"
    return 0
}

RunServices() {
    local service="$1"
    shift
    local verb="${1:-}"
    local pretty=0
    local dir path failed=0 ran=0 answer
    local -a names=()
    local index=0 unchanged=0 changed=0 failed_color name_width=16
    case "$verb" in
        up|start|stop|restart|pause|unpause|down) pretty=1 ;;
    esac

    if [[ -z "$service" || "$service" == "all" ]]; then
        if [[ -z "$service" ]]; then
            case "$verb" in
                down|stop|restart)
                    answer="$(Ask "No service was provided. $verb every service? [y/N]")"
                    if [[ "$answer" != [yY] ]]; then
                        Say info "Exiting."
                        return
                    fi
                    ;;
                *)
                    answer="$(Ask "No service was provided. Loop through all services? [Y/n]")"
                    if [[ -n "$answer" && "$answer" != [yY] ]]; then
                        Say info "Exiting."
                        return
                    fi
                    ;;
            esac
        fi
        while IFS= read -r dir; do
            [[ -f "${dir}${COMPOSE_FILE}" ]] || continue
            names+=("$(basename "$dir")")
        done < <(ServiceDirs)
        if [[ ${#names[@]} -eq 0 ]]; then
            Say warn "No enabled services found."
            return
        fi
        name_width="$(ColumnWidth 16 "${names[@]}")"
        ROW_NAME_WIDTH="$name_width"
        for path in "${names[@]}"; do
            index=$((index+1))
            ran=1
            if [[ "$pretty" -eq 1 ]]; then
                if RunComposeBrief "$index" "${#names[@]}" "$path" "$APPS/$path/$COMPOSE_FILE" "$@"; then
                    if [[ "$BRIEF_KIND" == "steady" ]]; then
                        unchanged=$((unchanged+1))
                    else
                        changed=$((changed+1))
                    fi
                else
                    failed=$((failed+1))
                fi
            else
                printf "%b── %s ──%b\n" "$c_blue" "$path" "$c_reset"
                if ! RunOneCompose "$APPS/$path/$COMPOSE_FILE" "$@"; then
                    failed=$((failed+1))
                fi
            fi
        done
        if [[ "$pretty" -eq 1 && "$ran" -eq 1 ]]; then
            failed_color="$c_dim"
            [[ "$failed" -gt 0 ]] && failed_color="$c_red"
            printf "%b──%b %d unchanged %b·%b %d changed %b·%b %b%d failed%b\n" \
                "$c_teal" "$c_reset" "$unchanged" "$c_dim" "$c_reset" "$changed" \
                "$c_dim" "$c_reset" "$failed_color" "$failed" "$c_reset"
        fi
        [[ "$failed" -eq 0 ]] || exit 1
        return
    fi

    if [[ "$service" == *"/"* || "$service" == *".."* || "$service" == "." ]]; then
        Say bad "Invalid service name."
        exit 1
    fi
    if [[ -f "$APPS/$service/$COMPOSE_FILE" ]]; then
        printf "%b── %s ──%b\n" "$c_blue" "$service" "$c_reset"
        RunOneCompose "$APPS/$service/$COMPOSE_FILE" "$@" || exit 1
        return
    fi
    if [[ -f "$APPS/$service/$COMPOSE_FILE_DISABLED" ]]; then
        Say warn "Service is disabled."
        case "$verb" in
            up|start|restart|build)
                answer="$(Ask "Enable $service and $verb? [y/N]")"
                if [[ "$answer" != [yY] ]]; then
                    Say info "Left $service disabled."
                    exit 1
                fi
                mv -- "$APPS/$service/$COMPOSE_FILE_DISABLED" "$APPS/$service/$COMPOSE_FILE" || {
                    Say bad "Could not enable $service."
                    exit 1
                }
                Say ok "Enabled $service."
                printf "%b── %s ──%b\n" "$c_blue" "$service" "$c_reset"
                RunOneCompose "$APPS/$service/$COMPOSE_FILE" "$@" || exit 1
                return
                ;;
            *)
                Say info "dc enable $service"
                exit 1
                ;;
        esac
    fi
    Say bad "Service does not exist."
    exit 1
}

JoinRecords() {
    local sep="$1"
    local line="" extra="" count=0
    while true; do
        line=""
        IFS= read -r line || [[ -n "$line" ]] || break
        count=0
        extra="$line"
        while [[ "$extra" == *"$sep"* ]]; do
            extra="${extra#*"$sep"}"
            count=$((count + 1))
        done
        while [[ "$count" -lt 3 ]]; do
            extra=""
            IFS= read -r extra || [[ -n "$extra" ]] || break
            line+=" $extra"
            while [[ "$extra" == *"$sep"* ]]; do
                extra="${extra#*"$sep"}"
                count=$((count + 1))
            done
        done
        printf '%s\n' "$line"
    done
}

LoadContainers() {
    local cname cstatus cports project service
    local -a raw=() ordered=()
    local sep=$'\x1e' line
    local fmt="{{.Names}}${sep}{{.Status}}${sep}{{.Ports}}${sep}{{.Label \"com.docker.compose.project\"}}"
    local want=""

    CTR_SVC=()
    CTR_NAME=()
    CTR_STATUS=()
    CTR_PORTS=()
    if [[ -n "${folder:-}" && "$folder" != "all" ]]; then
        want="${folder,,}"
    fi
    if ! docker ps -a --format "$fmt" >/dev/null 2>&1; then
        Say bad "docker ps failed."
        return 1
    fi
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        raw+=("$line")
    done < <(docker ps -a --format "$fmt" | JoinRecords "$sep")

    for line in "${raw[@]}"; do
        IFS=$sep read -r cname cstatus cports project <<< "$line"
        [[ -z "$cname" ]] && continue
        service="${project:-"-"}"
        if [[ -n "$want" && "${service,,}" != "$want" ]]; then
            continue
        fi
        ordered+=("${service}${sep}${cname}${sep}${cstatus}${sep}$(ShortenPorts "$cports")")
    done
    if [[ ${#ordered[@]} -eq 0 ]]; then
        return 0
    fi
    while IFS=$sep read -r service cname cstatus cports; do
        [[ -z "$cname" ]] && continue
        CTR_SVC+=("$service")
        CTR_NAME+=("$cname")
        CTR_STATUS+=("$cstatus")
        CTR_PORTS+=("$cports")
    done < <(printf '%s\n' "${ordered[@]}" | sort -t "$sep" -k1,1 -k2,2)
}

OneLine() {
    local s="$1"
    s="${s//$'\r'/ }"
    s="${s//$'\n'/ }"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    while [[ "$s" == *"  "* ]]; do
        s="${s//  / }"
    done
    if (( ${#s} > 160 )); then
        s="${s:0:157}..."
    fi
    printf '%s' "$s"
}

CleanError() {
    local s="$1"
    [[ -z "$s" || "$s" == '""' || "$s" == "null" ]] && return 0
    s="${s#\"}"
    s="${s%\"}"
    s="${s//\\n/ }"
    s="${s//\\r/ }"
    s="${s//\\\"/}"
    s="${s//\\\\/\\}"
    OneLine "$s"
}

ClassifyStatus() {
    local low
    low="${1,,}"
    case "$low" in
        *restarting*) printf '%s' restarting ;;
        *dead*) printf '%s' dead ;;
        *unhealthy*) printf '%s' unhealthy ;;
        created*) printf '%s' created ;;
        exited\ \(0\)*|exited\ \(143\)*) ;;
        exited\ *) printf '%s' exited ;;
    esac
}

KeepIssue() {
    local kind="$1" oom="$2" restarts="$3" code="$4"
    [[ -n "$kind" ]] || return 1
    if [[ "$kind" == "exited" && "$code" == "137" && "$oom" != "true" ]]; then
        if [[ ! "$restarts" =~ ^[0-9]+$ || "$restarts" -eq 0 ]]; then
            return 1
        fi
    fi
    return 0
}

IssueHint() {
    local kind="$1" oom="$2" restarts="$3" code="$4" error="$5" policy="$6"
    local hint=""
    case "$kind" in
        unhealthy)
            hint="Health check is failing."
            ;;
        restarting)
            if [[ "$oom" == "true" ]]; then
                hint="Restarting because it ran out of memory."
            elif [[ "$restarts" =~ ^[0-9]+$ && "$restarts" -gt 1 && "$code" =~ ^[0-9]+$ ]]; then
                hint="Restarting after exit ${code}. Docker has restarted it ${restarts} times."
            elif [[ "$restarts" =~ ^[0-9]+$ && "$restarts" -gt 1 ]]; then
                hint="Restarting. Docker has restarted it ${restarts} times."
            elif [[ "$code" =~ ^[0-9]+$ ]]; then
                hint="Restarting after exit ${code}."
            else
                hint="Restarting."
            fi
            ;;
        exited)
            if [[ "$oom" == "true" ]]; then
                hint="It ran out of memory."
            elif [[ "$policy" == "on-failure" && "$restarts" =~ ^[0-9]+$ && "$restarts" -gt 0 ]]; then
                hint="Docker stopped trying after ${restarts} restarts."
            elif [[ "$code" == "137" && "$restarts" =~ ^[0-9]+$ && "$restarts" -gt 0 ]]; then
                hint="It was killed (exit 137) after ${restarts} restarts."
            elif [[ "$code" == "137" ]]; then
                hint="It was killed (exit 137)."
            elif [[ "$code" =~ ^[0-9]+$ && "$restarts" =~ ^[0-9]+$ && "$restarts" -gt 1 ]]; then
                hint="It exited with code ${code} after ${restarts} restarts."
            elif [[ "$code" =~ ^[0-9]+$ ]]; then
                hint="It exited with code ${code}."
            else
                hint="It exited with a failure code."
            fi
            ;;
        dead)
            hint="Docker marked this container dead."
            ;;
        created)
            hint="Created and never started."
            ;;
    esac
    if [[ -n "$error" ]]; then
        hint="${hint} ${error}"
    fi
    printf '%s' "$hint"
}

IssueCommands() {
    local kind="$1" service="$2" cname="$3"
    local who logs_cmd start_cmd
    if [[ -z "$service" || "$service" == "-" ]]; then
        who="$(printf '%q' "$cname")"
        logs_cmd="docker logs ${who} --tail 80"
        start_cmd="docker start ${who}"
        case "$kind" in
            unhealthy|restarting) printf '%s\n' "$logs_cmd" ;;
            exited) printf '%s\n' "$logs_cmd" "$start_cmd" ;;
            dead) printf '%s\n' "docker rm -f ${who}" ;;
            created) printf '%s\n' "$start_cmd" ;;
        esac
        return 0
    fi
    who="$(printf '%q' "$service")"
    logs_cmd="dc logs ${who} -- --tail 80"
    start_cmd="dc start ${who}"
    case "$kind" in
        unhealthy|restarting) printf '%s\n' "$logs_cmd" ;;
        exited) printf '%s\n' "$logs_cmd" "$start_cmd" ;;
        dead) printf '%s\n' "dc up ${who}" ;;
        created) printf '%s\n' "$start_cmd" ;;
    esac
}

ReadInspect() {
    local name="$1"
    local sep=$'\x1e'
    local fmt="{{.State.OOMKilled}}${sep}{{.RestartCount}}${sep}{{.State.ExitCode}}${sep}{{json .State.Error}}${sep}{{.HostConfig.RestartPolicy.Name}}"
    docker inspect --format "$fmt" "$name" 2>/dev/null || true
}

LastHealthLine() {
    local name="$1"
    local sep=$'\x1e' blob="" part="" last=""
    local fmt="{{if .State.Health}}{{range .State.Health.Log}}{{.Output}}${sep}{{end}}{{end}}"
    blob="$(docker inspect --format "$fmt" "$name" 2>/dev/null || true)"
    [[ -n "$blob" ]] || return 0
    while [[ "$blob" == *"$sep"* ]]; do
        part="${blob%%"$sep"*}"
        blob="${blob#*"$sep"}"
        [[ -n "${part//[[:space:]]/}" ]] && last="$part"
    done
    [[ -n "${blob//[[:space:]]/}" ]] && last="$blob"
    [[ -n "$last" ]] || return 0
    OneLine "$last"
}

PrintLogTail() {
    local name="$1"
    local -a kept=()
    local line i start
    while IFS= read -r line; do
        line="${line//$'\r'/}"
        line="$(printf '%s' "$line" | sed -E $'s/\x1B\\[[0-9;]*[[:alpha:]]//g')"
        [[ -z "${line//[[:space:]]/}" ]] && continue
        if (( ${#line} > 140 )); then
            line="${line:0:137}..."
        fi
        kept+=("$line")
    done < <(docker logs --tail 30 "$name" 2>&1 || true)
    [[ ${#kept[@]} -eq 0 ]] && return 0
    start=0
    if (( ${#kept[@]} > 6 )); then
        start=$(( ${#kept[@]} - 6 ))
    fi
    for (( i=start; i<${#kept[@]}; i++ )); do
        printf "       %b%s%b\n" "$c_dim" "${kept[$i]}" "$c_reset"
    done
}

ShortenPorts() {
    local raw="$1"
    local part left right short seen=" " out=""
    local -a parts=()
    [[ -z "$raw" ]] && return 0
    IFS=',' read -r -a parts <<< "$raw"
    for part in "${parts[@]}"; do
        part="${part#"${part%%[![:space:]]*}"}"
        part="${part%"${part##*[![:space:]]}"}"
        [[ -z "$part" || "$part" == \[* ]] && continue
        part="${part%/*}"
        if [[ "$part" == *'->'* ]]; then
            left="${part%%->*}"
            right="${part#*->}"
            left="${left##*:}"
            if [[ "$left" == "$right" ]]; then
                short="$left"
            else
                short="${left}→${right}"
            fi
        else
            short="${part##*:}"
        fi
        [[ -z "$short" || "$seen" == *" $short "* ]] && continue
        seen+="$short "
        if [[ -n "$out" ]]; then
            out+="  $short"
        else
            out="$short"
        fi
    done
    printf '%s' "$out"
}

Ps() {
    local low i ports_text mark color
    local svc_w name_w status_w
    local want="" have_dir=0

    Banner "ps"
    if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
        RunServices "$folder" ps "${EXTRA_ARGS[@]}"
        return
    fi
    if [[ -n "$folder" && "$folder" != "all" ]]; then
        want="${folder,,}"
        [[ -d "$APPS/$folder" ]] && have_dir=1
    fi
    LoadContainers || return 1
    if [[ ${#CTR_NAME[@]} -eq 0 ]]; then
        if [[ -n "$want" && "$have_dir" -eq 0 ]]; then
            Say bad "Service does not exist."
            exit 1
        fi
        Say info "No containers."
        return 0
    fi
    svc_w="$(ColumnWidth 7 "${CTR_SVC[@]}")"
    name_w="$(ColumnWidth 4 "${CTR_NAME[@]}")"
    status_w="$(ColumnWidth 6 "${CTR_STATUS[@]}")"
    printf "%b       %-*s  │  %-*s  │  %-*s  │  %s%b\n" "$c_dim" \
        "$svc_w" "service" "$name_w" "name" \
        "$status_w" "status" "ports" "$c_reset"
    for i in "${!CTR_NAME[@]}"; do
        low="${CTR_STATUS[$i],,}"
        case "$low" in
            *restarting*|*unhealthy*) mark="·"; color="$c_yellow" ;;
            up\ *|*healthy*) mark="✔"; color="$c_green" ;;
            *exited*|*dead*) mark="✘"; color="$c_red" ;;
            *) mark="·"; color="$c_yellow" ;;
        esac
        ports_text="${CTR_PORTS[$i]}"
        [[ -z "$ports_text" ]] && ports_text="-"
        StatusColor "${CTR_STATUS[$i]}"
        printf "  %b%s%b  %-*s  %b│%b  %-*s  %b│%b  %b%-*s%b  %b│%b  %s\n" \
            "$color" "$mark" "$c_reset" \
            "$svc_w" "${CTR_SVC[$i]}" \
            "$c_dim" "$c_reset" \
            "$name_w" "${CTR_NAME[$i]}" \
            "$c_dim" "$c_reset" \
            "$STATUS_COLOR" "$status_w" "${CTR_STATUS[$i]}" "$c_reset" \
            "$c_dim" "$c_reset" \
            "$ports_text"
    done
    printf "\n"
    Say info "${#CTR_NAME[@]} container(s)."
}

Issue() {
    local want="" have_dir=0
    local i kind hint health cmd title mark color low
    local oom restarts code error policy blob
    local sep=$'\x1e'
    local problems=0

    Banner "issue"
    if [[ -n "$folder" && "$folder" != "all" ]]; then
        want="${folder,,}"
        [[ -d "$APPS/$folder" ]] && have_dir=1
    fi
    LoadContainers || return 1
    if [[ ${#CTR_NAME[@]} -eq 0 && -n "$want" && "$have_dir" -eq 0 ]]; then
        Say bad "Service does not exist."
        exit 1
    fi

    for i in "${!CTR_NAME[@]}"; do
        kind="$(ClassifyStatus "${CTR_STATUS[$i]}")"
        [[ -n "$kind" ]] || continue
        low="${CTR_STATUS[$i],,}"
        oom="" restarts="" code="" error="" policy=""
        blob="$(ReadInspect "${CTR_NAME[$i]}")"
        if [[ -n "$blob" ]]; then
            IFS=$sep read -r oom restarts code error policy <<< "$blob"
            error="$(CleanError "$error")"
        fi
        if [[ "$kind" == "restarting" || "$kind" == "exited" ]]; then
            if [[ ! "$code" =~ ^[0-9]+$ && "$low" =~ \(([0-9]+)\) ]]; then
                code="${BASH_REMATCH[1]}"
            fi
        fi
        KeepIssue "$kind" "$oom" "$restarts" "$code" || continue

        if [[ "$problems" -gt 0 ]]; then
            printf "\n"
        fi
        problems=$((problems + 1))
        case "$kind" in
            exited|dead) mark="✘"; color="$c_red" ;;
            *) mark="!"; color="$c_yellow" ;;
        esac
        hint="$(IssueHint "$kind" "$oom" "$restarts" "$code" "$error" "$policy")"
        if [[ "$kind" == "unhealthy" ]]; then
            health="$(LastHealthLine "${CTR_NAME[$i]}")"
            if [[ -n "$health" ]]; then
                hint="Health check is failing: $health"
                [[ -n "$error" ]] && hint+=" $error"
            fi
        fi
        if [[ "${CTR_SVC[$i]}" == "-" ]]; then
            title="${CTR_NAME[$i]}"
        else
            title="${CTR_SVC[$i]}"
        fi
        printf "  %b%s%b  %s\n" "$color" "$mark" "$c_reset" "$title"
        StatusColor "${CTR_STATUS[$i]}"
        if [[ "$title" != "${CTR_NAME[$i]}" ]]; then
            printf "     %b%s%b  %b·%b  %b%s%b\n" "$c_dim" "${CTR_NAME[$i]}" "$c_reset" \
                "$c_dim" "$c_reset" "$STATUS_COLOR" "${CTR_STATUS[$i]}" "$c_reset"
        else
            printf "     %b%s%b\n" "$STATUS_COLOR" "${CTR_STATUS[$i]}" "$c_reset"
        fi
        printf "     %s\n" "$hint"
        while IFS= read -r cmd; do
            [[ -z "$cmd" ]] && continue
            printf "     %b%s%b\n" "$c_teal" "$cmd" "$c_reset"
        done < <(IssueCommands "$kind" "${CTR_SVC[$i]}" "${CTR_NAME[$i]}")
        if [[ "$kind" != "created" ]]; then
            PrintLogTail "${CTR_NAME[$i]}"
        fi
    done

    if [[ "$problems" -eq 0 ]]; then
        Say ok "No issues."
        return 0
    fi
    printf "\n"
    Say warn "${problems} container(s) need attention."
}

Stats() {
    local sep=$'\x1e' line name cpu mem memp net used
    local -A cpu_of=() mem_of=() memp_of=() net_of=()
    local -a row_svc=() row_name=() row_cpu=() row_mem=() row_net=()
    local i svc_w name_w cpu_w mem_w
    local want="" have_dir=0
    local fmt="{{.Name}}${sep}{{.CPUPerc}}${sep}{{.MemUsage}}${sep}{{.MemPerc}}${sep}{{.NetIO}}"
    local stats_file

    local -a running=()
    local low

    Banner "stats"
    if [[ -n "$folder" && "$folder" != "all" ]]; then
        want="${folder,,}"
        [[ -d "$APPS/$folder" ]] && have_dir=1
    fi
    LoadContainers || return 1
    if [[ ${#CTR_NAME[@]} -eq 0 ]]; then
        if [[ -n "$want" && "$have_dir" -eq 0 ]]; then
            Say bad "Service does not exist."
            exit 1
        fi
        Say info "No containers."
        return 0
    fi
    for i in "${!CTR_NAME[@]}"; do
        low="${CTR_STATUS[$i],,}"
        [[ "$low" == up\ * ]] || continue
        running+=("${CTR_NAME[$i]}")
    done
    if [[ ${#running[@]} -eq 0 ]]; then
        Say info "No running containers."
        return 0
    fi

    Say info "Sampling running containers."
    stats_file="$(mktemp)" || {
        Say bad "docker stats failed."
        return 1
    }
    if ! docker stats --no-stream --format "$fmt" "${running[@]}" >"$stats_file" 2>"$stats_file.err"; then
        Say bad "docker stats failed."
        cat "$stats_file.err" >&2
        rm -f "$stats_file" "$stats_file.err"
        return 1
    fi
    rm -f "$stats_file.err"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS=$sep read -r name cpu mem memp net <<< "$line"
        name="${name#/}"
        [[ -z "$name" ]] && continue
        cpu_of["$name"]="$cpu"
        mem_of["$name"]="$mem"
        memp_of["$name"]="$memp"
        net_of["$name"]="$net"
    done < "$stats_file"
    rm -f "$stats_file"

    for i in "${!CTR_NAME[@]}"; do
        name="${CTR_NAME[$i]}"
        [[ -n "${cpu_of[$name]:-}" ]] || continue
        used="${mem_of[$name]%% / *}"
        row_svc+=("${CTR_SVC[$i]}")
        row_name+=("$name")
        row_cpu+=("${cpu_of[$name]}")
        row_mem+=("$used  ${memp_of[$name]}")
        row_net+=("${net_of[$name]}")
    done
    if [[ ${#row_name[@]} -eq 0 ]]; then
        Say info "No running containers."
        return 0
    fi
    svc_w="$(ColumnWidth 7 "${row_svc[@]}")"
    name_w="$(ColumnWidth 4 "${row_name[@]}")"
    cpu_w="$(ColumnWidth 3 "${row_cpu[@]}")"
    mem_w="$(ColumnWidth 3 "${row_mem[@]}")"
    printf "%b       %-*s  │  %-*s  │  %-*s  │  %-*s  │  %s%b\n" "$c_dim" \
        "$svc_w" "service" "$name_w" "name" \
        "$cpu_w" "cpu" "$mem_w" "memory" "network" "$c_reset"
    for i in "${!row_name[@]}"; do
        printf "  %b·%b  %-*s  %b│%b  %-*s  %b│%b  %-*s  %b│%b  %-*s  %b│%b  %s\n" \
            "$c_teal" "$c_reset" \
            "$svc_w" "${row_svc[$i]}" \
            "$c_dim" "$c_reset" \
            "$name_w" "${row_name[$i]}" \
            "$c_dim" "$c_reset" \
            "$cpu_w" "${row_cpu[$i]}" \
            "$c_dim" "$c_reset" \
            "$mem_w" "${row_mem[$i]}" \
            "$c_dim" "$c_reset" \
            "${row_net[$i]}"
    done
    printf "\n"
    Say info "${#row_name[@]} running container(s)."
}

Disk() {
    Banner "df"
    if ! docker system df; then
        Say bad "docker system df failed."
        return 1
    fi
}

# Clean [--yes]: options also come from EXTRA_ARGS.
Clean() {
    local arg yes=0 answer tried=0 did=0 prune_help
    local -a volume_cmd=(docker volume prune -f)
    for arg in "$@" "${EXTRA_ARGS[@]}"; do
        case "$arg" in
            --yes) yes=1 ;;
            *)
                Say bad "Clean takes an optional --yes."
                Say info "dc clean"
                Say info "dc clean --yes"
                exit 1
                ;;
        esac
    done
    Banner "clean"
    Say info "This cleans the whole Docker host."
    if ! docker system df; then
        Say bad "docker system df failed."
        return 1
    fi
    printf "\n"
    if [[ "$yes" -eq 0 ]] && NonInteractive; then
        Say info "Non-interactive: nothing removed without --yes."
        return 0
    fi
    # Docker 23+ prunes only anonymous volumes unless --all is passed.
    prune_help="$(docker volume prune --help 2>/dev/null)"
    [[ "$prune_help" == *--all* ]] && volume_cmd=(docker volume prune --all -f)

    if [[ "$yes" -eq 1 ]]; then
        answer=y
    else
        answer="$(Ask "Remove unused images, build cache, stopped containers, and networks? [y/N]")"
    fi
    if [[ "$answer" == [yY] ]]; then
        tried=1
        if docker system prune -a -f; then
            did=1
        else
            Say bad "System prune failed."
        fi
    fi
    if [[ "$yes" -eq 1 ]]; then
        answer=y
        Say warn "Removing every volume not attached to a container, named ones too."
    else
        answer="$(Ask "Remove every volume not attached to a container, named ones too? Their data is deleted. [y/N]")"
    fi
    if [[ "$answer" == [yY] ]]; then
        tried=1
        if "${volume_cmd[@]}"; then
            did=1
        else
            Say bad "Volume prune failed."
        fi
    fi
    if [[ "$tried" -eq 0 ]]; then
        Say info "Nothing removed."
        return 0
    fi
    if [[ "$did" -eq 1 ]]; then
        printf "\n"
        docker system df || true
    fi
}

Cp() {
    local file
    Banner "cp"
    if [[ -z "$folder" || "$folder" == "all" ]]; then
        Say bad "Copy needs a service name."
        Say info "dc cp plex -- ./file plex:/tmp/file"
        exit 1
    fi
    if [[ ${#EXTRA_ARGS[@]} -lt 2 ]]; then
        Say bad "Copy needs a source and a destination."
        Say info "dc cp $folder -- ./file $folder:/tmp/file"
        exit 1
    fi
    RequireComposeFile "$APPS/$folder"
    [[ "$SVC_ENABLED" -eq 1 ]] || Say warn "Service is disabled."
    RunOneCompose "$SVC_COMPOSE" cp "${EXTRA_ARGS[@]}"
}

ValidServiceName() {
    local name="$1"
    [[ -n "$name" && "$name" != "all" && "$name" != "." && "$name" != ".." ]] || return 1
    [[ "$name" != *"/"* && "$name" != *".."* && "$name" != *$'\n'* ]] || return 1
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]
}

# Unique ${VAR} / $VAR names in compose text on stdin, one awk pass.
# Skips $$ (an escaped $) and full-line # comments.
ComposeVarNamesStdin() {
    awk '
        /^[[:space:]]*#/ { next }
        {
            s = $0
            gsub(/[$][$]/, "", s)
            while (match(s, /[$][{]?[A-Za-z_][A-Za-z0-9_]*/)) {
                n = substr(s, RSTART, RLENGTH)
                s = substr(s, RSTART + RLENGTH)
                sub(/^[$][{]?/, "", n)
                if (!(n in seen)) { seen[n] = 1; print n }
            }
        }
    '
}

# Unique ${VAR} / $VAR names in a compose file.
ComposeVarNames() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    ComposeVarNamesStdin < "$file"
}

declare -A ENV_MAP_SRC=() ENV_MAP_LINE=()

LoadEnvMapFile() {
    local file="$1" src="$2" line k
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
        k="${BASH_REMATCH[1]}"
        ENV_MAP_SRC["$k"]="$src"
        ENV_MAP_LINE["$k"]="${line#"${line%%[![:space:]]*}"}"
    done < "$file"
}

# One pass over the env chain for a compose file, last assignment wins.
# ENV_MAP_SRC[key] is "shared" (project .env) or "service"; ENV_MAP_LINE[key] is the raw line.
LoadEnvMap() {
    local compose_file="$1" f
    ENV_MAP_SRC=()
    ENV_MAP_LINE=()
    if [[ -n "${envFile:-}" && -f "$envFile" ]]; then
        LoadEnvMapFile "$envFile" shared
    fi
    while IFS= read -r f; do
        [[ -n "$f" ]] && LoadEnvMapFile "$f" service
    done < <(ServiceEnvFiles "$compose_file")
}

# Split a raw env value the way Compose reads it (no subshell). Sets ENV_RAW_QUOTE
# to ' or " or empty, and ENV_RAW_TEXT to the value without its quotes. Text after
# the closing quote, or after whitespace + # on an unquoted value, is a comment.
EnvRawValue() {
    local raw="$1" rest i
    raw="${raw#"${raw%%[![:space:]]*}"}"
    ENV_RAW_QUOTE=""
    case "$raw" in
        \'*\'*)
            rest="${raw:1}"
            ENV_RAW_QUOTE="'"
            ENV_RAW_TEXT="${rest%%\'*}"
            return 0
            ;;
        \"*\"*)
            rest="${raw:1}"
            for ((i = 0; i < ${#rest}; i++)); do
                [[ "${rest:i:1}" == '"' ]] && break
                [[ "${rest:i:1}" == '\' ]] && i=$((i + 1))
            done
            ENV_RAW_QUOTE='"'
            ENV_RAW_TEXT="${rest:0:i}"
            ENV_RAW_TEXT="${ENV_RAW_TEXT//\\\"/\"}"
            return 0
            ;;
    esac
    if [[ "$raw" =~ [[:space:]]# ]]; then
        raw="${raw%%"${BASH_REMATCH[0]}"*}"
    fi
    ENV_RAW_TEXT="${raw%"${raw##*[![:space:]]}"}"
}

# EnvGet <name>: sets ENV_GOT from loaded env files, else the exported shell
# environment. Exit 1 when neither has it.
EnvGet() {
    if [[ -n "${ENV_VAL[$1]+x}" ]]; then
        ENV_GOT="${ENV_VAL[$1]}"
        return 0
    fi
    if [[ -n "${SHELL_ENV[$1]+x}" ]]; then
        ENV_GOT="${SHELL_ENV[$1]}"
        return 0
    fi
    ENV_GOT=""
    return 1
}

# Parse one env file into ENV_VAL without executing it (last assignment wins).
# Unquoted and double-quoted values expand like Compose; single-quoted stay literal.
# With "settings", script setting keys (APPS, COMPOSE_FILE, ...) also become shell
# variables. Other keys stay in ENV_VAL so they cannot overwrite script state.
LoadEnvValues() {
    local file="$1" settings="${2:-}" line key
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        line="${line#export }"
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        EnvRawValue "${BASH_REMATCH[2]}"
        if [[ "$ENV_RAW_QUOTE" == "'" ]]; then
            ENV_VAL["$key"]="$ENV_RAW_TEXT"
        else
            ExpandComposeInto "$ENV_RAW_TEXT"
            ENV_VAL["$key"]="$EXPANDED"
        fi
        if [[ -n "$settings" ]] && IsScriptSettingKey "$key"; then
            printf -v "$key" '%s' "${ENV_VAL[$key]}"
        fi
    done < "$file"
}

# Load project then service env files into ENV_VAL (last wins).
LoadEnvValuesForService() {
    local compose_file="$1"
    local file

    if [[ -n "${envFile:-}" && -f "$envFile" ]]; then
        LoadEnvValues "$envFile"
    fi
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        LoadEnvValues "$file"
    done < <(ServiceEnvFiles "$compose_file")
}

EnvsFill() {
    local file="$1"
    local target="$APPS/$folder/.env"
    local name answer created=0
    local -a missing=()

    LoadEnvMap "$file"
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        [[ -z "${ENV_MAP_SRC[$name]:-}" ]] && missing+=("$name")
    done < <(ComposeVarNames "$file" | LC_ALL=C sort -u)

    if [[ ${#missing[@]} -eq 0 ]]; then
        Say ok "All compose vars are set for $folder."
        return 0
    fi

    Say info "$folder · ${#missing[@]} unset"
    for name in "${missing[@]}"; do
        printf "  %b%s%b=\n" "$c_teal" "$name" "$c_reset"
    done
    printf "\n"
    answer="$(Ask "Add these to $folder/.env with empty values? [y/N]")"
    if [[ "$answer" != [yY] ]]; then
        Say info "Left $folder/.env unchanged."
        return 0
    fi
    if [[ ! -f "$target" ]]; then
        printf '# %s service env\n' "$folder" >"$target" || {
            Say bad "Could not create $target."
            exit 1
        }
        created=1
        Say ok "Created $target"
    fi
    {
        printf '\n# filled by dc envs fill\n'
        for name in "${missing[@]}"; do
            printf '%s=\n' "$name"
        done
    } >>"$target" || {
        Say bad "Could not write $target."
        exit 1
    }
    Say ok "Added ${#missing[@]} key(s) to $target."
    answer="$(Ask "Edit $folder/.env now? [Y/n]")"
    if [[ -z "$answer" || "$answer" == [yY] ]]; then
        OpenEditor "$target"
    elif [[ "$created" -eq 1 ]]; then
        Say info "dc env $folder"
    fi
}

Envs() {
    local file show_values=0 do_fill=0 arg name width from_w=7 source value src_color val_color rank
    local -a names=() rows=()
    local missing=0

    Banner "envs"
    for arg in "${EXTRA_ARGS[@]}"; do
        case "$arg" in
            values|--values|-v) show_values=1 ;;
            fill|--fill) do_fill=1 ;;
            *)
                Say bad "Unknown argument: $arg"
                Say info "dc envs plex"
                Say info "dc envs plex values"
                Say info "dc envs plex fill"
                exit 1
                ;;
        esac
    done
    if [[ "$show_values" -eq 1 && "$do_fill" -eq 1 ]]; then
        Say bad "Use values or fill, not both."
        exit 1
    fi
    if ! ValidServiceName "${folder:-}"; then
        Say bad "Envs needs a service name."
        Say info "dc envs plex"
        Say info "dc envs plex values"
        Say info "dc envs plex fill"
        exit 1
    fi
    RequireComposeFile "$APPS/$folder"
    file="$SVC_COMPOSE"
    if [[ "$do_fill" -eq 1 ]]; then
        EnvsFill "$file"
        return 0
    fi
    while IFS= read -r name; do
        [[ -n "$name" ]] && names+=("$name")
    done < <(ComposeVarNames "$file" | LC_ALL=C sort -u)
    if [[ ${#names[@]} -eq 0 ]]; then
        Say info "No env vars in $folder compose file."
        return 0
    fi
    Say info "$folder · ${#names[@]} var(s)"
    if [[ "$show_values" -eq 1 ]]; then
        LoadEnvValuesForService "$file"
    fi
    LoadEnvMap "$file"
    for name in "${names[@]}"; do
        source="${ENV_MAP_SRC[$name]:-}"
        case "$source" in
            shared) rank=1 ;;
            service) rank=2 ;;
            *)
                rank=3
                source="-"
                ;;
        esac
        rows+=("${rank}|${source}|${name}")
    done
    width="$(ColumnWidth 3 "${names[@]}")"
    if [[ "$show_values" -eq 1 ]]; then
        printf "%b  %-*s  │  %-*s  │  %s%b\n" "$c_dim" \
            "$width" "var" \
            "$from_w" "from" \
            "value" "$c_reset"
    else
        printf "%b  %-*s  │  %s%b\n" "$c_dim" \
            "$width" "var" \
            "from" "$c_reset"
    fi
    while IFS='|' read -r rank source name; do
        [[ -n "$name" ]] || continue
        if [[ "$source" == "service" ]]; then
            src_color="$c_teal"
        else
            src_color="$c_dim"
        fi
        if [[ "$source" == "-" ]]; then
            missing=$((missing + 1))
        fi
        if [[ "$show_values" -eq 1 ]]; then
            if [[ "$source" != "-" ]] && EnvGet "$name"; then
                value="$ENV_GOT"
                val_color="$c_reset"
            else
                value="-"
                val_color="$c_dim"
            fi
            printf "  %b%-*s%b  %b│%b  %b%-*s%b  %b│%b  %b%s%b\n" \
                "$c_teal" "$width" "$name" "$c_reset" \
                "$c_dim" "$c_reset" \
                "$src_color" "$from_w" "$source" "$c_reset" \
                "$c_dim" "$c_reset" \
                "$val_color" "$value" "$c_reset"
        else
            printf "  %b%-*s%b  %b│%b  %b%s%b\n" \
                "$c_teal" "$width" "$name" "$c_reset" \
                "$c_dim" "$c_reset" \
                "$src_color" "$source" "$c_reset"
        fi
    done < <(printf '%s\n' "${rows[@]}" | LC_ALL=C sort -t '|' -k1,1n -k3,3)
    if [[ "$missing" -gt 0 ]]; then
        printf "\n"
        Say warn "$missing unset in shared or service env files."
    fi
}

# Names referenced in env values (${VAR} / $VAR), one awk pass. Follows EnvRawValue:
# single-quoted values are literal, and quotes or " #" end the value. Skips $$.
EnvFileRefNames() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    awk '
        {
            sub(/\r$/, "")
            sub(/^[[:space:]]+/, "")
            if ($0 == "" || substr($0, 1, 1) == "#") next
            sub(/^export[[:space:]]+/, "")
            if (!match($0, /^[A-Za-z_][A-Za-z0-9_]*=/)) next
            v = substr($0, RLENGTH + 1)
            sub(/^[[:space:]]+/, "", v)
            if (substr(v, 1, 1) == "'\''") next
            if (substr(v, 1, 1) == "\"") {
                v = substr(v, 2)
                if (i = index(v, "\"")) v = substr(v, 1, i - 1)
            } else if (match(v, /[[:space:]]#/)) {
                v = substr(v, 1, RSTART - 1)
            }
            gsub(/[$][$]/, "", v)
            while (match(v, /[$][{]?[A-Za-z_][A-Za-z0-9_]*/)) {
                n = substr(v, RSTART, RLENGTH)
                v = substr(v, RSTART + RLENGTH)
                sub(/^[$][{]?/, "", n)
                if (!(n in seen)) { seen[n] = 1; print n }
            }
        }
    ' "$file"
}

Where() {
    local var dir path compose_file in_compose in_env label width state name
    local -a names=() rows=()
    local defined=""

    Banner "where"
    var="${WHERE_VAR:-}"
    if [[ -z "$var" ]]; then
        var="${EXTRA_ARGS[0]:-}"
    fi
    if [[ -z "$var" && -n "${folder:-}" && "$folder" != "all" ]]; then
        var="$folder"
    fi
    if [[ ${#EXTRA_ARGS[@]} -gt 1 ]]; then
        Say bad "Where takes one env var name."
        Say info "dc where MEDIA"
        exit 1
    fi
    if [[ -z "$var" || ! "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        Say bad "Where needs an env var name."
        Say info "dc where MEDIA"
        exit 1
    fi
    if [[ -n "${envFile:-}" && -f "$envFile" ]]; then
        LoadEnvMapFile "$envFile" shared
        [[ -n "${ENV_MAP_SRC[$var]+x}" ]] && defined="shared"
    fi
    BuildServiceIndex
    for path in "${IDX_NAMES[@]}"; do
        state="${IDX_STATE[$path]}"
        [[ "$state" == "archived" ]] && continue
        in_compose=0
        in_env=0
        [[ "${IDX_CREFS[$path]}" == *" $var "* ]] && in_compose=1
        [[ "${IDX_EREFS[$path]}" == *" $var "* ]] && in_env=1
        if [[ "$in_compose" -eq 0 && "$in_env" -eq 0 ]]; then
            continue
        fi
        if [[ "$in_compose" -eq 1 && "$in_env" -eq 1 ]]; then
            label="compose, env"
        elif [[ "$in_compose" -eq 1 ]]; then
            label="compose"
        else
            label="env"
        fi
        names+=("$path")
        rows+=("${path}|${state}|${label}")
    done
    Say info "$var"
    if [[ -n "$defined" ]]; then
        Say info "Defined in shared"
    fi
    if [[ ${#names[@]} -eq 0 ]]; then
        Say info "Not referenced by any service."
        return 0
    fi
    Say info "${#names[@]} service(s)"
    width="$(ColumnWidth 7 "${names[@]}")"
    printf "%b  %-*s  │  %-*s  │  %s%b\n" "$c_dim" \
        "$width" "service" \
        8 "state" \
        "in" "$c_reset"
    while IFS='|' read -r name state label; do
        [[ -n "$name" ]] || continue
        if [[ "$state" == "enabled" ]]; then
            printf "  %b%s%b  %-*s  %b│%b  %b%-*s%b  %b│%b  %s\n" \
                "$c_green" "✔" "$c_reset" \
                "$width" "$name" \
                "$c_dim" "$c_reset" \
                "$c_green" 8 "enabled" "$c_reset" \
                "$c_dim" "$c_reset" \
                "$label"
        else
            printf "  %b%s%b  %-*s  %b│%b  %b%-*s%b  %b│%b  %s\n" \
                "$c_red" "✘" "$c_reset" \
                "$width" "$name" \
                "$c_dim" "$c_reset" \
                "$c_dim" 8 "disabled" "$c_reset" \
                "$c_dim" "$c_reset" \
                "$label"
        fi
    done < <(printf '%s\n' "${rows[@]}" | LC_ALL=C sort -t '|' -k1,1)
}

IsScriptSettingKey() {
    case "$1" in
        APPS|ARCHIVE|COMPOSE_FILE|COMPOSE_FILE_DISABLED|STUB_FILE|STARTING_PORT) return 0 ;;
        *) return 1 ;;
    esac
}

# Compose and the Docker CLI read these from the environment, never via ${}.
IsRuntimeEnvKey() {
    case "$1" in
        COMPOSE_*|DOCKER_HOST|DOCKER_CONTEXT|DOCKER_CONFIG|DOCKER_CLIENT_TIMEOUT|DOCKER_BUILDKIT|DOCKER_DEFAULT_PLATFORM|DOCKER_TLS_VERIFY|DOCKER_CERT_PATH) return 0 ;;
        *) return 1 ;;
    esac
}

EnvFileKeys() {
    local file="$1" line key
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        line="${line#export }"
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
        key="${BASH_REMATCH[1]}"
        IsScriptSettingKey "$key" && continue
        IsRuntimeEnvKey "$key" && continue
        printf '%s\n' "$key"
    done < "$file"
}

Unused() {
    local dir f key name source width answer removed=0 compose_file backup
    local spin='|/-\' tick=0
    local -A def_from=()
    local -A def_files=()
    local -A referenced=()
    local -A touched=()
    local -a unused_keys=() all_dirs=()

    Banner "unused"

    UnusedSpin() {
        local msg="$1"
        [[ -t 2 ]] || return 0
        tick=$(( (tick + 1) % 4 ))
        printf '\r\033[K  %b%s%b  %s' "$c_teal" "${spin:tick:1}" "$c_reset" "$msg" >&2
    }
    UnusedSpinClear() {
        [[ -t 2 ]] || return 0
        printf '\r\033[K' >&2
    }

    AddUnusedDef() {
        local k="$1" src="$2" file="$3"
        IsScriptSettingKey "$k" && return 0
        IsRuntimeEnvKey "$k" && return 0
        if [[ -z "${def_from[$k]+x}" ]]; then
            def_from["$k"]="$src"
        else
            case ", ${def_from[$k]}, " in
                *", $src, "*) ;;
                *) def_from["$k"]="${def_from[$k]}, $src" ;;
            esac
        fi
        if [[ -z "${def_files[$k]+x}" ]]; then
            def_files["$k"]="$file"
        elif [[ $'\n'"${def_files[$k]}"$'\n' != *$'\n'"$file"$'\n'* ]]; then
            def_files["$k"]="${def_files[$k]}"$'\n'"$file"
        fi
    }

    MarkReferenced() {
        local n="$1"
        [[ -n "$n" ]] || return 0
        referenced["$n"]=1
    }

    while IFS= read -r dir; do
        [[ -n "$dir" ]] && all_dirs+=("$dir")
    done < <(ServiceDirs; ArchivedServiceDirs)

    UnusedSpin "Reading env files"
    if [[ -n "${envFile:-}" && -f "$envFile" ]]; then
        while IFS= read -r key; do
            [[ -n "$key" ]] || continue
            AddUnusedDef "$key" "shared" "$envFile"
        done < <(EnvFileKeys "$envFile")
        while IFS= read -r key; do
            MarkReferenced "$key"
        done < <(EnvFileRefNames "$envFile")
    fi
    for dir in "${all_dirs[@]}"; do
        name="$(basename "$dir")"
        UnusedSpin "Reading $name"
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            while IFS= read -r key; do
                [[ -n "$key" ]] || continue
                AddUnusedDef "$key" "$name" "$f"
            done < <(EnvFileKeys "$f")
            while IFS= read -r key; do
                MarkReferenced "$key"
            done < <(EnvFileRefNames "$f")
        done < <(EnvFilesInDir "$dir")
    done

    for dir in "${all_dirs[@]}"; do
        name="${dir%/}"
        name="${name##*/}"
        FindComposeFile "$dir" || continue
        compose_file="$SVC_COMPOSE"
        UnusedSpin "Scanning $name"
        while IFS= read -r key; do
            MarkReferenced "$key"
        done < <(ComposeVarNames "$compose_file")
    done
    # dc create and dc add write these templates later; keep the keys they need.
    while IFS= read -r key; do
        MarkReferenced "$key"
    done < <(ComposeVarNames "$STUB_FILE"; AddAppBlock app app image APP app | ComposeVarNamesStdin)

    for key in "${!def_from[@]}"; do
        [[ -n "${referenced[$key]+x}" ]] && continue
        unused_keys+=("$key")
    done
    UnusedSpinClear

    if [[ ${#unused_keys[@]} -eq 0 ]]; then
        Say info "No unused env vars."
        return 0
    fi

    Say info "${#unused_keys[@]} unused"
    width="$(ColumnWidth 3 "${unused_keys[@]}")"
    printf "%b  %-*s  │  %s%b\n" "$c_dim" \
        "$width" "key" \
        "from" "$c_reset"
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        source="${def_from[$key]}"
        printf "  %-*s  %b│%b  %s\n" \
            "$width" "$key" \
            "$c_dim" "$c_reset" \
            "$source"
    done < <(printf '%s\n' "${unused_keys[@]}" | LC_ALL=C sort -u)

    answer="$(Ask "Remove these unused env vars? [y/N]")"
    if [[ "$answer" != [yY] ]]; then
        Say info "Left unused keys in place."
        return 0
    fi

    for key in "${unused_keys[@]}"; do
        while IFS= read -r f; do
            [[ -n "$f" ]] && touched["$f"]=1
        done < <(printf '%s\n' "${def_files[$key]}")
    done
    for f in "${!touched[@]}"; do
        if ! backup="$(BackupPathFor "$f")" || ! cp -p -- "$f" "$backup"; then
            Say bad "Could not back up $f. Nothing removed."
            exit 1
        fi
        Say info "Backup: $backup"
    done

    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            RemoveEnvKeyInFile "$f" "$key" || {
                Say bad "Could not update $f."
                exit 1
            }
        done < <(printf '%s\n' "${def_files[$key]}")
        removed=$((removed + 1))
    done < <(printf '%s\n' "${unused_keys[@]}" | LC_ALL=C sort -u)
    Say ok "Removed $removed unused env var(s)."
}

TrimField() {
    local s="$1"
    s="${s//$'\r'/}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    if [[ "$s" == \"*\" && "$s" == *\" ]]; then
        s="${s:1:${#s}-2}"
    elif [[ "$s" == \'*\' && "$s" == *\' ]]; then
        s="${s:1:${#s}-2}"
    fi
    printf '%s' "$s"
}

SkippedMounts() {
    local file="$1" service_dir="$2"
    local line item expanded hostpart indent vol_indent=0 in_vol=0
    local -A seen=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        if [[ "$in_vol" -eq 0 ]]; then
            if [[ "$line" =~ ^([[:space:]]*)volumes:[[:space:]]*$ ]]; then
                in_vol=1
                vol_indent="${#BASH_REMATCH[1]}"
            fi
            continue
        fi
        [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^([[:space:]]*) ]]; then
            indent="${#BASH_REMATCH[1]}"
        else
            indent=0
        fi
        if [[ "$indent" -le "$vol_indent" ]]; then
            in_vol=0
            if [[ "$line" =~ ^([[:space:]]*)volumes:[[:space:]]*$ ]]; then
                in_vol=1
                vol_indent="${#BASH_REMATCH[1]}"
            fi
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*(.*)$ ]]; then
            item="$(TrimField "${BASH_REMATCH[1]}")"
        elif [[ "$line" =~ ^[[:space:]]*source:[[:space:]]*(.*)$ ]]; then
            item="$(TrimField "${BASH_REMATCH[1]}")"
        else
            continue
        fi
        [[ -z "$item" || "$item" == "type:"* || "$item" == "target:"* ]] && continue
        ExpandComposeInto "$item"
        [[ -n "$EXPANDED" ]] && item="$EXPANDED"
        if [[ "$item" == *:* ]]; then
            hostpart="$(TrimField "${item%%:*}")"
        else
            hostpart="$(TrimField "$item")"
        fi
        [[ -z "$hostpart" || -n "${seen[$hostpart]+x}" ]] && continue
        seen["$hostpart"]=1
        case "$hostpart" in
            "$service_dir"|"$service_dir"/*|.|./*) ;;
            *..*|/*|~*) printf '%s\n' "$hostpart" ;;
            */*) ;;
            *) printf 'volume %s\n' "$hostpart" ;;
        esac
    done < "$file"
}

TarMembersSafe() {
    local archive="$1" service="$2" member part
    local -a parts=()
    local ok=0
    while IFS= read -r member; do
        [[ -z "$member" ]] && continue
        member="${member#./}"
        [[ "$member" == "$service" || "$member" == "$service"/* ]] || return 1
        IFS=/ read -ra parts <<< "$member"
        for part in "${parts[@]}"; do
            [[ -z "$part" ]] && continue
            [[ "$part" == "." || "$part" == ".." ]] && return 1
        done
        ok=1
    done < <(tar -tzf "$archive")
    [[ "$ok" -eq 1 ]]
}

Path() {
    printf 'script=%s\n' "$SCRIPT_PATH"
    printf 'apps=%s\n' "$APPS"
}

RemoteScriptPath() {
    local path="$1"
    path="${path%$'\r'}"
    [[ "$path" == /* && "$path" != *$'\n'* ]] || return 1
    path="${path%/}"
    if [[ "$path" != */compose.sh ]]; then
        path="$path/compose.sh"
    fi
    [[ "$path" == /*/compose.sh ]] || return 1
    printf '%s\n' "$path"
}

RemotePathProgram() {
    cat << 'END'
home="$HOME"
bashrc="$home/.bashrc"
line=""
if [[ -f "$bashrc" ]]; then
    line="$(grep -E '^[[:space:]]*source[[:space:]]+.*dc\.bash' "$bashrc" | tail -n 1 || true)"
fi
if [[ -z "$line" ]]; then
    printf 'error=dc.bash source line was not found in ~/.bashrc\n' >&2
    exit 1
fi
path="${line#*source}"
path="${path%%#*}"
path="${path#"${path%%[![:space:]]*}"}"
path="${path%"${path##*[![:space:]]}"}"
if [[ "$path" == \"*\" && "$path" == *\" ]]; then
    path="${path:1:${#path}-2}"
elif [[ "$path" == \'*\' && "$path" == *\' ]]; then
    path="${path:1:${#path}-2}"
fi
path="${path/#\~/$home}"
case "$path" in
    '$HOME'/*) path="$home/${path#'$HOME'/}" ;;
esac
dir="$(cd "$(dirname "$path")" && pwd)" || exit 1
script="$dir/compose.sh"
if [[ ! -f "$script" ]]; then
    printf 'error=compose.sh was not found next to dc.bash\n' >&2
    exit 1
fi
if [[ "${PATH_ONLY:-}" == 1 ]]; then
    printf '%s\n' "$script"
    exit 0
fi
bash "$script" -a path
END
}

MoveHostOk() {
    local host="$1"
    [[ "$host" =~ ^[A-Za-z0-9._+-]+(@[A-Za-z0-9._-]+)?$ ]]
}

SshConfigUser() {
    local name="$1" file="$HOME/.ssh/config"
    local line matched=0 user="" token
    local -a tokens=()
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^[Hh][Oo][Ss][Tt][[:space:]]+(.+)$ ]]; then
            if [[ "$matched" -eq 1 && -n "$user" ]]; then
                printf '%s\n' "$user"
                return 0
            fi
            matched=0
            user=""
            read -ra tokens <<< "${BASH_REMATCH[1]}"
            for token in "${tokens[@]}"; do
                [[ "$token" == "$name" ]] && matched=1
            done
            continue
        fi
        if [[ "$matched" -eq 1 && "$line" =~ ^[Uu][Ss][Ee][Rr][[:space:]]+([^[:space:]]+) ]]; then
            user="${BASH_REMATCH[1]}"
        fi
    done < "$file"
    if [[ "$matched" -eq 1 && -n "$user" ]]; then
        printf '%s\n' "$user"
    fi
}

ResolveHost() {
    local name="$1" file="$HOME/.ssh/compose-hosts" short user saved=""
    if [[ "$name" == *@* ]]; then
        printf '%s\n' "$name"
        return 0
    fi
    if [[ -f "$file" ]]; then
        while read -r short user; do
            if [[ "$short" == "$name" && -n "$user" ]]; then
                printf '%s@%s\n' "$user" "$name"
                return 0
            fi
        done < "$file"
    fi
    saved="$(SshConfigUser "$name")"
    if [[ -n "$saved" ]]; then
        printf '%s@%s\n' "$saved" "$name"
    else
        printf '%s\n' "$name"
    fi
}

WriteSshHostBlock() {
    local config="$HOME/.ssh/config" hosts="$HOME/.ssh/compose-hosts" tmp line inside=0 name user
    tmp="$(mktemp)" || return 1
    if [[ -f "$config" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "# begin compose hosts" ]]; then
                inside=1
                continue
            fi
            if [[ "$line" == "# end compose hosts" ]]; then
                inside=0
                continue
            fi
            [[ "$inside" -eq 1 ]] && continue
            printf '%s\n' "$line" >> "$tmp"
        done < "$config"
    fi
    printf '\n# begin compose hosts\n' >> "$tmp"
    if [[ -f "$hosts" ]]; then
        while read -r name user; do
            [[ -n "$name" && -n "$user" ]] || continue
            printf 'Host %s\n    User %s\n' "$name" "$user" >> "$tmp"
        done < "$hosts"
    fi
    printf '# end compose hosts\n' >> "$tmp"
    mv "$tmp" "$config" || return 1
    chmod 600 "$config" || return 1
}

SaveHostUser() {
    local short="$1" user="$2" file="$HOME/.ssh/compose-hosts" tmp line name found=0
    if [[ ! -d "$HOME/.ssh" ]]; then
        mkdir -p "$HOME/.ssh" || return 1
        chmod 700 "$HOME/.ssh" || return 1
    fi
    tmp="$(mktemp)" || return 1
    if [[ -f "$file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            name="${line%% *}"
            if [[ "$name" == "$short" ]]; then
                printf '%s %s\n' "$short" "$user" >> "$tmp"
                found=1
            else
                printf '%s\n' "$line" >> "$tmp"
            fi
        done < "$file"
    fi
    [[ "$found" -eq 1 ]] || printf '%s %s\n' "$short" "$user" >> "$tmp"
    mv "$tmp" "$file" || return 1
    chmod 600 "$file" || return 1
    WriteSshHostBlock
}

RememberHost() {
    local full="$1" user short current answer
    [[ "$full" == *@* ]] || return 0
    user="${full%%@*}"
    short="${full#*@}"
    [[ -n "$user" && -n "$short" && "$user" != "$full" ]] || return 0
    MoveHostOk "$user" && MoveHostOk "$short" || return 1
    current="$(ResolveHost "$short")"
    if [[ "$current" == "$full" ]]; then
        Say info "$short connects as $full."
        return 0
    fi
    if [[ "$current" == *@* ]]; then
        answer="$(Ask "Use $full instead of $current? [y/N]")"
        [[ "$answer" == [yY] ]] || return 0
    fi
    SaveHostUser "$short" "$user" || return 1
    Say info "$short connects as $full."
}

ComposeHostNames() {
    local file="$HOME/.ssh/compose-hosts" short user
    local -A seen=()
    if [[ -f "$file" ]]; then
        while read -r short user; do
            [[ -n "$short" && -n "$user" ]] || continue
            MoveHostOk "$short" || continue
            [[ -n "${seen[$short]+x}" ]] && continue
            seen["$short"]=1
            printf '%s\n' "$short"
        done < "$file"
    fi
    [[ ${#seen[@]} -gt 0 ]]
}

Hosts() {
    local short full name_w=8 full_w=12 count=0
    local -a names=() targets=()
    local -a ssh_opts=(-T -o BatchMode=yes -o ConnectTimeout=5 -o GSSAPIAuthentication=no -o PreferredAuthentications=publickey)

    Banner "host list"
    if [[ -z "${HOME:-}" ]]; then
        Say bad "HOME is not set."
        exit 1
    fi
    while IFS= read -r short; do
        [[ -n "$short" ]] || continue
        full="$(ResolveHost "$short")"
        names+=("$short")
        targets+=("$full")
        (( ${#short} > name_w )) && name_w=${#short}
        (( ${#full} > full_w )) && full_w=${#full}
    done < <(ComposeHostNames)
    count=${#names[@]}
    if [[ "$count" -eq 0 ]]; then
        Say info "No hosts yet."
        Say info "dc host add root@hostname"
        return 0
    fi
    printf "  %b%-*s  %-*s  %s%b\n" "$c_dim" "$name_w" "host" "$full_w" "connects as" "move" "$c_reset"
    for ((i=0; i<count; i++)); do
        short="${names[$i]}"
        full="${targets[$i]}"
        if ! command -v ssh >/dev/null 2>&1; then
            printf "  %b·%b  %-*s  %-*s  %b?%b\n" "$c_teal" "$c_reset" "$name_w" "$short" "$full_w" "$full" "$c_yellow" "$c_reset"
            continue
        fi
        if ssh "${ssh_opts[@]}" "$full" true >/dev/null 2>&1; then
            printf "  %b✔%b  %-*s  %-*s  %bok%b\n" "$c_green" "$c_reset" "$name_w" "$short" "$full_w" "$full" "$c_green" "$c_reset"
        else
            printf "  %b✘%b  %-*s  %-*s  %bfail%b\n" "$c_red" "$c_reset" "$name_w" "$short" "$full_w" "$full" "$c_red" "$c_reset"
        fi
    done
    Say info "dc move SERVICE ${names[0]}"
}

DeleteMovedService() {
    local name="$1" target loc file="" resolved
    if ! resolved="$(ResolveServiceRoot "$name")"; then
        Say bad "Service does not exist."
        return 1
    fi
    target="${resolved%%|*}"
    loc="${resolved##*|}"
    file="$(ServiceComposeFile "$target" || true)"
    if [[ "$loc" == "apps" && -n "$file" ]] && CheckStatus "$name"; then
        Say warn "Stopping it now."
        RunOneCompose "$file" down || return 1
    fi
    Say warn "Deleting folder."
    rm -r -- "$target"
    Say ok "Folder deleted."
}

PROGRESS_TICK=0
ProgressBar() {
    local label="$1" done="$2" total="$3"
    local width=24 pct filled empty bar mark spin='|/-\'
    [[ "$done" =~ ^[0-9]+$ ]] || done=0
    [[ "$total" =~ ^[0-9]+$ && "$total" -gt 0 ]] || total=1
    if [[ "$done" -gt "$total" ]]; then
        done="$total"
    fi
    pct=$(( done * 100 / total ))
    filled=$(( pct * width / 100 ))
    empty=$(( width - filled ))
    printf -v bar '%*s' "$filled" ''
    bar="${bar// /█}"
    printf -v empty '%*s' "$empty" ''
    empty="${empty// /░}"
    mark="${spin:PROGRESS_TICK:1}"
    PROGRESS_TICK=$(( (PROGRESS_TICK + 1) % 4 ))
    printf '\r  %b%s%s%b  %s  %-8s %3d%%' "$c_teal" "$bar" "$empty" "$c_reset" "$mark" "$label" "$pct" >&2
}

# Print paths under $1 that this user cannot read (or enter, for dirs).
UnreadableUnder() {
    local root="$1"
    local path err line shown
    local -A seen=()

    [[ -d "$root" ]] || return 0
    err="$(mktemp)" || return 0
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        [[ -n "${seen[$path]+x}" ]] && continue
        seen["$path"]=1
        printf '%s\n' "$path"
    done < <(find "$root" \( ! -readable -o \( -type d ! -executable \) \) -print 2>"$err")
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *"Permission denied"* ]] || continue
        shown="${line#find: }"
        shown="${shown#: Permission denied}"
        shown="${shown#\'}"
        shown="${shown%\'}"
        shown="${shown#\`}"
        shown="${shown%\`}"
        shown="${shown#: Permission denied}"
        [[ -n "$shown" ]] || continue
        [[ -n "${seen[$shown]+x}" ]] && continue
        seen["$shown"]=1
        printf '%s\n' "$shown"
    done < "$err"
    rm -f "$err"
}

# PackService <dest.tgz> <pack_root> <service_dir> <name>
# Packs pack_root/name into dest; service_dir is only used to count files.
PackService() {
    local dest="$1" pack_root="$2" service_dir="$3" name="$4"
    local verbose err count done_n tpid watcher=""
    verbose="$(mktemp)" || return 1
    err="$(mktemp)" || {
        rm -f "$verbose"
        return 1
    }
    count="$(find "$service_dir" -print 2>/dev/null | wc -l)"
    count="${count//[[:space:]]/}"
    [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || count=1
    if command -v stdbuf >/dev/null 2>&1; then
        stdbuf -oL tar -C "$pack_root" -czf "$dest" -v "$name" >"$verbose" 2>"$err" &
    else
        tar -C "$pack_root" -czf "$dest" -v "$name" >"$verbose" 2>"$err" &
    fi
    tpid=$!
    if [[ -t 2 ]]; then
        (
            while :; do
                done_n="$(wc -l < "$verbose" 2>/dev/null || echo 0)"
                done_n="${done_n//[[:space:]]/}"
                [[ "$done_n" =~ ^[0-9]+$ ]] || done_n=0
                ProgressBar packing "$done_n" "$count"
                sleep 0.1
            done
        ) &
        watcher=$!
    fi
    if ! wait "$tpid"; then
        if [[ -n "$watcher" ]]; then
            kill "$watcher" 2>/dev/null
            wait "$watcher" 2>/dev/null
        fi
        printf '\r\033[K' >&2
        Say bad "Could not pack $name."
        [[ -s "$err" ]] && cat "$err" >&2
        rm -f "$verbose" "$err"
        return 1
    fi
    if [[ -n "$watcher" ]]; then
        kill "$watcher" 2>/dev/null
        wait "$watcher" 2>/dev/null
        ProgressBar packing "$count" "$count"
        printf '\n' >&2
    fi
    rm -f "$verbose" "$err"
}

StreamFile() {
    local file="$1" label="$2"
    local total fifo reader line copy_status=0
    total="$(wc -c < "$file")"
    total="${total//[[:space:]]/}"
    [[ "$total" =~ ^[0-9]+$ && "$total" -gt 0 ]] || total=1
    if [[ ! -t 2 ]]; then
        cat "$file"
        return
    fi
    if dd if=/dev/null of=/dev/null count=0 status=progress >/dev/null 2>&1; then
        fifo="$(mktemp -u)" || {
            cat "$file"
            return
        }
        mkfifo "$fifo" || {
            cat "$file"
            return
        }
        (
            while IFS= read -r -d $'\r' line || [[ -n "$line" ]]; do
                [[ "$line" == *bytes* ]] || continue
                [[ "$line" =~ ([0-9]+) ]] || continue
                ProgressBar "$label" "${BASH_REMATCH[1]}" "$total"
            done <"$fifo"
        ) &
        reader=$!
        ProgressBar "$label" 0 "$total"
        LC_ALL=C dd if="$file" bs=1048576 status=progress 2>"$fifo"
        copy_status=$?
        wait "$reader"
        rm -f "$fifo"
        if [[ "$copy_status" -ne 0 ]]; then
            printf '\r\033[K' >&2
            return "$copy_status"
        fi
        ProgressBar "$label" "$total" "$total"
        printf '\n' >&2
        return 0
    fi
    if command -v pv >/dev/null 2>&1; then
        fifo="$(mktemp -u)" || {
            cat "$file"
            return
        }
        mkfifo "$fifo" || {
            cat "$file"
            return
        }
        (
            while IFS= read -r line; do
                line="${line//[[:space:]]/}"
                [[ "$line" =~ ^[0-9]+$ ]] || continue
                ProgressBar "$label" "$line" 100
            done <"$fifo"
        ) &
        reader=$!
        pv -n -s "$total" "$file" 2>"$fifo"
        copy_status=$?
        wait "$reader"
        rm -f "$fifo"
        if [[ "$copy_status" -ne 0 ]]; then
            printf '\r\033[K' >&2
            return "$copy_status"
        fi
        ProgressBar "$label" 100 100
        printf '\n' >&2
        return 0
    fi
    cat "$file"
}

Move() {
    local host file service_dir pack_root size answer remote_info script_path apps_path
    local errfile remote_cmd name line key sent run_state header archive status stopped_for_move=0
    local resolved loc archived_flag=0 rel shown
    local -a ssh_opts=(-T -o BatchMode=yes -o ConnectTimeout=20 -o GSSAPIAuthentication=no -o PreferredAuthentications=publickey)
    local -a env_lines=() missing=() skipped=() unreadable=()
    local -a var_names=()

    Banner "move"
    if ! ValidServiceName "$folder"; then
        Say bad "Move needs a service name."
        Say info "dc move plex root@other-host"
        exit 1
    fi
    host="${EXTRA_ARGS[0]:-}"
    if [[ -z "$host" || ${#EXTRA_ARGS[@]} -ne 1 ]] || ! MoveHostOk "$host"; then
        Say bad "Move needs one host."
        Say info "dc move plex hostname"
        Say info "dc move plex root@hostname"
        exit 1
    fi
    host="$(ResolveHost "$host")"
    if ! command -v ssh >/dev/null 2>&1; then
        Say bad "ssh is required."
        exit 1
    fi
    if ! resolved="$(ResolveServiceRoot "$folder")"; then
        Say bad "Service does not exist."
        exit 1
    fi
    service_dir="${resolved%%|*}"
    loc="${resolved##*|}"
    if [[ "$loc" == "archive" ]]; then
        archived_flag=1
        pack_root="$(ArchiveDir)"
    else
        pack_root="$APPS"
    fi
    if ! file="$(ServiceComposeFile "$service_dir")"; then
        Say bad "Service does not exist."
        exit 1
    fi
    Say info "Contacting $host."
    errfile="$(mktemp)" || exit 1
    remote_info="$(ssh "${ssh_opts[@]}" "$host" bash -s <<<"$(RemotePathProgram)" 2>"$errfile")" || {
        Say bad "Could not reach $host."
        [[ -s "$errfile" ]] && cat "$errfile" >&2
        rm -f "$errfile"
        exit 1
    }
    rm -f "$errfile"
    while IFS= read -r line; do
        case "$line" in
            script=*) script_path="${line#script=}" ;;
            apps=*) apps_path="${line#apps=}" ;;
        esac
    done <<< "$remote_info"
    if ! script_path="$(RemoteScriptPath "$script_path")"; then
        script_path=""
    fi
    if [[ -z "$script_path" || "$apps_path" == *$'\n'* || -z "$apps_path" ]]; then
        Say bad "The other host did not report its path."
        [[ -n "$remote_info" ]] && printf '%s\n' "$remote_info" >&2
        exit 1
    fi
    Say info "Measuring $folder."
    size="$(du -sh "$service_dir" 2>/dev/null | awk '{print $1}')"
    [[ -n "$size" ]] || size="unknown"
    while IFS= read -r name; do
        [[ -n "$name" ]] && var_names+=("$name")
    done < <(ComposeVarNames "$file")
    LoadEnvMap "$file"
    for name in "${var_names[@]}"; do
        line="${ENV_MAP_LINE[$name]:-}"
        if [[ -n "$line" ]]; then
            env_lines+=("$line")
        else
            missing+=("$name")
        fi
    done
    while IFS= read -r line; do
        [[ -n "$line" ]] && skipped+=("$line")
    done < <(SkippedMounts "$file" "$service_dir")

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        rel="$line"
        if [[ "$rel" == "$service_dir"/* ]]; then
            rel="${folder}/${rel#"$service_dir"/}"
        fi
        unreadable+=("$rel")
    done < <(UnreadableUnder "$service_dir")

    Say info "Folder size: $size"
    Say info "Destination: $host"
    Say info "Apps path: $apps_path"
    Say info "Script: $script_path"
    if [[ "$archived_flag" -eq 1 ]]; then
        Say info "Source: archived"
        Say info "Lands archived on the other host."
    else
        Say info "The other host pulls the image when the service is started."
    fi
    if [[ ${#skipped[@]} -gt 0 ]]; then
        Say warn "Outside mounts stay here:"
        printf '    %s\n' "${skipped[@]}"
    fi
    if [[ ${#env_lines[@]} -gt 0 ]]; then
        sent=""
        for line in "${env_lines[@]}"; do
            sent+="${line%%=*} "
        done
        Say info "Env keys: ${sent% }"
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        Say warn "No value here for: ${missing[*]}"
    fi
    if [[ ${#unreadable[@]} -gt 0 ]]; then
        Say bad "Cannot pack: ${#unreadable[@]} path(s) are not readable."
        shown=0
        for rel in "${unreadable[@]}"; do
            printf '    %s\n' "$rel"
            shown=$((shown + 1))
            if [[ "$shown" -ge 20 && "$shown" -lt ${#unreadable[@]} ]]; then
                Say info "… and $(( ${#unreadable[@]} - shown )) more"
                break
            fi
        done
        Say info "Fix ownership, then retry. Example:"
        Say info "sudo chown -R \"\$USER:\" $service_dir"
        exit 1
    fi
    answer="$(Ask "Move $folder to $host? [y/N]")"
    if [[ "$answer" != [yY] ]]; then
        Say info "Keeping $folder here."
        return 0
    fi
    if [[ "$archived_flag" -eq 0 ]]; then
        run_state="$(ReturnStatus "$folder")"
        run_state="${run_state,,}"
        if [[ "$run_state" == *running* || "$run_state" == *restarting* || "$run_state" == *paused* ]]; then
            answer="$(Ask "Stop $folder before moving? [Y/n]")"
            if [[ -z "$answer" || "$answer" == [yY] ]]; then
                Say warn "Stopping $folder."
                if ! RunOneCompose "$file" stop; then
                    Say bad "Stop failed. This host was left unchanged."
                    exit 1
                fi
                stopped_for_move=1
            else
                Say warn "Copying while containers are running."
            fi
        fi
    fi

    header="$(mktemp)" || exit 1
    archive="$(mktemp)" || {
        rm -f "$header"
        exit 1
    }
    {
        printf 'COMPOSE-MOVE 2\n'
        printf 'service %s\n' "$folder"
        printf 'compose %s\n' "$(basename "$file")"
        printf 'archived %s\n' "$archived_flag"
        printf 'env %s\n' "${#env_lines[@]}"
        if [[ ${#env_lines[@]} -gt 0 ]]; then
            printf '%s\n' "${env_lines[@]}"
        fi
    } >"$header" || {
        Say bad "Could not pack $folder."
        rm -f "$header" "$archive"
        exit 1
    }
    if ! PackService "$archive" "$pack_root" "$service_dir" "$folder"; then
        rm -f "$header" "$archive"
        exit 1
    fi
    printf -v remote_cmd 'bash %q -a receive -s %q' "$script_path" "$folder"
    {
        cat "$header"
        StreamFile "$archive" sending
    } | ssh "${ssh_opts[@]}" "$host" "$remote_cmd"
    status=$?
    rm -f "$header" "$archive"
    if [[ "$status" -ne 0 ]]; then
        printf '\r\033[K' >&2
        Say bad "Move failed. The folder is still here."
        if [[ "$stopped_for_move" -eq 1 ]]; then
            Say warn "Starting $folder again."
            if RunOneCompose "$file" start; then
                Say ok "$folder is running."
            else
                Say bad "Could not start $folder."
            fi
        fi
        exit 1
    fi
    if [[ "$archived_flag" -eq 0 && -f "$APPS/$folder/$COMPOSE_FILE" ]]; then
        mv "$APPS/$folder/$COMPOSE_FILE" "$APPS/$folder/$COMPOSE_FILE_DISABLED"
        Say warn "Disabled $folder on this host."
    fi
    if [[ "$archived_flag" -eq 1 ]]; then
        Say ok "Moved $folder to $host. It is archived there."
        answer="$(Ask "Remove $folder from this archive? [y/N]")"
        if [[ "$answer" == [yY] ]]; then
            DeleteMovedService "$folder"
            return
        fi
        Say info "Kept the archived folder here."
        return 0
    fi
    Say ok "Moved $folder to $host. It is disabled there."
    answer="$(Ask "Remove $folder from this host? [y/N]")"
    if [[ "$answer" == [yY] ]]; then
        DeleteMovedService "$folder"
        return
    fi
    Say info "Kept the disabled folder here."
}

Receive() {
    local magic svc_line compose_line archived_line env_line compose_name env_count
    local line key added=0 i work archive arrived final_name dest_root archived_flag=0
    local -a env_lines=()

    if ! ValidServiceName "$folder"; then
        Say bad "Invalid service name."
        exit 1
    fi
    if [[ ! -d "$APPS" ]]; then
        Say bad "APPS directory does not exist."
        exit 1
    fi
    if [[ -e "$APPS/$folder" || -e "$(ArchiveDir)/$folder" ]]; then
        Say bad "Service already exists on this host."
        exit 1
    fi
    if [[ -n "${RECEIVE_STREAM:-}" ]]; then
        exec <"$RECEIVE_STREAM"
    fi
    IFS= read -r magic || exit 1
    [[ "$magic" == "COMPOSE-MOVE 2" ]] || {
        Say bad "Move stream was not recognized."
        Say info "Both hosts need a current compose.sh (COMPOSE-MOVE 2)."
        exit 1
    }
    IFS= read -r svc_line || exit 1
    IFS= read -r compose_line || exit 1
    IFS= read -r archived_line || exit 1
    IFS= read -r env_line || exit 1
    [[ "$svc_line" == "service $folder" ]] || {
        Say bad "Move stream service does not match."
        exit 1
    }
    [[ "$compose_line" == compose\ * ]] || {
        Say bad "Move stream was not recognized."
        exit 1
    }
    compose_name="${compose_line#compose }"
    [[ "$compose_name" != */* && "$compose_name" != *..* && "$compose_name" =~ ^[A-Za-z0-9._-]+$ ]] || {
        Say bad "Compose file name was refused."
        exit 1
    }
    [[ "$archived_line" =~ ^archived[[:space:]]+(0|1)$ ]] || {
        Say bad "Move stream was not recognized."
        exit 1
    }
    archived_flag="${BASH_REMATCH[1]}"
    [[ "$env_line" =~ ^env[[:space:]]+([0-9]+)$ ]] || {
        Say bad "Move stream was not recognized."
        exit 1
    }
    env_count="${BASH_REMATCH[1]}"
    if [[ "$env_count" -gt 500 ]]; then
        Say bad "Move stream listed too many env keys."
        exit 1
    fi
    for ((i=0; i<env_count; i++)); do
        IFS= read -r line || {
            Say bad "Move stream ended early."
            exit 1
        }
        [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || {
            Say bad "Move stream had a bad env line."
            exit 1
        }
        env_lines+=("$line")
    done
    work="$(mktemp -d)" || exit 1
    archive="$work/archive.tar.gz"
    if ! cat >"$archive"; then
        rm -rf "$work"
        Say bad "Move stream ended early."
        exit 1
    fi
    mkdir -p "$work/unpack"
    if ! TarMembersSafe "$archive" "$folder"; then
        rm -rf "$work"
        Say bad "Move archive was refused."
        exit 1
    fi
    if ! tar -xzf "$archive" -C "$work/unpack"; then
        rm -rf "$work"
        Say bad "Could not unpack the service."
        exit 1
    fi
    final_name="$COMPOSE_FILE_DISABLED"
    arrived="$work/unpack/$folder/$compose_name"
    if [[ -f "$arrived" && "$compose_name" != "$final_name" ]]; then
        mv -f "$arrived" "$work/unpack/$folder/$final_name"
    fi
    if [[ -f "$work/unpack/$folder/$COMPOSE_FILE" ]]; then
        mv -f "$work/unpack/$folder/$COMPOSE_FILE" "$work/unpack/$folder/$final_name"
    fi
    if [[ ! -f "$work/unpack/$folder/$final_name" ]]; then
        rm -rf "$work"
        Say bad "Compose file was not in the archive."
        exit 1
    fi
    if [[ -e "$APPS/$folder" || -e "$(ArchiveDir)/$folder" ]]; then
        rm -rf "$work"
        Say bad "Service already exists on this host."
        exit 1
    fi
    if [[ "$archived_flag" -eq 1 ]]; then
        dest_root="$(ArchiveDir)"
        mkdir -p "$dest_root" || {
            rm -rf "$work"
            Say bad "Could not create archive directory."
            exit 1
        }
    else
        dest_root="$APPS"
    fi
    if ! mv "$work/unpack/$folder" "$dest_root/$folder"; then
        rm -rf "$work"
        Say bad "Could not place the service folder."
        exit 1
    fi
    rm -rf "$work"
    if [[ ${#env_lines[@]} -gt 0 ]]; then
        for line in "${env_lines[@]}"; do
            key="${line%%=*}"
            if grep -qE "^[[:space:]]*${key}=" "$envFile"; then
                Say info "Kept $key."
                continue
            fi
            if [[ "$added" -eq 0 ]]; then
                printf '\n# moved service %s\n' "$folder" >>"$envFile"
            fi
            printf '%s\n' "$line" >>"$envFile"
            Say ok "Added $key."
            added=1
        done
    fi
    if [[ "$archived_flag" -eq 1 ]]; then
        Say ok "Received $folder. It is archived."
    else
        Say ok "Received $folder. It is disabled."
    fi
}

Exec() {
    local file svc s
    local -a svcs=()
    Banner "exec"
    if [[ -z "$folder" || "$folder" == "all" ]]; then
        Say bad "Exec needs a service name."
        exit 1
    fi
    if [[ ${#EXTRA_ARGS[@]} -eq 0 ]]; then
        Say bad "Exec needs a command."
        Say info "dc exec plex -- bash"
        exit 1
    fi
    RequireComposeFile "$APPS/$folder"
    if [[ "$SVC_ENABLED" -ne 1 ]]; then
        Say warn "Service is disabled."
        exit 1
    fi
    file="$SVC_COMPOSE"
    while IFS= read -r svc; do
        [[ -n "$svc" ]] && svcs+=("$svc")
    done < <(RunOneCompose "$file" config --services 2>/dev/null)
    svc=""
    for s in "${svcs[@]}"; do
        if [[ "${s,,}" == "$folder" ]]; then
            svc="$s"
            break
        fi
    done
    if [[ -z "$svc" && ${#svcs[@]} -eq 1 ]]; then
        svc="${svcs[0]}"
    fi
    if [[ -z "$svc" && ${#svcs[@]} -eq 0 ]]; then
        svc="$folder"
    fi
    if [[ -z "$svc" ]]; then
        Say bad "Compose service name is missing."
        printf '    %s\n' "${svcs[@]}"
        exit 1
    fi
    if [[ -t 0 && -t 1 ]]; then
        RunOneCompose "$file" exec "$svc" "${EXTRA_ARGS[@]}"
        return
    fi
    if { : </dev/tty >/dev/tty; } 2>/dev/null; then
        RunOneCompose "$file" exec "$svc" "${EXTRA_ARGS[@]}" </dev/tty >/dev/tty 2>&1
        return
    fi
    RunOneCompose "$file" exec -T "$svc" "${EXTRA_ARGS[@]}"
}

Logs() {
    local arg follow=0
    Banner "logs"
    for arg in "${EXTRA_ARGS[@]}"; do
        case "$arg" in
            -f|--follow) follow=1 ;;
        esac
    done
    if [[ "$follow" -eq 1 && ( -z "$folder" || "$folder" == "all" ) ]]; then
        Say bad "Follow needs a service name."
        exit 1
    fi
    RunServices "$folder" logs "${EXTRA_ARGS[@]}"
}

EditFile() {
    local name="${1:-$folder}"
    if ! CheckFolderSuppliedNoExit "$name"; then
        Say bad "No service name supplied."
        exit 1
    fi
    if ! FindComposeFile "$APPS/$name"; then
        Say bad "Neither primary nor backup file exists."
        Say info "$APPS/$name/$COMPOSE_FILE"
        Say info "$APPS/$name/$COMPOSE_FILE_DISABLED"
        exit 1
    fi
    if [[ "$SVC_ENABLED" -eq 1 ]]; then
        Say ok "Using $SVC_COMPOSE"
    else
        Say warn "Primary file not found. Using $SVC_COMPOSE"
    fi
    Banner "edit $name"
    OpenEditor "$SVC_COMPOSE"
}

EditEnv() {
    local target answer

    Banner "env"
    if [[ -z "${folder:-}" || "$folder" == "all" ]]; then
        if [[ ! -f "$envFile" ]]; then
            Say bad "Env file does not exist: $envFile"
            exit 1
        fi
        Say ok "Using $envFile"
        OpenEditor "$envFile"
        return 0
    fi
    if ! ValidServiceName "$folder"; then
        Say bad "Env needs a service name."
        Say info "dc env"
        Say info "dc env plex"
        exit 1
    fi
    if [[ ! -d "$APPS/$folder" ]]; then
        Say bad "Service does not exist."
        exit 1
    fi
    target="$APPS/$folder/.env"
    if [[ -f "$target" ]]; then
        Say ok "Using $target"
    else
        answer="$(Ask "Create $folder/.env? [y/N]")"
        if [[ "$answer" != [yY] ]]; then
            Say info "Left $folder without an env file."
            return 0
        fi
        printf '# %s service env\n' "$folder" >"$target" || {
            Say bad "Could not create $target."
            exit 1
        }
        Say ok "Created $target"
    fi
    OpenEditor "$target"
}

OpenEditor() {
    local file="$1"
    local editor
    if command -v nano >/dev/null 2>&1; then
        editor="nano"
    elif command -v vim >/dev/null 2>&1; then
        editor="vim"
    else
        Say bad "nano or vim is required."
        exit 1
    fi
    if [[ -t 0 && -t 1 ]]; then
        "$editor" -- "$file"
        return
    fi
    if { : </dev/tty >/dev/tty; } 2>/dev/null; then
        "$editor" -- "$file" </dev/tty >/dev/tty 2>&1
        return
    fi
    Say bad "No terminal available for $editor."
    exit 1
}


Create() {
    local image content target
    Banner "create"
    if ! CheckFolderSuppliedNoExit "${1:-$folder}"; then
        folder="$(Ask "What should we name the service:")"
        folder="${folder,,}"
    fi
    if ! ValidServiceName "$folder"; then
        Say bad "Invalid service name."
        Say info "Use letters, numbers, dot, dash, or underscore."
        exit 1
    fi

    if [ ! -f "$STUB_FILE" ]; then
        Say bad "Stub file does not exist: $STUB_FILE"
        exit 1
    fi

    if [ -e "$APPS/$folder" ] || [ -e "$(ArchiveDir)/$folder" ]; then
        Say warn "Service already exists: $folder"
        exit 1
    fi

    image="$(Ask "Enter the container image:")"
    if [ -z "$image" ]; then
        Say bad "Image not supplied."
        exit 1
    fi
    if [[ ! "$image" =~ ^[A-Za-z0-9._/:@-]+$ ]]; then
        Say bad "Image name has unsupported characters."
        exit 1
    fi

    content="$(<"$STUB_FILE")"
    content="${content//"{{SERVICE}}"/"$folder"}"
    content="${content//"{{IMAGE}}"/"$image"}"
    target="$APPS/$folder/$COMPOSE_FILE_DISABLED"
    if ! mkdir -p "$APPS/$folder" || ! printf '%s\n' "$content" >"$target"; then
        Say bad "Could not create $folder."
        exit 1
    fi
    Say ok "Service created: $folder"
    Say warn "Disabled until you edit the compose file."
}

# Compose service keys already in the file (best-effort).
ComposeServiceKeys() {
    local file="$1" key
    if RunOneCompose "$file" config --services >/dev/null 2>&1; then
        RunOneCompose "$file" config --services 2>/dev/null
        return 0
    fi
    while IFS= read -r key; do
        [[ -n "$key" ]] && printf '%s\n' "$key"
    done < <(grep -E '^  [A-Za-z0-9._-]+:[[:space:]]*$' "$file" 2>/dev/null | sed -E 's/^  ([^:]+):.*/\1/')
}

# AddAppBlock <app key> <container name> <image> <port prefix> <folder>
# The compose service block dc add appends. Unused scans it too, so keys it
# needs are never reported as unused.
AddAppBlock() {
    local svc_key="$1" cname="$2" image="$3" port_prefix="$4" folder="$5"
    printf '\n'
    printf '  %s:\n' "$svc_key"
    printf '    container_name: %s\n' "$cname"
    printf '    hostname: %s\n' "$svc_key"
    printf '    image: %s\n' "$image"
    printf '    restart: unless-stopped\n'
    printf '    network_mode: bridge\n'
    printf '    ports:\n'
    printf '      - ${%s_PORT_80}:80\n' "$port_prefix"
    printf '    volumes:\n'
    printf '      - ${APPS}/%s/%s:/config\n' "$folder" "$svc_key"
    printf '      - ${TIME}\n'
    printf '    environment:\n'
    printf '      - PUID=${PUID}\n'
    printf '      - PGID=${PGID}\n'
    printf '      - TZ=${TZ}\n'
    printf '    logging:\n'
    printf '      driver: json-file\n'
    printf '      options:\n'
    printf '        max-file: ${DOCKERLOGGING_MAXFILE}\n'
    printf '        max-size: ${DOCKERLOGGING_MAXSIZE}\n'
}

Add() {
    local file svc_key image cname port_prefix answer existing
    local -a keys=()

    Banner "add"
    if ! ValidServiceName "${folder:-}"; then
        Say bad "Add needs a service folder name."
        Say info "dc add plex"
        exit 1
    fi
    if [[ -d "$(ArchiveDir)/$folder" && ! -d "$APPS/$folder" ]]; then
        Say bad "Service is archived."
        Say info "dc unarchive $folder"
        exit 1
    fi
    RequireComposeFile "$APPS/$folder"
    file="$SVC_COMPOSE"

    while IFS= read -r existing; do
        [[ -n "$existing" ]] && keys+=("$existing")
    done < <(ComposeServiceKeys "$file")
    if [[ ${#keys[@]} -gt 0 ]]; then
        Say info "Existing apps: ${keys[*]}"
    fi

    svc_key="$(Ask "New app key (compose service name):")"
    svc_key="${svc_key,,}"
    svc_key="${svc_key// /-}"
    if ! ValidServiceName "$svc_key"; then
        Say bad "Invalid app key."
        exit 1
    fi
    for existing in "${keys[@]}"; do
        if [[ "$existing" == "$svc_key" ]]; then
            Say bad "App key already exists: $svc_key"
            exit 1
        fi
    done

    image="$(Ask "Container image:")"
    if [[ -z "$image" ]]; then
        Say bad "Image not supplied."
        exit 1
    fi
    if [[ ! "$image" =~ ^[A-Za-z0-9._/:@-]+$ ]]; then
        Say bad "Image name has unsupported characters."
        exit 1
    fi

    cname="${folder}-${svc_key}"
    port_prefix="$(ServiceEnvPrefix "$svc_key")"
    Say info "Will append to $file"
    Say info "container_name: $cname"
    Say info "volume: \${APPS}/$folder/$svc_key"
    Say info "port env: ${port_prefix}_PORT_80"
    answer="$(Ask "Add $svc_key to $folder? [y/N]")"
    if [[ "$answer" != [yY] ]]; then
        Say info "Left $folder unchanged."
        return 0
    fi

    AddAppBlock "$svc_key" "$cname" "$image" "$port_prefix" "$folder" >>"$file" || {
        Say bad "Could not write $file."
        exit 1
    }
    Say ok "Added $svc_key to $folder."
    Say info "dc envs $folder fill"
    Say info "dc edit $folder"
    if [[ -f "$APPS/$folder/$COMPOSE_FILE" ]]; then
        answer="$(Ask "Run up for $folder now? [y/N]")"
        if [[ "$answer" == [yY] ]]; then
            RunOneCompose "$file" up -d || exit 1
        fi
    else
        Say warn "Service is disabled. dc enable $folder"
    fi
}

TidyFixedHeader() {
    case "$1" in
        "Script Settings"|"Universal Settings"|"User Specific Settings"|"Ports"|"Other") return 0 ;;
        *) return 1 ;;
    esac
}

TidyEnvWriteSection() {
    local out="$1" title="$2"
    shift 2
    local key wrote=0
    for key in "$@"; do
        [[ -n "${ENV_TIDY_VAL[$key]+x}" ]] || continue
        if [[ "$wrote" -eq 0 ]]; then
            printf '# %s\n' "$title" >>"$out"
            wrote=1
        fi
        printf '%s=%s\n' "$key" "${ENV_TIDY_VAL[$key]}" >>"$out"
        unset "ENV_TIDY_VAL[$key]"
        unset "ENV_TIDY_CAT[$key]"
    done
    [[ "$wrote" -eq 1 ]] && printf '\n' >>"$out"
}

TidyEnv() {
    local line key val sort_key out answer title current="" i j wrote
    local top=0 ports=0 cats=0 other=0 dups=0
    local -a port_rows=() other_keys=() cat_order=() order_cat=() order_key=()
    local -A ENV_TIDY_VAL=()
    local -A ENV_TIDY_CAT=()
    local -A seen=()
    local -A cat_seen=()

    if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
        if [[ ${#EXTRA_ARGS[@]} -eq 1 && "${EXTRA_ARGS[0]}" == "--undo" ]]; then
            RestoreEnv
            return
        fi
        Say bad "Tidy takes an optional --undo."
        Say info "dc tidy"
        Say info "dc tidy --undo"
        exit 1
    fi
    Banner "tidy"
    if [[ ! -f "$envFile" ]]; then
        Say bad "Env file does not exist: $envFile"
        exit 1
    fi
    if [[ ! -w "$envFile" ]]; then
        Say bad "Cannot write $envFile."
        exit 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        if [[ -z "$line" ]]; then
            continue
        fi
        if [[ "$line" == \#* ]]; then
            title="${line#\#}"
            title="${title#"${title%%[![:space:]]*}"}"
            title="${title%"${title##*[![:space:]]}"}"
            if [[ -z "$title" ]] || TidyFixedHeader "$title"; then
                current=""
            else
                current="$title"
                if [[ -z "${cat_seen[$current]+x}" ]]; then
                    cat_seen["$current"]=1
                    cat_order+=("$current")
                fi
            fi
            continue
        fi
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        if [[ -n "${seen[$key]+x}" ]]; then
            dups=$((dups + 1))
        fi
        seen["$key"]=1
        ENV_TIDY_VAL["$key"]="$val"
        ENV_TIDY_CAT["$key"]="$current"
        order_cat+=("$current")
        order_key+=("$key")
    done < "$envFile"
    if [[ ${#ENV_TIDY_VAL[@]} -eq 0 ]]; then
        Say info "Env file has no variables."
        return 0
    fi

    out="$(mktemp)" || exit 1
    TidyEnvWriteSection "$out" "Script Settings" \
        APPS ARCHIVE COMPOSE_FILE COMPOSE_FILE_DISABLED STUB_FILE STARTING_PORT
    TidyEnvWriteSection "$out" "Universal Settings" \
        COMPOSE_VERSION COMPOSE_HTTP_TIMEOUT DOCKER_CLIENT_TIMEOUT \
        DOCKERLOGGING_MAXFILE DOCKERLOGGING_MAXSIZE TIME DOCKER_SOCK
    TidyEnvWriteSection "$out" "User Specific Settings" \
        PUID PGID TZ
    top=$(( ${#seen[@]} - ${#ENV_TIDY_VAL[@]} ))

    for key in "${!ENV_TIDY_VAL[@]}"; do
        if [[ "$key" == *_PORT_* ]]; then
            val="${ENV_TIDY_VAL[$key]}"
            sort_key="${val%%[!0-9]*}"
            [[ "$sort_key" =~ ^[0-9]+$ ]] || sort_key=999999
            port_rows+=("$(printf '%06d\t%s' "$sort_key" "$key")")
            unset "ENV_TIDY_CAT[$key]"
        fi
    done

    if [[ ${#port_rows[@]} -gt 0 ]]; then
        printf '# Ports\n' >>"$out"
        while IFS=$'\t' read -r sort_key key; do
            [[ -n "$key" ]] || continue
            printf '%s=%s\n' "$key" "${ENV_TIDY_VAL[$key]}" >>"$out"
            unset "ENV_TIDY_VAL[$key]"
            ports=$((ports + 1))
        done < <(printf '%s\n' "${port_rows[@]}" | LC_ALL=C sort)
        printf '\n' >>"$out"
    fi

    for title in "${cat_order[@]}"; do
        wrote=0
        for i in "${!order_key[@]}"; do
            key="${order_key[$i]}"
            [[ "${ENV_TIDY_CAT[$key]:-}" == "$title" ]] || continue
            [[ -n "${ENV_TIDY_VAL[$key]+x}" ]] || continue
            for ((j=i+1; j<${#order_key[@]}; j++)); do
                if [[ "${order_key[$j]}" == "$key" ]]; then
                    continue 2
                fi
            done
            if [[ "$wrote" -eq 0 ]]; then
                printf '# %s\n' "$title" >>"$out"
                wrote=1
            fi
            printf '%s=%s\n' "$key" "${ENV_TIDY_VAL[$key]}" >>"$out"
            unset "ENV_TIDY_VAL[$key]"
            unset "ENV_TIDY_CAT[$key]"
        done
        if [[ "$wrote" -eq 1 ]]; then
            printf '\n' >>"$out"
            cats=$((cats + 1))
        fi
    done

    for key in "${!ENV_TIDY_VAL[@]}"; do
        other_keys+=("$key")
    done
    if [[ ${#other_keys[@]} -gt 0 ]]; then
        printf '# Other\n' >>"$out"
        while IFS= read -r key; do
            [[ -n "$key" ]] || continue
            printf '%s=%s\n' "$key" "${ENV_TIDY_VAL[$key]}" >>"$out"
            other=$((other + 1))
        done < <(printf '%s\n' "${other_keys[@]}" | LC_ALL=C sort)
        printf '\n' >>"$out"
    fi

    Say info "Top settings: $top"
    Say info "Ports: $ports"
    Say info "Categories: $cats"
    Say info "Other: $other"
    if [[ "$dups" -gt 0 ]]; then
        Say warn "Duplicate keys kept the last value: $dups"
    fi
    answer="$(Ask "Rewrite $envFile? [y/N]")"
    if [[ "$answer" != [yY] ]]; then
        rm -f "$out"
        Say info "Left $envFile unchanged."
        return 0
    fi
    local bak
    bak="$(BackupPathFor "$envFile")" || {
        rm -f "$out"
        Say bad "Could not create backup folder."
        exit 1
    }
    cp "$envFile" "$bak" || {
        rm -f "$out"
        Say bad "Could not write $bak."
        exit 1
    }
    if ! mv "$out" "$envFile"; then
        rm -f "$out"
        Say bad "Could not rewrite $envFile."
        exit 1
    fi
    Say ok "Organized $envFile."
    Say info "Previous file saved as $bak."
}

RestoreEnv() {
    local bak answer

    Banner "tidy undo"
    bak="$(ResolveBackupPath "$envFile" || true)"
    if [[ ! -f "$bak" ]]; then
        Say bad "No tidy backup found."
        Say info "Expected $(BackupDirFor "$envFile")/$(basename "$envFile").bak"
        Say info "dc tidy creates that file before it rewrites .env."
        exit 1
    fi
    if [[ ! -r "$bak" ]]; then
        Say bad "Cannot read $bak."
        exit 1
    fi
    Say info "Backup: $bak"
    if [[ -f "$envFile" ]]; then
        Say warn "This replaces $envFile."
    fi
    answer="$(Ask "Restore .env from the tidy backup? [y/N]")"
    if [[ "$answer" != [yY] ]]; then
        Say info "Left $envFile unchanged."
        return 0
    fi
    if [[ -e "$envFile" && ! -w "$envFile" ]]; then
        Say bad "Cannot write $envFile."
        exit 1
    fi
    if [[ -e "$(dirname "$envFile")" && ! -w "$(dirname "$envFile")" ]]; then
        Say bad "Cannot write in $(dirname "$envFile")."
        exit 1
    fi
    cp "$bak" "$envFile" || {
        Say bad "Could not restore $envFile."
        exit 1
    }
    Say ok "Restored $envFile from $bak."
}

MarkUsedPort() {
    local -n _ports=$1
    local raw="$2" port
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    [[ "$raw" =~ ^([0-9]+) ]] || return 1
    port="${BASH_REMATCH[1]}"
    [[ "$port" -ge 1 && "$port" -le 65535 ]] || return 1
    _ports["$port"]=1
}

LoadEnvPortsFromFile() {
    local name=$1
    local file=$2
    local key value
    [[ -f "$file" ]] || return 0
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        key="${key%"${key##*[![:space:]]}"}"
        key="${key//$'\r'/}"
        [[ "$key" == "STARTING_PORT" ]] && continue
        [[ "$key" == *_PORT_* && "$key" != \#* ]] || continue
        MarkUsedPort "$name" "$value"
    done < "$file"
}

LoadEnvPorts() {
    local name=$1
    local file
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        LoadEnvPortsFromFile "$name" "$file"
    done < <(AllEnvFiles)
}

EnvStartingPort() {
    local raw="${STARTING_PORT:-5000}"
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    if [[ "$raw" =~ ^[0-9]+$ && "$raw" -ge 1 && "$raw" -le 65535 ]]; then
        printf '%s\n' "$raw"
        return 0
    fi
    printf '5000\n'
}

LoadListeningPorts() {
    local name=$1
    local line
    if command -v ss >/dev/null 2>&1; then
        while IFS= read -r line; do
            [[ "$line" =~ :([0-9]+)([[:space:]]|$) ]] || continue
            MarkUsedPort "$name" "${BASH_REMATCH[1]}"
        done < <(ss -H -lnt 2>/dev/null || true)
        return 0
    fi
    if command -v netstat >/dev/null 2>&1; then
        while IFS= read -r line; do
            [[ "$line" =~ :([0-9]+)[[:space:]] ]] || continue
            MarkUsedPort "$name" "${BASH_REMATCH[1]}"
        done < <(netstat -lnt 2>/dev/null || netstat -an 2>/dev/null || true)
    fi
}

NextPort() {
    local floor start="" port
    local -A used=()

    Banner "nextport"
    floor="$(EnvStartingPort)"
    if [[ -n "${folder:-}" && "$folder" != "all" ]]; then
        if [[ "$folder" =~ ^[0-9]+$ && ${#EXTRA_ARGS[@]} -eq 0 ]]; then
            start="$folder"
        else
            Say bad "Nextport takes an optional start port."
            Say info "dc nextport"
            Say info "dc nextport 8080"
            exit 1
        fi
    elif [[ ${#EXTRA_ARGS[@]} -gt 1 ]]; then
        Say bad "Nextport takes an optional start port."
        Say info "dc nextport"
        Say info "dc nextport 8080"
        exit 1
    elif [[ ${#EXTRA_ARGS[@]} -eq 1 ]]; then
        start="${EXTRA_ARGS[0]}"
    fi
    if [[ -z "$start" ]]; then
        start="$floor"
    elif [[ ! "$start" =~ ^[0-9]+$ || "$start" -lt 1 || "$start" -gt 65535 ]]; then
        Say bad "Start port must be 1 to 65535."
        exit 1
    elif [[ "$start" -lt "$floor" ]]; then
        Say bad "Start port must be $floor or higher."
        Say info "Set STARTING_PORT in .env to change the floor."
        exit 1
    fi
    LoadEnvPorts used
    LoadListeningPorts used
    for ((port=start; port<=65535; port++)); do
        [[ -n "${used[$port]+x}" ]] && continue
        Say ok "$port"
        Say info "Free from env files and listening ports."
        return 0
    done
    Say bad "No free port from $start to 65535."
    exit 1
}

CheckPorts() {
    local key value name width file
    local -a names=()
    declare -A ports
    Banner "ports"

    while IFS= read -r file; do
        [[ -n "$file" && -f "$file" ]] || continue
        while IFS='=' read -r key value || [[ -n "$key" ]]; do
            key="${key//$'\r'/}"
            key="${key%"${key##*[![:space:]]}"}"
            [[ "$key" == *_PORT_* && "$key" != \#* ]] || continue
            name="${key%%_PORT_*}"
            name="${name^^}"
            [[ -n "$name" ]] || continue
            EnvRawValue "${value//$'\r'/}"
            value="$ENV_RAW_TEXT"
            if [[ -n "${ports[$name]:-}" ]]; then
                ports[$name]+="  ${value}"
            else
                ports[$name]="$value"
                names+=("$name")
            fi
        done < "$file"
    done < <(AllEnvFiles)

    if [[ ${#names[@]} -eq 0 ]]; then
        Say info "No _PORT_ entries in project or service env files."
        return
    fi
    width="$(ColumnWidth 7 "${names[@]}")"
    printf "%b  %-*s  │  %s%b\n" "$c_dim" "$width" "service" "ports" "$c_reset"
    while IFS= read -r name; do
        printf "  %b%-*s%b  %b│%b  %s\n" "$c_teal" "$width" "$name" "$c_reset" "$c_dim" "$c_reset" "${ports[$name]}"
    done < <(printf '%s\n' "${names[@]}" | sort)
}


### Image listing and pull

# Tag is the text after the last colon that belongs to the repository,
# not a registry port. localhost:5000/nginx has no tag; nginx:1.25 does.
ImageTag() {
    local ref="$1"
    local base="${ref%%@*}"
    local repo="${base##*/}"
    local tag

    if [[ "$repo" == *:* ]]; then
        tag="${repo##*:}"
        if [ -n "$tag" ]; then
            printf '%s' "$tag"
            return
        fi
    fi

    if [ "$ref" != "$base" ]; then
        printf '%s' "digest"
        return
    fi

    printf '%s' "-"
}

ImageRefUnresolved() {
    local ref="$1"
    case "$ref" in
        *'$'*|*'{{'*|'>'*|'|'*|'*'*|'!'*|*' '*|*':') return 0 ;;
        *) return 1 ;;
    esac
}

CleanImageRef() {
    local val="$1"
    val="${val//$'\r'/}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"

    if [[ "$val" == \"* ]]; then
        val="${val:1}"
        val="${val%%\"*}"
    elif [[ "$val" == \'* ]]; then
        val="${val:1}"
        val="${val%%\'*}"
    else
        val="${val%%#*}"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
    fi

    printf '%s' "$val"
}

# Expand $VAR, ${VAR}, ${VAR:-default}, and ${VAR-default} from loaded env
# values (EnvGet) into EXPANDED (no subshell).
ExpandComposeInto() {
    local _ecv_rest="$1" _ecv_out="" _ecv_def _ecv_match

    while [[ -n "$_ecv_rest" ]]; do
        if [[ "$_ecv_rest" == \$\$* ]]; then
            _ecv_out+='$'
            _ecv_rest="${_ecv_rest:2}"
            continue
        fi

        if [[ "$_ecv_rest" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)(:-)([^}]*)\} ]]; then
            _ecv_def="${BASH_REMATCH[3]}"
            _ecv_match="${BASH_REMATCH[0]}"
            EnvGet "${BASH_REMATCH[1]}"
            [[ -n "$ENV_GOT" ]] || ENV_GOT="$_ecv_def"
            _ecv_out+="$ENV_GOT"
            _ecv_rest="${_ecv_rest:${#_ecv_match}}"
            continue
        fi

        if [[ "$_ecv_rest" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)-([^}]*)\} ]]; then
            _ecv_def="${BASH_REMATCH[2]}"
            _ecv_match="${BASH_REMATCH[0]}"
            if EnvGet "${BASH_REMATCH[1]}"; then
                _ecv_out+="$ENV_GOT"
            else
                _ecv_out+="$_ecv_def"
            fi
            _ecv_rest="${_ecv_rest:${#_ecv_match}}"
            continue
        fi

        if [[ "$_ecv_rest" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\} ]] || [[ "$_ecv_rest" =~ ^\$([A-Za-z_][A-Za-z0-9_]*) ]]; then
            _ecv_match="${BASH_REMATCH[0]}"
            EnvGet "${BASH_REMATCH[1]}"
            _ecv_out+="$ENV_GOT"
            _ecv_rest="${_ecv_rest:${#_ecv_match}}"
            continue
        fi

        _ecv_out+="${_ecv_rest:0:1}"
        _ecv_rest="${_ecv_rest:1}"
    done

    EXPANDED="$_ecv_out"
}

ParseImageStream() {
    local line val
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line//$'\r'/}"
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*image:[[:space:]]*(.*)$ ]] || continue
        val="$(CleanImageRef "${BASH_REMATCH[1]}")"
        printf '%s\n' "$val"
    done
}

ExtractImageRefs() {
    ParseImageStream < "$1"
}

FileUsesExtends() {
    grep -Eq '^[[:space:]]*extends:' "$1"
}

ComposeConfigImages() {
    local file="$1"
    local output status err line
    err="$(mktemp)" || return 1

    output="$(RunOneCompose "$file" config --images 2>"$err")"
    status=$?
    if [ "$status" -eq 0 ]; then
        rm -f "$err"
        while IFS= read -r line || [ -n "$line" ]; do
            line="$(CleanImageRef "$line")"
            [ -n "$line" ] && printf '%s\n' "$line"
        done <<< "$output"
        return 0
    fi

    output="$(RunOneCompose "$file" config 2>"$err")"
    status=$?
    if [ "$status" -eq 0 ]; then
        rm -f "$err"
        printf '%s\n' "$output" | ParseImageStream
        return 0
    fi

    rm -f "$err"
    return 1
}

GetFileImages() {
    local file="$1"
    local -a refs=()
    local -A seen=()
    local img exp resolved line
    local unresolved=0
    local tried=0
    local ok=0
    local before=0
    local warn=0

    while IFS= read -r img || [ -n "$img" ]; do
        if [ -z "$img" ]; then
            unresolved=$((unresolved+1))
            continue
        fi
        ExpandComposeInto "$img"
        exp="$EXPANDED"
        case "$exp" in
            ""|~|null|Null|NULL) unresolved=$((unresolved+1)) ; continue ;;
        esac
        if ImageRefUnresolved "$exp"; then
            unresolved=$((unresolved+1))
            continue
        fi
        if [ -z "${seen[$exp]+x}" ]; then
            seen["$exp"]=1
            refs+=("$exp")
        fi
    done < <(ExtractImageRefs "$file")

    before=${#refs[@]}
    if [ "$unresolved" -gt 0 ] || FileUsesExtends "$file"; then
        tried=1
        if resolved="$(ComposeConfigImages "$file")"; then
            ok=1
            while IFS= read -r line || [ -n "$line" ]; do
                [ -z "$line" ] && continue
                if ImageRefUnresolved "$line"; then
                    continue
                fi
                case "$line" in
                    ""|~|null|Null|NULL) continue ;;
                esac
                if [ -z "${seen[$line]+x}" ]; then
                    seen["$line"]=1
                    refs+=("$line")
                fi
            done <<< "$resolved"
        fi
    fi

    if [ "$tried" -eq 1 ] && [ "$ok" -eq 0 ]; then
        warn=1
    fi
    if [ "$unresolved" -gt 0 ] && [ "${#refs[@]}" -le "$before" ]; then
        warn=1
    fi
    if [ "$warn" -eq 1 ]; then
        Say warn "Could not resolve every image in $(basename "$(dirname "$file")")/$(basename "$file")"
    fi

    if [ ${#refs[@]} -gt 0 ]; then
        printf '%s\n' "${refs[@]}"
    fi
}

NormalizeImageRef() {
    local ref="$1"
    ref="${ref#index.docker.io/}"
    ref="${ref#docker.io/}"
    if [[ "$ref" == library/* && "${ref#library/}" != */* ]]; then
        ref="${ref#library/}"
    fi
    if [[ "$ref" != *@* ]]; then
        local repo="${ref##*/}"
        if [[ "$repo" != *:* ]]; then
            ref="${ref}:latest"
        fi
    fi
    printf '%s' "$ref"
}

DigestListHas() {
    local list="$1"
    local needle="$2"
    [[ -n "$needle" && " $list " == *" $needle "* ]]
}

AddLocalDigest() {
    local key="$1"
    local digest="$2"
    local current="${LOCAL_IMAGE_DIGESTS[$key]:-}"
    DigestListHas "$current" "$digest" && return 0
    if [[ -n "$current" ]]; then
        LOCAL_IMAGE_DIGESTS["$key"]="$current $digest"
    else
        LOCAL_IMAGE_DIGESTS["$key"]="$digest"
    fi
}

RecordImageDigestLine() {
    local line="$1"
    local tags_json digests_json tag_item digest_item digest key
    [[ "$line" == *$'\t'* ]] || return 0
    tags_json="${line%%$'\t'*}"
    digests_json="${line#*$'\t'}"
    [[ -z "$tags_json" || "$tags_json" == "[]" || "$tags_json" == "null" ]] && return 0
    [[ -z "$digests_json" || "$digests_json" == "[]" || "$digests_json" == "null" ]] && return 0
    while IFS= read -r tag_item; do
        [[ -z "$tag_item" ]] && continue
        key="$(NormalizeImageRef "$tag_item")"
        while IFS= read -r digest_item; do
            digest="${digest_item#*@}"
            [[ "$digest" == sha256:* ]] || continue
            AddLocalDigest "$key" "$digest"
        done < <(printf '%s\n' "$digests_json" | grep -oE '"[^"]*"' | sed 's/^"//;s/"$//')
    done < <(printf '%s\n' "$tags_json" | grep -oE '"[^"]*"' | sed 's/^"//;s/"$//')
}

LoadLocalDigests() {
    local id line
    local -a ids=()
    local -A seen_ids=()
    unset LOCAL_IMAGE_DIGESTS
    declare -gA LOCAL_IMAGE_DIGESTS=()
    while IFS= read -r id; do
        [[ -z "$id" || -n "${seen_ids[$id]:-}" ]] && continue
        seen_ids["$id"]=1
        ids+=("$id")
    done < <(docker image ls -q --no-trunc 2>/dev/null || true)
    [[ ${#ids[@]} -eq 0 ]] && return 0
    while IFS= read -r line; do
        RecordImageDigestLine "$line"
    done < <(docker image inspect --format '{{json .RepoTags}}{{"\t"}}{{json .RepoDigests}}' "${ids[@]}" 2>/dev/null || true)
}

ParseRemoteDigestLines() {
    local line digest
    local -A seen=()
    while IFS= read -r line; do
        digest=""
        if [[ "$line" =~ ^[[:space:]]*Digest:[[:space:]]*(sha256:[a-f0-9]{64}) ]]; then
            digest="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ @sha256:([a-f0-9]{64}) ]]; then
            digest="sha256:${BASH_REMATCH[1]}"
        fi
        if [[ -n "$digest" && -z "${seen[$digest]:-}" ]]; then
            seen["$digest"]=1
            printf '%s\n' "$digest"
        fi
    done
}

RemoteManifestDigests() {
    local ref="$1"
    local out parsed="" err=""
    if out="$(docker buildx imagetools inspect "$ref" 2>&1)"; then
        parsed="$(printf '%s\n' "$out" | ParseRemoteDigestLines)"
    else
        err="$out"
    fi
    if [[ -z "$parsed" ]]; then
        if out="$(docker manifest inspect --verbose "$ref" 2>&1)"; then
            parsed="$(printf '%s\n' "$out" | ParseRemoteDigestLines)"
        else
            err="${err}"$'\n'"${out}"
        fi
    fi
    if [[ -n "$parsed" ]]; then
        printf '%s\n' "$parsed"
        return 0
    fi
    if [[ "$err" == *"not found"* || "$err" == *"manifest unknown"* || "$err" == *"no such manifest"* ]]; then
        return 2
    fi
    return 1
}

ImageNeedsPull() {
    local ref="$1"
    local key digest remote remotes remote_status=0
    if [[ "$ref" == *@sha256:* ]]; then
        digest="${ref##*@}"
        for key in "${!LOCAL_IMAGE_DIGESTS[@]}"; do
            DigestListHas "${LOCAL_IMAGE_DIGESTS[$key]}" "$digest" && return 1
        done
        docker image inspect "$digest" &>/dev/null && return 1
        return 0
    fi
    key="$(NormalizeImageRef "$ref")"
    digest="${LOCAL_IMAGE_DIGESTS[$key]:-}"
    if [[ -z "$digest" ]]; then
        return 0
    fi
    remotes="$(RemoteManifestDigests "$ref")" || remote_status=$?
    if [[ "$remote_status" -eq 2 ]]; then
        return 2
    fi
    if [[ "$remote_status" -ne 0 || -z "$remotes" ]]; then
        return 0
    fi
    while IFS= read -r remote; do
        [[ -n "$remote" ]] && DigestListHas "$digest" "$remote" && return 1
    done <<< "$remotes"
    return 0
}

PrintMissingTags() {
    local ref missing=0
    for ref in "$@"; do
        if [ "$(ImageTag "$ref")" = "-" ]; then
            missing=$((missing+1))
        fi
    done
    if [ "$missing" -gt 0 ]; then
        Say warn "${missing} image(s) have no tag and will pull as latest."
    fi
}

PrintImageRow() {
    local state="$1" path="$2" path_w="$3" tag="$4" tag_w="$5" img="$6"
    local mark color tag_color
    if [[ "$state" == "Enabled" ]]; then
        mark="✔"
        color="$c_green"
    else
        mark="✘"
        color="$c_red"
    fi
    tag_color="$c_dim"
    [[ "$tag" == "-" ]] && tag_color="$c_yellow"
    printf "  %b%s%b  %-*s  %b│%b  %b%-*s%b  %b│%b  %s\n" \
        "$color" "$mark" "$c_reset" \
        "$path_w" "$path" \
        "$c_dim" "$c_reset" \
        "$tag_color" "$tag_w" "$tag" "$c_reset" \
        "$c_dim" "$c_reset" \
        "$img"
}

ShowImages() {
    local mode="$1"
    local -a pull_refs=()
    local -a enabled_refs=()
    local -a disabled_refs=()
    local -a disabled_only_refs=()
    local -a chosen_refs=()
    local -A seen_pull=()
    local -A seen_enabled=()
    local -A seen_disabled=()
    local -A seen_row=()
    local count=0
    local found_file=0
    local failed=0
    local index=1
    local total=0
    local dir path path_lc state file img tag row_key
    local -a disp_path=() disp_state=() disp_tag=() disp_img=()
    local tag_width i
    local answer img_ref include_disabled=0 pull_enabled=0 arg title

    for arg in "${EXTRA_ARGS[@]}"; do
        case "$arg" in
            --pull) mode="pull" ;;
            -*)
                Say bad "Images takes an optional service and --pull."
                Say info "dc images plex"
                Say info "dc images plex --pull"
                exit 1
                ;;
            *)
                if [[ -n "${folder:-}" ]]; then
                    Say bad "Images takes one service."
                    exit 1
                fi
                folder="${arg,,}"
                ;;
        esac
    done
    title="images"
    [[ "$mode" == "pull" ]] && title="images pull"
    if [ -n "$folder" ] && [ "$folder" != "all" ]; then
        Banner "$title $folder"
    else
        Banner "$title"
    fi

    while IFS= read -r dir; do
        path="$(basename "$dir")"
        path_lc="${path,,}"
        if [ -n "$folder" ] && [ "$folder" != "all" ] && [ "$path_lc" != "$folder" ]; then
            continue
        fi

        for state in Enabled Disabled; do
            if [ "$state" = "Enabled" ]; then
                file="${dir}${COMPOSE_FILE}"
            else
                file="${dir}${COMPOSE_FILE_DISABLED}"
            fi
            [ -f "$file" ] || continue
            found_file=1

            while IFS= read -r img; do
                [ -z "$img" ] && continue
                row_key="${path}|${state}|${img}"
                if [ -n "${seen_row[$row_key]+x}" ]; then
                    continue
                fi
                seen_row["$row_key"]=1
                tag="$(ImageTag "$img")"
                disp_path+=("$path")
                disp_state+=("$state")
                disp_tag+=("$tag")
                disp_img+=("$img")
                count=$((count+1))
                if [ -z "${seen_pull[$img]+x}" ]; then
                    seen_pull["$img"]=1
                    pull_refs+=("$img")
                fi
                if [ "$state" = "Enabled" ]; then
                    if [ -z "${seen_enabled[$img]+x}" ]; then
                        seen_enabled["$img"]=1
                        enabled_refs+=("$img")
                    fi
                elif [ -z "${seen_disabled[$img]+x}" ]; then
                    seen_disabled["$img"]=1
                    disabled_refs+=("$img")
                fi
            done < <(GetFileImages "$file")
        done
    done < <(ServiceDirs)

    if [ -n "$folder" ] && [ "$folder" != "all" ] && [ "$found_file" -eq 0 ]; then
        Say bad "Service does not exist."
        exit 1
    fi

    for img_ref in "${disabled_refs[@]}"; do
        if [ -z "${seen_enabled[$img_ref]+x}" ]; then
            disabled_only_refs+=("$img_ref")
        fi
    done

    if [[ "$count" -gt 0 ]]; then
        local svc_width
        local -a en_idx=() dis_idx=()
        local idx
        svc_width="$(ColumnWidth 7 "${disp_path[@]}")"
        tag_width="$(ColumnWidth 3 "${disp_tag[@]}")"
        printf "%b     %-*s  │  %-*s  │  %s%b\n" "$c_dim" \
            "$svc_width" "service" "$tag_width" "tag" "image" "$c_reset"
        for i in "${!disp_path[@]}"; do
            if [[ "${disp_state[$i]}" == "Enabled" ]]; then
                en_idx+=("$i")
            else
                dis_idx+=("$i")
            fi
        done
        for idx in "${en_idx[@]}"; do
            PrintImageRow "${disp_state[$idx]}" "${disp_path[$idx]}" "$svc_width" "${disp_tag[$idx]}" "$tag_width" "${disp_img[$idx]}"
        done
        if [[ ${#en_idx[@]} -gt 0 && ${#dis_idx[@]} -gt 0 ]]; then
            printf "\n  %bdisabled%b\n" "$c_dim" "$c_reset"
        fi
        for idx in "${dis_idx[@]}"; do
            PrintImageRow "${disp_state[$idx]}" "${disp_path[$idx]}" "$svc_width" "${disp_tag[$idx]}" "$tag_width" "${disp_img[$idx]}"
        done
    fi

    printf "\n"
    Say info "${count} listed · ${#pull_refs[@]} unique."
    if [ ${#disabled_only_refs[@]} -gt 0 ]; then
        Say warn "${#disabled_only_refs[@]} image(s) are only used by disabled services."
    fi

    if [ "$mode" != "pull" ]; then
        PrintMissingTags "${pull_refs[@]}"
        return 0
    fi

    if [ ${#enabled_refs[@]} -eq 0 ] && [ ${#disabled_only_refs[@]} -eq 0 ]; then
        Say info "No images to pull."
        return 0
    fi

    if NonInteractive; then
        if [ ${#enabled_refs[@]} -gt 0 ]; then
            pull_enabled=1
        fi
        Say info "Non-interactive: pulling enabled service images only."
    else
        if [ ${#enabled_refs[@]} -gt 0 ]; then
            if [ -n "$folder" ]; then
                pull_enabled=1
            else
                answer="$(Ask "Pull ${#enabled_refs[@]} unique image(s) from enabled services? [Y/n]")"
                if [[ -z "$answer" || "$answer" == [yY] ]]; then
                    pull_enabled=1
                fi
            fi
        fi

        if [ ${#disabled_only_refs[@]} -gt 0 ]; then
            if [ "$pull_enabled" -eq 1 ]; then
                answer="$(Ask "Also pull ${#disabled_only_refs[@]} image(s) from disabled services? [y/N]")"
            else
                answer="$(Ask "Pull ${#disabled_only_refs[@]} image(s) from disabled services? [y/N]")"
            fi
            if [[ "$answer" == [yY] ]]; then
                include_disabled=1
            fi
        fi
    fi

    if [ "$pull_enabled" -eq 1 ]; then
        chosen_refs=("${enabled_refs[@]}")
    fi
    if [ "$include_disabled" -eq 1 ]; then
        for img_ref in "${disabled_only_refs[@]}"; do
            chosen_refs+=("$img_ref")
        done
    fi

    if [ ${#chosen_refs[@]} -eq 0 ]; then
        Say info "No images to pull."
        return 0
    fi

    PrintMissingTags "${chosen_refs[@]}"

    if ! command -v docker >/dev/null 2>&1; then
        Say bad "docker is not available, cannot pull images."
        exit 1
    fi

    local -a stale_refs=()
    local -a missing_refs=()
    local -a check_pids=()
    local status_dir current_count stale_count missing_count max_checks=8
    local check_i result_line pull_status

    Say info "Checking ${#chosen_refs[@]} image(s) against the registry."
    LoadLocalDigests
    status_dir="$(mktemp -d)"
    check_i=0
    for img_ref in "${chosen_refs[@]}"; do
        if [[ -t 1 ]]; then
            printf "\r\033[K  %b·%b  %d/%d" "$c_teal" "$c_reset" "$((check_i+1))" "${#chosen_refs[@]}"
        fi
        printf '%s\n' "$img_ref" > "$status_dir/$check_i.ref"
        (
            ImageNeedsPull "$img_ref"
            pull_status=$?
            if [[ "$pull_status" -eq 1 ]]; then
                echo current > "$status_dir/$check_i.result"
            elif [[ "$pull_status" -eq 2 ]]; then
                echo missing > "$status_dir/$check_i.result"
            else
                echo pull > "$status_dir/$check_i.result"
            fi
        ) &
        check_pids+=("$!")
        if [[ ${#check_pids[@]} -ge $max_checks ]]; then
            wait "${check_pids[0]}" || true
            check_pids=("${check_pids[@]:1}")
        fi
        check_i=$((check_i+1))
    done
    for check_i in "${check_pids[@]}"; do
        wait "$check_i" || true
    done

    current_count=0
    stale_count=0
    missing_count=0
    check_i=0
    for img_ref in "${chosen_refs[@]}"; do
        result_line="$(cat "$status_dir/$check_i.result" 2>/dev/null || echo pull)"
        if [[ "$result_line" == "current" ]]; then
            current_count=$((current_count+1))
        elif [[ "$result_line" == "missing" ]]; then
            missing_refs+=("$img_ref")
            missing_count=$((missing_count+1))
        else
            stale_refs+=("$img_ref")
            stale_count=$((stale_count+1))
        fi
        check_i=$((check_i+1))
    done
    rm -rf "$status_dir"
    [[ -t 1 ]] && printf "\r\033[K"

    Say ok "${current_count} image(s) already match the registry."
    if [[ "$missing_count" -gt 0 ]]; then
        Say warn "${missing_count} image(s) stay on disk because that tag is no longer on the registry:"
        for img_ref in "${missing_refs[@]}"; do
            printf "  %b·%b  %s\n" "$c_yellow" "$c_reset" "$img_ref"
        done
    fi
    if [[ "$stale_count" -eq 0 ]]; then
        Say ok "Nothing to pull."
        return 0
    fi
    Say warn "${stale_count} image(s) have updates:"
    for img_ref in "${stale_refs[@]}"; do
        printf "  %b↓%b  %s\n" "$c_yellow" "$c_reset" "$img_ref"
    done

    total=$stale_count
    index=1
    for img_ref in "${stale_refs[@]}"; do
        printf "  %b↓%b  %3d/%-3d  %s\n" "$c_yellow" "$c_reset" "$index" "$total" "$img_ref"
        if ! docker pull "$img_ref"; then
            Say bad "Failed to pull $img_ref"
            failed=$((failed+1))
        fi
        index=$((index+1))
    done

    if [ "$failed" -gt 0 ]; then
        Say bad "$failed image(s) failed to pull."
        exit 1
    fi
    Say ok "Pulled ${total} image(s)."
}

Key() {
    local ssh_dir priv="" pub host name comment created=0 shown import_cmd copy_cmd quoted answer
    Banner "host add"
    if [[ -z "${HOME:-}" ]]; then
        Say bad "HOME is not set."
        exit 1
    fi
    host="${EXTRA_ARGS[0]:-}"
    if [[ -z "$host" && -n "${folder:-}" ]]; then
        host="$folder"
    fi
    if [[ ${#EXTRA_ARGS[@]} -gt 1 ]] || { [[ -n "$host" ]] && ! MoveHostOk "$host"; }; then
        Say bad "Host add takes an optional host."
        Say info "dc host add"
        Say info "dc host add root@other-host"
        exit 1
    fi
    if [[ -n "$host" ]]; then
        RememberHost "$host" || Say warn "Could not remember a short name for $host."
    fi
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        Say bad "ssh-keygen is required."
        exit 1
    fi
    ssh_dir="$HOME/.ssh"
    for name in id_ed25519 id_ecdsa id_rsa; do
        if [[ -f "$ssh_dir/$name" ]]; then
            priv="$ssh_dir/$name"
            break
        fi
    done
    if [[ -z "$priv" ]]; then
        if [[ -e "$ssh_dir/id_ed25519.pub" ]]; then
            Say bad "A public key exists without its private key."
            exit 1
        fi
        mkdir -p "$ssh_dir" || exit 1
        chmod 700 "$ssh_dir" || exit 1
        comment="compose@$(hostname 2>/dev/null || printf 'compose')"
        if ! ssh-keygen -q -t ed25519 -f "$ssh_dir/id_ed25519" -N "" -C "$comment" </dev/null; then
            Say bad "Could not create the key."
            exit 1
        fi
        priv="$ssh_dir/id_ed25519"
        created=1
    fi
    if [[ ! -s "$priv.pub" ]]; then
        if ! ssh-keygen -y -P "" -f "$priv" >"$priv.pub" 2>/dev/null </dev/null; then
            Say bad "No public key next to $priv."
            exit 1
        fi
        chmod 644 "$priv.pub" || exit 1
    fi
    IFS= read -r pub <"$priv.pub" || exit 1
    pub="${pub//$'\r'/}"
    if [[ ! "$pub" =~ ^ssh-(ed25519|rsa|ecdsa)[[:space:]]+[A-Za-z0-9+/=]+ ]]; then
        Say bad "Public key looks wrong."
        exit 1
    fi
    if [[ "$priv" == "$HOME/"* ]]; then
        shown="~/${priv#"$HOME/"}"
    else
        shown="$priv"
    fi
    if [[ "$created" -eq 1 ]]; then
        Say ok "Created $shown."
        Say info "Passphrase is empty, so dc move can use it."
    else
        Say ok "Using $shown."
        if ! ssh-keygen -y -P "" -f "$priv" >/dev/null 2>&1 </dev/null; then
            Say warn "This key has a passphrase. Run ssh-add $shown before dc move."
        fi
    fi
    if [[ "$pub" == *"'"* || "$pub" == *\\* ]]; then
        printf -v quoted '%q' "$pub"
        import_cmd="mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '%s\\n' ${quoted} >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    else
        import_cmd="mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '%s\\n' '${pub}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    fi
    if [[ -z "$host" ]]; then
        printf -v copy_cmd 'ssh-copy-id -i %q user@other-host' "$priv.pub"
        Say info "On the other host, run:"
        printf '\n%s\n\n' "$import_cmd"
        Say info "From this host, confirm the host once and enter the password once:"
        printf '\n%s\n\n' "$copy_cmd"
        return 0
    fi
    if ! command -v ssh-copy-id >/dev/null 2>&1; then
        Say warn "ssh-copy-id is not installed."
        Say info "On the other host, run:"
        printf '\n%s\n\n' "$import_cmd"
        return 0
    fi
    answer="$(Ask "Install this key on $host? [y/N]")"
    if [[ "$answer" != [yY] ]]; then
        Say info "Leaving $host unchanged."
        Say info "On the other host, run:"
        printf '\n%s\n\n' "$import_cmd"
        return 0
    fi
    if ! ssh-copy-id -i "$priv.pub" "$host"; then
        Say bad "Could not install the key on $host."
        Say info "On the other host, run:"
        printf '\n%s\n\n' "$import_cmd"
        exit 1
    fi
    if ! ssh -T -o BatchMode=yes -o ConnectTimeout=20 -o GSSAPIAuthentication=no -o PreferredAuthentications=publickey "$host" true; then
        Say bad "dc move cannot connect to $host yet."
        exit 1
    fi
    Say ok "$host accepts this key. dc move can connect."
}

# Host add [user@host] | Host list
Host() {
    local sub="${EXTRA_ARGS[0]:-list}"
    case "$sub" in
        add)
            EXTRA_ARGS=("${EXTRA_ARGS[@]:1}")
            Key
            ;;
        list)
            if [[ ${#EXTRA_ARGS[@]} -gt 1 ]]; then
                Say bad "Host list takes no arguments."
                exit 1
            fi
            Hosts
            ;;
        *)
            Say bad "Use host add or host list."
            Say info "dc host add root@other-host"
            Say info "dc host list"
            exit 1
            ;;
    esac
}

Setup() {
    case "${EXTRA_ARGS[0]:-bashrc}" in
        bashrc) PrintBashrc ;;
        *)
            Say bad "Use setup or setup bashrc."
            Say info "dc setup"
            exit 1
            ;;
    esac
}

BashrcSourceLine() {
    printf 'source %q\n' "$SCRIPT_WORKING_DIR/dc.bash"
}

BashrcHasSource() {
    local file="$1" line="$2" want raw path
    want="${line#source }"
    [[ -f "$file" ]] || return 1
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        raw="${raw%$'\r'}"
        raw="${raw#"${raw%%[![:space:]]*}"}"
        raw="${raw%"${raw##*[![:space:]]}"}"
        [[ -z "$raw" || "$raw" == \#* ]] && continue
        [[ "$raw" == "$line" ]] && return 0
        case "$raw" in
            source\ *|.\ *)
                path="${raw#source }"
                [[ "$raw" == .\ * ]] && path="${raw#. }"
                path="${path#"${path%%[![:space:]]*}"}"
                if [[ "$path" == \"*\" && "$path" == *\" ]]; then
                    path="${path:1:${#path}-2}"
                elif [[ "$path" == \'*\' && "$path" == *\' ]]; then
                    path="${path:1:${#path}-2}"
                fi
                [[ "$path" == "$SCRIPT_WORKING_DIR/dc.bash" || "$path" == "$want" ]] && return 0
                ;;
        esac
    done < "$file"
    return 1
}

ScheduleAllowed() {
    [[ -n "$1" ]] && ActionHasFlag "$1" j && [[ "$ACT_FLAGS" != *h* ]]
}

# ScheduleMarker <action> [options...]
ScheduleMarker() {
    local IFS=' '
    printf 'compose-schedule:%s' "$*"
}

# Sets SCHED_ACTION and SCHED_OPTS from a managed crontab line. Exit 1 otherwise.
ScheduleParseLine() {
    local tail
    SCHED_ACTION="" SCHED_OPTS=""
    [[ "$1" == *" # compose-schedule:"* ]] || return 1
    tail="${1##* # compose-schedule:}"
    tail="${tail%"${tail##*[![:space:]]}"}"
    SCHED_ACTION="${tail%% *}"
    [[ "$tail" == *" "* ]] && SCHED_OPTS="${tail#* }"
    [[ -n "$SCHED_ACTION" ]]
}

# Old action name → "new_action option". Exit 1 when not renamed.
# Schedules use it to rewrite crontab lines; dispatch uses it to point at the new name.
ActionRenamed() {
    case "$1" in
        pull) printf 'images --pull' ;;
        hosts) printf 'host list' ;;
        version) printf 'update --check' ;;
        repull) printf 'update --force' ;;
        restore) printf 'tidy --undo' ;;
        key) printf 'host add' ;;
        bashrc) printf 'setup' ;;
        *) return 1 ;;
    esac
}

ScheduleLogDir() {
    printf '%s/.logs' "$SCRIPT_WORKING_DIR"
}

ScheduleLogFile() {
    printf '%s/schedule-%s.log' "$(ScheduleLogDir)" "$1"
}

# Prints the log path a crontab line appends to (">>'path'"). Exit 1 if none.
ScheduleLineLog() {
    local log="$1"
    [[ "$log" == *" >>'"*"' 2>&1"* ]] || return 1
    log="${log#* >>\'}"
    log="${log%%\' 2>&1*}"
    log="${log//\'\\\'\'/\'}"
    printf '%s' "$log"
}

# Offers to point jobs that still log to the old logs/ folder at .logs/, and moves their files.
ScheduleMoveLogs() {
    local line old_dir new_dir old_q new_q answer changed=0 f
    local -a lines=() out=()
    old_dir="$SCRIPT_WORKING_DIR/logs"
    new_dir="$(ScheduleLogDir)"
    old_q=">>$(CronQuote "$old_dir/schedule-")"
    old_q="${old_q%\'}"
    new_q=">>$(CronQuote "$new_dir/schedule-")"
    new_q="${new_q%\'}"
    while IFS= read -r line || [[ -n "$line" ]]; do
        lines+=("$line")
        [[ "$line" == *" # compose-schedule:"* && "$line" == *"$old_q"* ]] && changed=$((changed + 1))
    done < <(ReadCrontab)
    [[ "$changed" -gt 0 ]] || return 0
    Say warn "$changed schedule(s) still log to $old_dir."
    answer="$(Ask "Move them to $new_dir? [y/N]")"
    if [[ "$answer" != [yY] ]]; then
        Say info "Left those logs in $old_dir."
        return 0
    fi
    mkdir -p "$new_dir" || {
        Say bad "Could not create $new_dir."
        return 1
    }
    for line in "${lines[@]}"; do
        if [[ "$line" == *" # compose-schedule:"* ]]; then
            line="${line/"$old_q"/"$new_q"}"
        fi
        out+=("$line")
    done
    if ! printf '%s\n' "${out[@]}" | WriteCrontab; then
        Say bad "Could not update crontab."
        exit 1
    fi
    for f in "$old_dir"/schedule-*.log; do
        [[ -f "$f" ]] || continue
        if [[ -e "$new_dir/${f##*/}" ]]; then
            cat "$f" >>"$new_dir/${f##*/}" && rm -f "$f"
        else
            mv -- "$f" "$new_dir/"
        fi
    done
    rmdir "$old_dir" 2>/dev/null || true
    Say ok "Moved $changed schedule log(s) to $new_dir."
}

CronQuote() {
    local s="$1"
    printf "'%s'" "${s//\'/\'\\\'\'}"
}

ScheduleCronExprOk() {
    local field
    [[ $# -eq 5 ]] || return 1
    for field in "$@"; do
        [[ "$field" =~ ^[0-9A-Za-z*/,-]+$ ]] || return 1
    done
    return 0
}

ReadCrontab() {
    crontab -l 2>/dev/null || true
}

WriteCrontab() {
    local tmp
    tmp="$(mktemp)" || return 1
    cat >"$tmp" || {
        rm -f "$tmp"
        return 1
    }
    crontab "$tmp"
    local status=$?
    rm -f "$tmp"
    return "$status"
}

# ScheduleLine <action> <option count> [options...] <five cron fields>
ScheduleLine() {
    local action="$1" nopts="$2"
    shift 2
    local -a opts=("${@:1:$nopts}")
    shift "$nopts"
    local expr="$*"
    local bash_bin log marker opt opt_part=""
    bash_bin="$(command -v bash)"
    [[ -n "$bash_bin" ]] || bash_bin="/bin/bash"
    log="$(ScheduleLogFile "$action")"
    marker="$(ScheduleMarker "$action" "${opts[@]}")"
    if [[ ${#opts[@]} -gt 0 ]]; then
        opt_part=" --"
        for opt in "${opts[@]}"; do
            opt_part+=" $(CronQuote "$opt")"
        done
    fi
    printf '%s cd %s && COMPOSE_NONINTERACTIVE=1 %s %s -e %s -a %s%s >>%s 2>&1 # %s\n' \
        "$expr" \
        "$(CronQuote "$SCRIPT_WORKING_DIR")" \
        "$(CronQuote "$bash_bin")" \
        "$(CronQuote "$SCRIPT_PATH")" \
        "$(CronQuote "$envFile")" \
        "$(CronQuote "$action")" \
        "$opt_part" \
        "$(CronQuote "$log")" \
        "$marker"
}

# Rewrites one old-name crontab line to its new action. Prints the new line.
ScheduleRewriteLine() {
    local line="$1" old="$2" new_action="$3" new_opt="$4" out
    out="${line/" -a $(CronQuote "$old") "/" -a $(CronQuote "$new_action") -- $(CronQuote "$new_opt") "}"
    [[ "$out" != "$line" ]] || return 1
    out="${out/"/schedule-$old.log"/"/schedule-$new_action.log"}"
    out="${out% # compose-schedule:*} # $(ScheduleMarker "$new_action" "$new_opt")"
    printf '%s\n' "$out"
}

# Offers to rewrite crontab lines that still use renamed actions.
ScheduleMigrate() {
    local line renamed new_action new_opt answer changed=0 new_line
    local -a lines=() stale=() targets=()
    local -A taken=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        lines+=("$line")
        ScheduleParseLine "$line" && taken["$SCHED_ACTION"]=1
    done < <(ReadCrontab)
    for line in "${lines[@]}"; do
        ScheduleParseLine "$line" || continue
        ScheduleAllowed "$SCHED_ACTION" && continue
        if renamed="$(ActionRenamed "$SCHED_ACTION")"; then
            new_action="${renamed%% *}"
            if [[ -n "${taken[$new_action]+x}" ]]; then
                Say warn "$SCHED_ACTION is now $renamed, and $new_action is already scheduled."
                Say info "dc schedule remove $SCHED_ACTION"
                continue
            fi
            stale+=("$SCHED_ACTION")
            targets+=("$renamed")
            Say warn "$SCHED_ACTION is now $renamed."
        else
            Say warn "$SCHED_ACTION is no longer an action."
            Say info "dc schedule remove $SCHED_ACTION"
        fi
    done
    [[ ${#stale[@]} -gt 0 ]] || return 0
    answer="$(Ask "Rewrite ${#stale[@]} old schedule(s) to the new names? [y/N]")"
    if [[ "$answer" != [yY] ]]; then
        Say info "Left crontab unchanged."
        return 0
    fi
    local -a out=()
    local i
    for line in "${lines[@]}"; do
        if ScheduleParseLine "$line"; then
            for i in "${!stale[@]}"; do
                [[ "$SCHED_ACTION" == "${stale[$i]}" ]] || continue
                new_action="${targets[$i]%% *}"
                new_opt="${targets[$i]#* }"
                if new_line="$(ScheduleRewriteLine "$line" "${stale[$i]}" "$new_action" "$new_opt")"; then
                    line="$new_line"
                    changed=$((changed + 1))
                else
                    Say warn "Could not rewrite the ${stale[$i]} line. Remove it and add it again."
                fi
                break
            done
        fi
        out+=("$line")
    done
    [[ "$changed" -gt 0 ]] || return 0
    if ! printf '%s\n' "${out[@]}" | WriteCrontab; then
        Say bad "Could not update crontab."
        exit 1
    fi
    Say ok "Rewrote $changed schedule(s)."
}

ScheduleList() {
    local line expr count=0 label log
    local -a lines=()
    while IFS= read -r line; do
        [[ "$line" == *" # compose-schedule:"* ]] || continue
        lines+=("$line")
    done < <(ReadCrontab)
    if [[ ${#lines[@]} -eq 0 ]]; then
        Say info "No scheduled actions."
        Say info "dc schedule add images --pull 0 4 '*' '*' '*'"
        return 0
    fi
    ScheduleMigrate
    ScheduleMoveLogs
    lines=()
    while IFS= read -r line; do
        [[ "$line" == *" # compose-schedule:"* ]] || continue
        lines+=("$line")
    done < <(ReadCrontab)
    for line in "${lines[@]}"; do
        ScheduleParseLine "$line" || continue
        label="$SCHED_ACTION"
        [[ -n "$SCHED_OPTS" ]] && label+=" $SCHED_OPTS"
        expr="${line%% cd *}"
        expr="${expr%"${expr##*[![:space:]]}"}"
        if ScheduleAllowed "$SCHED_ACTION"; then
            printf "  %b✔%b  %b%-16s%b  %s\n" "$c_green" "$c_reset" "$c_teal" "$label" "$c_reset" "$expr"
        else
            printf "  %b✘%b  %b%-16s%b  %s\n" "$c_red" "$c_reset" "$c_teal" "$label" "$c_reset" "$expr"
        fi
        if log="$(ScheduleLineLog "$line")"; then
            Say info "log $log"
        else
            Say info "log $(ScheduleLogFile "$SCHED_ACTION")"
        fi
        count=$((count + 1))
    done
    Say ok "$count scheduled action(s)."
}

# ScheduleAdd <action> [options...] <m> <h> <dom> <mon> <dow>
ScheduleAdd() {
    local action="${1:-}"
    [[ $# -gt 0 ]] && shift
    local expr line answer existing=0 opt label nopts renamed
    local -a keep=() opts=() fields=()

    if [[ -z "$action" ]] || ! ScheduleAllowed "$action"; then
        Say bad "Schedule needs an allowed action."
        if renamed="$(ActionRenamed "$action")"; then
            Say info "$action is now $renamed."
        fi
        Say info "$(ActionsWithFlag j)"
        Say info "dc schedule add images --pull 0 4 '*' '*' '*'"
        exit 1
    fi
    if [[ $# -lt 5 ]]; then
        Say bad "Cron needs five fields. Quote the stars so the shell keeps them."
        Say info "dc schedule add images --pull 0 4 '*' '*' '*'"
        exit 1
    fi
    nopts=$(( $# - 5 ))
    opts=("${@:1:$nopts}")
    fields=("${@:$((nopts + 1))}")
    for opt in "${opts[@]}"; do
        if ! ActionHasOption "$action" "$opt"; then
            ActionLookup "$action"
            Say bad "$action does not take $opt."
            if [[ -n "$ACT_OPTS" ]]; then
                Say info "$action takes: $ACT_OPTS"
            else
                Say info "$action takes no options."
            fi
            exit 1
        fi
    done
    if ! ScheduleCronExprOk "${fields[@]}"; then
        Say bad "Cron needs five fields. Quote the stars so the shell keeps them."
        Say info "dc schedule add images --pull 0 4 '*' '*' '*'"
        exit 1
    fi
    expr="${fields[*]}"
    label="$action"
    [[ ${#opts[@]} -gt 0 ]] && label+=" ${opts[*]}"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if ScheduleParseLine "$line" && [[ "$SCHED_ACTION" == "$action" ]]; then
            existing=1
            continue
        fi
        keep+=("$line")
    done < <(ReadCrontab)
    if [[ "$existing" -eq 1 ]]; then
        answer="$(Ask "Replace schedule for $action with $label at '$expr'? [y/N]")"
        if [[ "$answer" != [yY] ]]; then
            Say info "Left crontab unchanged."
            return 0
        fi
    else
        answer="$(Ask "Schedule $label at '$expr'? [y/N]")"
        if [[ "$answer" != [yY] ]]; then
            Say info "Left crontab unchanged."
            return 0
        fi
    fi
    mkdir -p "$(ScheduleLogDir)" || {
        Say bad "Could not create $(ScheduleLogDir)."
        exit 1
    }
    keep+=("$(ScheduleLine "$action" "$nopts" "${opts[@]}" "${fields[@]}")")
    if ! printf '%s\n' "${keep[@]}" | WriteCrontab; then
        Say bad "Could not update crontab."
        exit 1
    fi
    Say ok "Scheduled $label: $expr"
    Say info "log $(ScheduleLogFile "$action")"
}

ScheduleRemove() {
    local action="$1" line found=0 answer
    local -a keep=()

    if [[ ! "$action" =~ ^[a-z0-9-]+$ ]]; then
        Say bad "Remove needs a scheduled action name."
        Say info "dc schedule remove images"
        exit 1
    fi
    while IFS= read -r line; do
        if ScheduleParseLine "$line" && [[ "$SCHED_ACTION" == "$action" ]]; then
            found=1
            continue
        fi
        keep+=("$line")
    done < <(ReadCrontab)
    if [[ "$found" -eq 0 ]]; then
        Say info "No schedule for $action."
        return 0
    fi
    answer="$(Ask "Remove schedule for $action? [y/N]")"
    if [[ "$answer" != [yY] ]]; then
        Say info "Left crontab unchanged."
        return 0
    fi
    if [[ ${#keep[@]} -eq 0 ]]; then
        if ! WriteCrontab </dev/null; then
            # empty crontab: crontab -r is clearer on some systems
            crontab -r 2>/dev/null || true
        fi
    else
        if ! printf '%s\n' "${keep[@]}" | WriteCrontab; then
            Say bad "Could not update crontab."
            exit 1
        fi
    fi
    Say ok "Removed schedule for $action."
}

Schedule() {
    local sub

    Banner "schedule"
    if ! command -v crontab >/dev/null 2>&1; then
        Say bad "crontab is required."
        exit 1
    fi
    sub="${EXTRA_ARGS[0]:-list}"
    case "$sub" in
        list|"")
            ScheduleList
            ;;
        add)
            ScheduleAdd "${EXTRA_ARGS[@]:1}"
            ;;
        remove|rm)
            if [[ ${#EXTRA_ARGS[@]} -ne 2 ]]; then
                Say bad "Remove needs one action."
                Say info "dc schedule remove images"
                exit 1
            fi
            ScheduleRemove "${EXTRA_ARGS[1]}"
            ;;
        *)
            Say bad "Use list, add, or remove."
            Say info "dc schedule"
            Say info "dc schedule add images --pull 0 4 '*' '*' '*'"
            Say info "dc schedule remove images"
            exit 1
            ;;
    esac
}

DocsFile() {
    printf '%s\n' "$SCRIPT_WORKING_DIR/DOCS.md"
}

DocsTopics() {
    local file topic
    file="$(DocsFile)"
    [[ -f "$file" ]] || return 0
    while IFS= read -r topic; do
        [[ -n "$topic" ]] && printf '%s\n' "$topic"
    done < <(grep -E '^### [a-z0-9]+$' "$file" | sed 's/^### //')
}

DocsShowSection() {
    local file="$1" topic="$2"
    local line in=0 found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "### $topic" ]]; then
            in=1
            found=1
            printf '%s\n' "$line"
            continue
        fi
        if [[ "$in" -eq 1 ]]; then
            if [[ "$line" =~ ^###\  || "$line" =~ ^##\  ]]; then
                break
            fi
            printf '%s\n' "$line"
        fi
    done < "$file"
    [[ "$found" -eq 1 ]]
}

DocsShowFile() {
    local file="$1"
    if command -v less >/dev/null 2>&1 && [[ -t 1 ]]; then
        less -R "$file"
        return
    fi
    if command -v more >/dev/null 2>&1 && [[ -t 1 ]]; then
        more "$file"
        return
    fi
    cat "$file"
}

Docs() {
    local file topic="${EXTRA_ARGS[0]:-}"
    if [[ -z "$topic" && -n "${folder:-}" && "$folder" != "all" ]]; then
        topic="$folder"
    fi
    if [[ ${#EXTRA_ARGS[@]} -gt 1 ]]; then
        Say bad "Docs takes an optional topic."
        Say info "dc docs"
        Say info "dc docs images"
        exit 1
    fi

    Banner "docs"
    file="$(DocsFile)"
    if [[ ! -f "$file" ]]; then
        Say bad "Documentation file not found: $file"
        Say info "Run dc update --force to download DOCS.md."
        exit 1
    fi
    if [[ -z "$topic" ]]; then
        Say info "Full reference: $file"
        Say info "dc docs images"
        DocsShowFile "$file"
        return 0
    fi
    topic="${topic,,}"
    if ! DocsShowSection "$file" "$topic"; then
        Say bad "No docs for: $topic"
        Say info "Topics:"
        DocsTopics | while IFS= read -r line; do
            printf "  %b·%b  %s\n" "$c_teal" "$c_reset" "$line"
        done
        exit 1
    fi
}

PrintBashrc() {
    local line file answer last
    line="$(BashrcSourceLine)"
    line="${line%$'\n'}"
    if [[ -z "${HOME:-}" ]]; then
        printf "  %b✘%b  HOME is not set.\n" "$c_red" "$c_reset" >&2
        printf '\n%s\n\n' "$line" >&2
        exit 1
    fi
    file="$HOME/.bashrc"
    if BashrcHasSource "$file" "$line"; then
        printf "  %b✔%b  Already in ~/.bashrc.\n" "$c_green" "$c_reset" >&2
        return 0
    fi
    printf "  %b·%b  This line is not in ~/.bashrc.\n" "$c_teal" "$c_reset" >&2
    printf '\n%s\n\n' "$line" >&2
    answer="$(Ask "Add it to ~/.bashrc? [y/N]")"
    if [[ "$answer" != [yY] ]]; then
        printf "  %b·%b  Left ~/.bashrc unchanged.\n" "$c_teal" "$c_reset" >&2
        return 0
    fi
    if [[ -e "$file" && ! -f "$file" ]]; then
        printf "  %b✘%b  ~/.bashrc is not a file.\n" "$c_red" "$c_reset" >&2
        exit 1
    fi
    if [[ -e "$file" && ! -w "$file" ]]; then
        printf "  %b✘%b  Cannot write ~/.bashrc.\n" "$c_red" "$c_reset" >&2
        exit 1
    fi
    {
        if [[ -s "$file" ]]; then
            last="$(tail -c 1 "$file" || true)"
            [[ "$last" == $'\n' ]] || printf '\n'
        fi
        printf '%s\n' "$line"
    } >>"$file" || {
        printf "  %b✘%b  Could not update ~/.bashrc.\n" "$c_red" "$c_reset" >&2
        exit 1
    }
    printf "  %b✔%b  Added the source line to ~/.bashrc.\n" "$c_green" "$c_reset" >&2
    printf "  %b·%b  Open a new shell to use dc.\n" "$c_teal" "$c_reset" >&2
}

# Do the Things
action_lc="${action:-}"
action_lc="${action_lc,,}"
# setup runs before .env exists on a new install. bashrc is its old name.
if [[ "$action_lc" == "setup" || "$action_lc" == "bashrc" ]]; then
    [[ "$action_lc" == "bashrc" ]] && Say warn "bashrc is now setup. The old name still works for now."
    if [[ "${folder,,}" == "bashrc" ]]; then
        EXTRA_ARGS=("bashrc" "${EXTRA_ARGS[@]}")
    fi
    Setup
    exit 0
fi
CheckEnv;
CheckEnvVariables;
if [[ "$action_lc" == "path" ]]; then
    Path
    exit 0
fi
WHERE_VAR=""
if [[ "$action_lc" == "where" ]]; then
    WHERE_VAR="${EXTRA_ARGS[0]:-}"
    if [[ -z "$WHERE_VAR" && -n "${folder:-}" && "${folder,,}" != "all" ]]; then
        WHERE_VAR="$folder"
    fi
fi
LowerCaseArguments;
if [[ "$action" == "receive" ]]; then
    Receive
    exit $?
fi
if ActionHasFlag "$action" d; then
    CheckDockerCompose
fi
CheckAction;

exit 0
