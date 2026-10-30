#!/bin/bash
VERSION=v1.7.36
### ChangeNotes: restore puts back the env file from tidy.
GITHUB="https://github.com/causefx/compose"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/causefx/compose/main"
GITHUB_RAWURL="$GITHUB_RAW_BASE/compose.sh"
SCRIPT_ARGS=( "$@" )
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_WORKING_DIR="$(dirname "$SCRIPT_PATH")"

LATEST_RELEASE=""
LATEST_CHANGES=""
EXTRA_ARGS=()
declare -A PROJECT_STATUS=()
PROJECT_STATUS_LOADED=0
declare -a CTR_SVC=() CTR_NAME=() CTR_STATUS=() CTR_PORTS=()

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

Ask() {
    local reply
    printf "  %b?%b  %s " "$c_teal" "$c_reset" "$1" >&2
    if [[ -r /dev/tty ]]; then
        IFS= read -r reply </dev/tty || reply=""
    else
        IFS= read -r reply || reply=""
    fi
    printf '%s' "$reply"
}

PaintStatus() {
    local text="$1"
    local color="$c_dim"
    local lower
    lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
        *unhealthy*|*restarting*|*paused*|*created*) color="$c_yellow" ;;
        up\ *|*running*|*healthy*) color="$c_green" ;;
        *exited*|*stopped*|*dead*) color="$c_red" ;;
    esac
    printf '%b%s%b' "$color" "$text" "$c_reset"
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

PadRight() {
    local text="$1"
    local width="$2"
    local gap=$(( width - ${#text} ))
    if (( gap > 0 )); then
        printf '%s%*s' "$text" "$gap" ""
    else
        printf '%s' "$text"
    fi
}

# Add an action here. Help, dispatch, and dc tab completion read this list.
# name|description|handler|compose args
ActionSpec() {
    cat <<'EOF'
# @actions
# @group Run
up|Create and start containers|compose|up -d
down|Stop and remove containers, networks|compose|down
start|Start service(s)|compose|start
stop|Stop service(s)|compose|stop
restart|Restart service container(s)|compose|restart
build|Build service image(s)|compose|build
pause|Pause service(s)|compose|pause
unpause|Unpause service(s)|compose|unpause
exec|Run a command in a service|exec
cp|Copy files to or from a service|cp
# @group Check
list|List service(s)|list
ps|Show container(s)|ps
issue|Show containers that need attention|issue
logs|Show service logs|logs
top|Show processes in a container|compose|top
stats|Show CPU, memory, and network|stats
images|List compose images and tags|images
pull|Pull images and skip ones already current|pull
config|Render compose file(s)|compose|config
ports|Show ports from ENV file|ports
nextport|Show the next free host port|nextport
df|Show Docker disk usage|df
prune|Remove unused Docker data|prune
# @group Services
enable|Enable service(s)|enable
disable|Disable service(s)|disable
create|Create service|create
remove|Remove service|remove
move|Move a service to another host|move
receive|Receive a service from another host|receive
edit|Edit service|edit
env|Edit env file|env
tidy|Organize the env file and sort ports|tidy
restore|Restore .env from the tidy backup|restore
# @group Script
version|Display version|version
update|Update script when a new version exists|update
repull|Re-download repo files|repull
bashrc|Add the dc.bash source line to ~/.bashrc|bashrc
key|Create an SSH key and install it on a host|key
hosts|List hosts ready for moving services|hosts
path|Print script and APPS paths|path
help|This help menu|help
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

Help() {
    local line name desc handler args group
    local first=1
    Banner "help"
    printf "  %bcompose.sh -a <action> [-s service] [-- extra args]%b\n" "$c_dim" "$c_reset"
    printf "  %b-e <file>%b   env file, default %s\n" "$c_dim" "$c_reset" "$SCRIPT_WORKING_DIR/.env"
    printf "  %bexample%b     compose.sh -a logs -s plex -- --tail 100\n" "$c_dim" "$c_reset"
    printf "  %bexample%b     compose.sh -a move -s plex -- root@other-host\n" "$c_dim" "$c_reset"
    printf "  %bexample%b     compose.sh -a key -- root@other-host\n" "$c_dim" "$c_reset"
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
        IFS='|' read -r name desc handler args <<< "$line"
        printf "  %b%-10s%b  %s\n" "$c_teal" "$name" "$c_reset" "$desc"
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
    folder="${folder,,}"
}


CheckEnv() {
    if [ -z "$envFile" ]; then
        envFile="$SCRIPT_WORKING_DIR/.env"
    fi

    if [ ! -f "$envFile" ]; then
        Say bad "Env file does not exist: $envFile"
        exit
    fi

    # shellcheck disable=SC1090
    source "$envFile"
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

CheckDockerCompose() {
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
        exit
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
    local name desc handler args
    if [[ -z "${action:-}" ]]; then
        Say bad "Invalid option. Run compose.sh -h for available actions."
        exit 1
    fi
    while IFS='|' read -r name desc handler args; do
        [[ "$name" == "$action" ]] || continue
        case "$handler" in
            compose)
                Banner "$name"
                # shellcheck disable=SC2086
                RunServices "$folder" $args "${EXTRA_ARGS[@]}"
                ;;
            logs)
                Banner "logs"
                Logs
                ;;
            enable)
                Say ok "Enabling $folder"
                Toggle enable "$folder"
                ;;
            disable)
                Say warn "Disabling $folder"
                Toggle disable "$folder"
                ;;
            list) List ;;
            ps) Ps ;;
            issue) Issue ;;
            images) ShowImages list ;;
            pull) ShowImages pull ;;
            stats) Stats ;;
            df) Disk ;;
            prune) Prune ;;
            exec) Exec ;;
            cp) Cp ;;
            create)
                Banner "create"
                Create "$folder"
                ;;
            remove) Remove "$folder" ;;
            move) Move ;;
            receive) Receive ;;
            path) Path ;;
            version)
                Banner "version"
                Say ok "$VERSION"
                CheckVersion ask
                ;;
            update)
                Banner "update"
                CheckVersion apply
                ;;
            repull)
                Banner "repull"
                Update
                ;;
            ports) CheckPorts ;;
            nextport) NextPort ;;
            edit) EditFile "$folder" ;;
            env) EditFile env ;;
            tidy) TidyEnv ;;
            restore) RestoreEnv ;;
            bashrc) PrintBashrc ;;
            key) Key ;;
            hosts) Hosts ;;
            help) Help ;;
            *)
                Say bad "Unknown handler: $handler"
                exit 1
                ;;
        esac
        return 0
    done < <(EachAction)
    Say bad "Invalid option. Run compose.sh -h for available actions."
    Help
    exit 1
}

CheckVersion() {
    local mode="$1"
    local answer

    LATEST_RELEASE="$(curl -fsS -r 0-50 "$GITHUB_RAWURL" | sed -n "/VERSION/s/VERSION=//p" | tr -d '"\r')"
    LATEST_CHANGES="$(curl -fsS -r 0-200 "$GITHUB_RAWURL" | sed -n "/ChangeNotes/s/### ChangeNotes: //p" | tr -d '\r')"

    if [[ -z "$LATEST_RELEASE" ]]; then
        Say warn "Could not check for updates."
        return 1
    fi

    if [[ "$VERSION" == "$LATEST_RELEASE" ]]; then
        if [[ "$mode" == "apply" ]]; then
            Say ok "Already up to date."
        fi
        return 0
    fi

    Say warn "New version available: $VERSION → $LATEST_RELEASE"
    [[ -n "$LATEST_CHANGES" ]] && Say info "Change notes: $LATEST_CHANGES"
    if [[ "$mode" == "apply" ]]; then
        Update
        return
    fi
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
  local -a args=("-a" "version")
  local i n
  n=${#SCRIPT_ARGS[@]}
  i=0
  while [[ "$i" -lt "$n" ]]; do
    if [[ "${SCRIPT_ARGS[$i]}" == "-e" && $((i + 1)) -lt "$n" ]]; then
      args+=("-e" "${SCRIPT_ARGS[$((i + 1))]}")
    fi
    i=$((i + 1))
  done
  exec "$SCRIPT_PATH" "${args[@]}"
  exit 1
}

UpdateCurl() {
  local -a repo_files=(
    compose.sh
    dc.bash
    README.md
    docker-compose.yml
    .env.example
    .gitignore
    LICENSE
  )
  local -a tmps=()
  local name tmp dest i

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
    if [[ -f "$dest" ]] && ! cp "$dest" "$dest.bak"; then
      rm -f "${tmps[@]}"
      Say bad "Could not back up $name. No files were changed."
      return
    fi
  done

  for i in "${!repo_files[@]}"; do
    name="${repo_files[$i]}"
    dest="$SCRIPT_WORKING_DIR/$name"
    if ! cp "${tmps[$i]}" "$dest"; then
      for name in "${repo_files[@]}"; do
        dest="$SCRIPT_WORKING_DIR/$name"
        if [[ -f "$dest.bak" ]]; then
          cp "$dest.bak" "$dest"
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

List() {
    local dir path status width enabled_count=0 disabled_count=0 i
    local -a en_name=() en_status=() dis_name=() dis_status=()
    Banner "list"
    LoadProjectStatus
    while IFS= read -r dir; do
        path="$(basename "$dir")"
        status="$(ReturnStatus "$path")"
        if [ -z "$status" ] || [ "$status" = " - " ]; then
            status="no container"
        fi
        if [ -f "$dir/$COMPOSE_FILE" ]; then
            en_name+=("$path")
            en_status+=("$status")
            enabled_count=$((enabled_count+1))
        fi
        if [ -f "$dir/$COMPOSE_FILE_DISABLED" ]; then
            dis_name+=("$path")
            dis_status+=("$status")
            disabled_count=$((disabled_count+1))
        fi
    done < <(ServiceDirs)
    if [[ ${#en_name[@]} -eq 0 && ${#dis_name[@]} -eq 0 ]]; then
        Say info "No services."
        return
    fi
    width="$(ColumnWidth 7 "${en_name[@]}" "${dis_name[@]}")"
    printf "%b     %s  │  %s%b\n" "$c_dim" "$(PadRight "service" "$width")" "containers" "$c_reset"
    for i in "${!en_name[@]}"; do
        printf "  %b%s%b  %s  %b│%b  %s\n" \
            "$c_green" "✔" "$c_reset" \
            "$(PadRight "${en_name[$i]}" "$width")" \
            "$c_dim" "$c_reset" \
            "$(PaintStatus "${en_status[$i]}")"
    done
    if [[ ${#dis_name[@]} -gt 0 ]]; then
        [[ ${#en_name[@]} -gt 0 ]] && printf "\n  %bdisabled%b\n" "$c_dim" "$c_reset"
        for i in "${!dis_name[@]}"; do
            printf "  %b%s%b  %s  %b│%b  %s\n" \
                "$c_red" "✘" "$c_reset" \
                "$(PadRight "${dis_name[$i]}" "$width")" \
                "$c_dim" "$c_reset" \
                "$(PaintStatus "${dis_status[$i]}")"
        done
    fi
    printf "\n"
    Say info "$enabled_count enabled · $disabled_count disabled"
}

Toggle() {
    local action="$1"
    local folder="$2"
    local file fileName newFileName removeAnswer
    CheckFolderSupplied "$folder"
    fileName=$( [ "$action" == "enable" ] && echo "$COMPOSE_FILE_DISABLED" || echo "$COMPOSE_FILE" )
    newFileName=$( [ "$action" == "enable" ] && echo "$COMPOSE_FILE" || echo "$COMPOSE_FILE_DISABLED" )

    for file in "$APPS/$folder"/*; do
        if [ -f "$file" ] && [ "${file##*/}" == $fileName ]; then
            if [ $newFileName == $COMPOSE_FILE_DISABLED ]; then
                if CheckStatus $folder; then
                    removeAnswer="$(Ask "Service is running. Stop and remove it? [y/N]")"
                    if [[ "$removeAnswer" == [yY] ]]; then
                        Say warn "Stopping and removing containers."
                        "${DockerCmd[@]}" --file "$APPS/$folder/$COMPOSE_FILE" --env-file "$envFile" down
                        Say ok "Service removed."
                    else
                        Say info "Keeping service."
                    fi
                fi
            fi
            mv "$file" "$APPS/$folder/$newFileName"
        fi
    done
    if [ ! -f "$APPS/$folder/$COMPOSE_FILE" ] && [ ! -f "$APPS/$folder/$COMPOSE_FILE_DISABLED" ]; then
        Say bad "Service does not exist."
    elif [ "$action" = "enable" ]; then
        Say ok "Service enabled."
    else
        Say warn "Service disabled."
    fi
}

ServiceDir() {
    local name="$1"
    local parent target

    if [[ -z "$name" || "$name" == *"/"* || "$name" == *".."* || "$name" == "." ]]; then
        Say baderr "Invalid service name."
        return 1
    fi
    if [[ ! -d "$APPS" ]]; then
        Say baderr "APPS directory does not exist."
        return 1
    fi

    parent="$(cd -P "$APPS" && pwd -P)"
    target="$parent/$name"
    if [[ ! -d "$target" ]]; then
        Say baderr "Service does not exist."
        return 1
    fi
    target="$(cd -P "$target" && pwd -P)"
    case "$target" in
        "$parent"/*) printf '%s\n' "$target" ;;
        *)
            Say baderr "Refusing to delete a path outside $parent."
            return 1
            ;;
    esac
}

Remove() {
    local name="$1"
    local target compose_file=""

    CheckFolderSupplied "$name"
    if ! target="$(ServiceDir "$name")"; then
        exit 1
    fi
    Banner "remove"
    Say warn "Removing service folder: $target"

    if [[ -f "$APPS/$name/$COMPOSE_FILE" ]]; then
        compose_file="$APPS/$name/$COMPOSE_FILE"
    elif [[ -f "$APPS/$name/$COMPOSE_FILE_DISABLED" ]]; then
        compose_file="$APPS/$name/$COMPOSE_FILE_DISABLED"
    fi
    if [[ -n "$compose_file" ]] && CheckStatus "$name"; then
        Say warn "Service is running. Stopping it now."
        "${DockerCmd[@]}" --file "$compose_file" --env-file "$envFile" down
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
            key="$(printf '%s' "$status" | tr '[:upper:]' '[:lower:]')"
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

RunOneCompose() {
    local file="$1"
    shift
    "${DockerCmd[@]}" --file "$file" --env-file "$envFile" "$@"
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
    start=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do
        now=$(date +%s)
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
    local dir path failed=0 ran=0
    local -a names=()
    local index=0 unchanged=0 changed=0 failed_color name_width=16
    case "$verb" in
        up|start|stop|restart|pause|unpause|down) pretty=1 ;;
    esac

    if [[ -z "$service" || "$service" == "all" ]]; then
        if [[ -z "$service" ]]; then
            answer="$(Ask "No service was provided. Loop through all services? [Y/n]")"
            if [[ -n "$answer" && "$answer" != [yY] ]]; then
                Say info "Exiting."
                return
            fi
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
        exit 1
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
    low="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
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
    printf "%b       %s  │  %s  │  %s  │  %s%b\n" "$c_dim" \
        "$(PadRight "service" "$svc_w")" "$(PadRight "name" "$name_w")" \
        "$(PadRight "status" "$status_w")" "ports" "$c_reset"
    for i in "${!CTR_NAME[@]}"; do
        low="$(printf '%s' "${CTR_STATUS[$i]}" | tr '[:upper:]' '[:lower:]')"
        case "$low" in
            *restarting*|*unhealthy*) mark="·"; color="$c_yellow" ;;
            up\ *|*healthy*) mark="✔"; color="$c_green" ;;
            *exited*|*dead*) mark="✘"; color="$c_red" ;;
            *) mark="·"; color="$c_yellow" ;;
        esac
        ports_text="${CTR_PORTS[$i]}"
        [[ -z "$ports_text" ]] && ports_text="-"
        printf "  %b%s%b  %s  %b│%b  %s  %b│%b  %s  %b│%b  %s\n" \
            "$color" "$mark" "$c_reset" \
            "$(PadRight "${CTR_SVC[$i]}" "$svc_w")" \
            "$c_dim" "$c_reset" \
            "$(PadRight "${CTR_NAME[$i]}" "$name_w")" \
            "$c_dim" "$c_reset" \
            "$(PaintStatus "$(PadRight "${CTR_STATUS[$i]}" "$status_w")")" \
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
        low="$(printf '%s' "${CTR_STATUS[$i]}" | tr '[:upper:]' '[:lower:]')"
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
        if [[ "$title" != "${CTR_NAME[$i]}" ]]; then
            printf "     %b%s%b  %b·%b  %s\n" "$c_dim" "${CTR_NAME[$i]}" "$c_reset" \
                "$c_dim" "$c_reset" "$(PaintStatus "${CTR_STATUS[$i]}")"
        else
            printf "     %s\n" "$(PaintStatus "${CTR_STATUS[$i]}")"
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
        low="$(printf '%s' "${CTR_STATUS[$i]}" | tr '[:upper:]' '[:lower:]')"
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
    printf "%b       %s  │  %s  │  %s  │  %s  │  %s%b\n" "$c_dim" \
        "$(PadRight "service" "$svc_w")" "$(PadRight "name" "$name_w")" \
        "$(PadRight "cpu" "$cpu_w")" "$(PadRight "memory" "$mem_w")" "network" "$c_reset"
    for i in "${!row_name[@]}"; do
        printf "  %b·%b  %s  %b│%b  %s  %b│%b  %s  %b│%b  %s  %b│%b  %s\n" \
            "$c_teal" "$c_reset" \
            "$(PadRight "${row_svc[$i]}" "$svc_w")" \
            "$c_dim" "$c_reset" \
            "$(PadRight "${row_name[$i]}" "$name_w")" \
            "$c_dim" "$c_reset" \
            "$(PadRight "${row_cpu[$i]}" "$cpu_w")" \
            "$c_dim" "$c_reset" \
            "$(PadRight "${row_mem[$i]}" "$mem_w")" \
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

Prune() {
    local answer tried=0 did=0
    Banner "prune"
    Say info "This cleans the whole Docker host."
    if ! docker system df; then
        Say bad "docker system df failed."
        return 1
    fi
    printf "\n"
    answer="$(Ask "Remove unused images, build cache, stopped containers, and networks? [y/N]")"
    if [[ "$answer" == [yY] ]]; then
        tried=1
        if docker system prune -a -f; then
            did=1
        else
            Say bad "Image prune failed."
        fi
        if docker builder prune -a -f; then
            did=1
        else
            Say warn "Build cache was left in place."
        fi
    fi
    answer="$(Ask "Remove unused volumes? Volumes not attached to a container are deleted. [y/N]")"
    if [[ "$answer" == [yY] ]]; then
        tried=1
        if docker volume prune -f; then
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
    if [[ -f "$APPS/$folder/$COMPOSE_FILE" ]]; then
        file="$APPS/$folder/$COMPOSE_FILE"
    elif [[ -f "$APPS/$folder/$COMPOSE_FILE_DISABLED" ]]; then
        Say warn "Service is disabled."
        file="$APPS/$folder/$COMPOSE_FILE_DISABLED"
    else
        Say bad "Service does not exist."
        exit 1
    fi
    RunOneCompose "$file" cp "${EXTRA_ARGS[@]}"
}

ValidServiceName() {
    local name="$1"
    [[ -n "$name" && "$name" != "all" && "$name" != "." && "$name" != ".." ]] || return 1
    [[ "$name" != *"/"* && "$name" != *".."* && "$name" != *$'\n'* ]] || return 1
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]
}

ComposeVarNames() {
    local file="$1" text match name new
    local -A seen=()
    text="$(tr -d '\r' < "$file")"
    while [[ "$text" =~ \$\{([A-Za-z_][A-Za-z0-9_]*) ]]; do
        name="${BASH_REMATCH[1]}"
        match="${BASH_REMATCH[0]}"
        if [[ -z "${seen[$name]+x}" ]]; then
            seen["$name"]=1
            printf '%s\n' "$name"
        fi
        new="${text/"$match"/}"
        [[ "$new" == "$text" ]] && break
        text="$new"
    done
    while [[ "$text" =~ \$([A-Za-z_][A-Za-z0-9_]*) ]]; do
        name="${BASH_REMATCH[1]}"
        match="${BASH_REMATCH[0]}"
        if [[ -z "${seen[$name]+x}" ]]; then
            seen["$name"]=1
            printf '%s\n' "$name"
        fi
        new="${text/"$match"/}"
        [[ "$new" == "$text" ]] && break
        text="$new"
    done
}

EnvRawLine() {
    local file="$1" key="$2" line found="" k
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
        k="${BASH_REMATCH[1]}"
        [[ "$k" == "$key" ]] || continue
        line="${line#"${line%%[![:space:]]*}"}"
        found="$line"
    done < "$file"
    [[ -n "$found" ]] && printf '%s\n' "$found"
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
        expanded="$(ExpandComposeValue "$item")"
        [[ -n "$expanded" ]] && item="$expanded"
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

    Banner "hosts"
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
        Say info "dc key root@hostname"
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
    local name="$1" target file=""
    if ! target="$(ServiceDir "$name")"; then
        return 1
    fi
    if [[ -f "$target/$COMPOSE_FILE" ]]; then
        file="$target/$COMPOSE_FILE"
    elif [[ -f "$target/$COMPOSE_FILE_DISABLED" ]]; then
        file="$target/$COMPOSE_FILE_DISABLED"
    fi
    if [[ -n "$file" ]] && CheckStatus "$name"; then
        Say warn "Stopping it now."
        "${DockerCmd[@]}" --file "$file" --env-file "$envFile" down || return 1
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

PackService() {
    local dest="$1"
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
        stdbuf -oL tar -C "$APPS" -czf "$dest" -v "$folder" >"$verbose" 2>"$err" &
    else
        tar -C "$APPS" -czf "$dest" -v "$folder" >"$verbose" 2>"$err" &
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
        Say bad "Could not pack $folder."
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
    local host file service_dir size answer remote_info script_path apps_path
    local errfile remote_cmd name line key sent run_state header archive status stopped_for_move=0
    local -a ssh_opts=(-T -o BatchMode=yes -o ConnectTimeout=20 -o GSSAPIAuthentication=no -o PreferredAuthentications=publickey)
    local -a env_lines=() missing=() skipped=()
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
    if [[ -f "$APPS/$folder/$COMPOSE_FILE" ]]; then
        file="$APPS/$folder/$COMPOSE_FILE"
    elif [[ -f "$APPS/$folder/$COMPOSE_FILE_DISABLED" ]]; then
        file="$APPS/$folder/$COMPOSE_FILE_DISABLED"
    else
        Say bad "Service does not exist."
        exit 1
    fi
    service_dir="$(cd -P "$APPS/$folder" && pwd -P)" || {
        Say bad "Service does not exist."
        exit 1
    }
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
    for name in "${var_names[@]}"; do
        line="$(EnvRawLine "$envFile" "$name")"
        if [[ -n "$line" ]]; then
            env_lines+=("$line")
        else
            missing+=("$name")
        fi
    done
    while IFS= read -r line; do
        [[ -n "$line" ]] && skipped+=("$line")
    done < <(SkippedMounts "$file" "$service_dir")

    Say info "Folder size: $size"
    Say info "Destination: $host"
    Say info "Apps path: $apps_path"
    Say info "Script: $script_path"
    Say info "The other host pulls the image when the service is started."
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
    answer="$(Ask "Move $folder to $host? [y/N]")"
    if [[ "$answer" != [yY] ]]; then
        Say info "Keeping $folder here."
        return 0
    fi
    run_state="$(printf '%s' "$(ReturnStatus "$folder")" | tr '[:upper:]' '[:lower:]')"
    if [[ "$run_state" == *running* || "$run_state" == *restarting* || "$run_state" == *paused* ]]; then
        answer="$(Ask "Stop $folder before moving? [Y/n]")"
        if [[ -z "$answer" || "$answer" == [yY] ]]; then
            Say warn "Stopping $folder."
            if ! "${DockerCmd[@]}" --file "$file" --env-file "$envFile" stop; then
                Say bad "Stop failed. This host was left unchanged."
                exit 1
            fi
            stopped_for_move=1
        else
            Say warn "Copying while containers are running."
        fi
    fi

    header="$(mktemp)" || exit 1
    archive="$(mktemp)" || {
        rm -f "$header"
        exit 1
    }
    {
        printf 'COMPOSE-MOVE 1\n'
        printf 'service %s\n' "$folder"
        printf 'compose %s\n' "$(basename "$file")"
        printf 'env %s\n' "${#env_lines[@]}"
        if [[ ${#env_lines[@]} -gt 0 ]]; then
            printf '%s\n' "${env_lines[@]}"
        fi
    } >"$header" || {
        Say bad "Could not pack $folder."
        rm -f "$header" "$archive"
        exit 1
    }
    if ! PackService "$archive"; then
        rm -f "$header" "$archive"
        exit 1
    fi
    printf -v remote_cmd 'bash %q -a receive -s %q' "$script_path" "$folder"
    set -o pipefail
    {
        cat "$header"
        StreamFile "$archive" sending
    } | ssh "${ssh_opts[@]}" "$host" "$remote_cmd"
    status=$?
    set +o pipefail
    rm -f "$header" "$archive"
    if [[ "$status" -ne 0 ]]; then
        printf '\r\033[K' >&2
        Say bad "Move failed. The folder is still here."
        if [[ "$stopped_for_move" -eq 1 ]]; then
            Say warn "Starting $folder again."
            if "${DockerCmd[@]}" --file "$file" --env-file "$envFile" start; then
                Say ok "$folder is running."
            else
                Say bad "Could not start $folder."
            fi
        fi
        exit 1
    fi
    if [[ -f "$APPS/$folder/$COMPOSE_FILE" ]]; then
        mv "$APPS/$folder/$COMPOSE_FILE" "$APPS/$folder/$COMPOSE_FILE_DISABLED"
        Say warn "Disabled $folder on this host."
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
    local magic svc_line compose_line env_line compose_name env_count
    local line key added=0 i work archive arrived final_name
    local -a env_lines=()

    if ! ValidServiceName "$folder"; then
        Say bad "Invalid service name."
        exit 1
    fi
    if [[ ! -d "$APPS" ]]; then
        Say bad "APPS directory does not exist."
        exit 1
    fi
    if [[ -e "$APPS/$folder" ]]; then
        Say bad "Service already exists on this host."
        exit 1
    fi
    if [[ -n "${RECEIVE_STREAM:-}" ]]; then
        exec <"$RECEIVE_STREAM"
    fi
    IFS= read -r magic || exit 1
    [[ "$magic" == "COMPOSE-MOVE 1" ]] || {
        Say bad "Move stream was not recognized."
        exit 1
    }
    IFS= read -r svc_line || exit 1
    IFS= read -r compose_line || exit 1
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
    if [[ -e "$APPS/$folder" ]]; then
        rm -rf "$work"
        Say bad "Service already exists on this host."
        exit 1
    fi
    if ! mv "$work/unpack/$folder" "$APPS/$folder"; then
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
    Say ok "Received $folder. It is disabled."
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
    if [[ -f "$APPS/$folder/$COMPOSE_FILE" ]]; then
        file="$APPS/$folder/$COMPOSE_FILE"
    elif [[ -f "$APPS/$folder/$COMPOSE_FILE_DISABLED" ]]; then
        Say warn "Service is disabled."
        exit 1
    else
        Say bad "Service does not exist."
        exit 1
    fi
    while IFS= read -r svc; do
        [[ -n "$svc" ]] && svcs+=("$svc")
    done < <("${DockerCmd[@]}" --file "$file" --env-file "$envFile" config --services 2>/dev/null)
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
    if [ "$1" == "env" ]; then
        file_to_edit="$envFile"
    else
        file_to_edit="$APPS/$1/$COMPOSE_FILE"
        backup_file_to_edit="$APPS/$1/$COMPOSE_FILE_DISABLED"
        
        # Only check the folder if $1 is not "env"
        if ! CheckFolderSuppliedNoExit "$1"; then
            Say bad "No service name supplied."
            exit 1
        fi
    fi

    # Check for existence of files
    if [ -f "$file_to_edit" ]; then
        Say ok "Using $file_to_edit"
    elif [ -f "$backup_file_to_edit" ]; then
        Say warn "Primary file not found. Using $backup_file_to_edit"
        file_to_edit="$backup_file_to_edit"
    else
        Say bad "Neither primary nor backup file exists."
        Say info "$file_to_edit"
        Say info "$backup_file_to_edit"
        exit 1
    fi

    Banner "edit $1"
    OpenEditor "$file_to_edit"
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
    if ! CheckFolderSuppliedNoExit "$1"; then
        folder="$(Ask "What should we name the service:")"
        folder="${folder,,}"
    fi
    

    if [ ! -f "$STUB_FILE" ]; then
        Say bad "Stub file does not exist: $STUB_FILE"
        exit
    fi

    if [ -d "$APPS/$folder" ]; then
        Say warn "Service already exists: $folder"
        exit
    fi

    image="$(Ask "Enter the container image:")"
    if [ -z "$image" ]; then
        Say bad "Image not supplied."
        exit
    fi

    mkdir -p "$APPS/$folder"
    cp "$STUB_FILE" "$APPS/$folder/$COMPOSE_FILE_DISABLED"
    sed -i -e "s|{{SERVICE}}|$folder|g" -e "s|{{IMAGE}}|$image|g" "$APPS/$folder/$COMPOSE_FILE_DISABLED"
    Say ok "Service created: $folder"
    Say warn "Disabled until you edit the compose file."
    
    exit
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
        APPS COMPOSE_FILE COMPOSE_FILE_DISABLED STUB_FILE STARTING_PORT
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
    cp "$envFile" "${envFile}.bak" || {
        rm -f "$out"
        Say bad "Could not write ${envFile}.bak."
        exit 1
    }
    if ! mv "$out" "$envFile"; then
        rm -f "$out"
        Say bad "Could not rewrite $envFile."
        exit 1
    fi
    Say ok "Organized $envFile."
    Say info "Previous file saved as ${envFile}.bak."
}

RestoreEnv() {
    local bak="${envFile}.bak" answer

    Banner "restore"
    if [[ ! -f "$bak" ]]; then
        Say bad "No backup at $bak."
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

LoadEnvPorts() {
    local name=$1
    local key value
    [[ -f "$envFile" ]] || return 0
    while IFS='=' read -r key value; do
        key="${key%"${key##*[![:space:]]}"}"
        [[ "$key" == "STARTING_PORT" ]] && continue
        [[ "$key" == *_PORT_* && "$key" != \#* ]] || continue
        MarkUsedPort "$name" "$value"
    done < "$envFile"
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
        Say info "Free from .env and listening ports."
        return 0
    done
    Say bad "No free port from $start to 65535."
    exit 1
}

CheckPorts() {
    local key value name width
    local -a names=()
    declare -A ports
    Banner "ports"

    while IFS='=' read -r key value; do
        if [[ $key == *_PORT_* && ! $key =~ ^# ]]; then
            name="${key%%_PORT_*}"
            name="${name^^}"
            if [[ -n "${ports[$name]:-}" ]]; then
                ports[$name]+="  ${value}"
            else
                ports[$name]="$value"
                names+=("$name")
            fi
        fi
    done < "$envFile"

    if [[ ${#names[@]} -eq 0 ]]; then
        Say info "No _PORT_ entries in the env file."
        return
    fi
    width="$(ColumnWidth 7 "${names[@]}")"
    printf "%b  %s  │  %s%b\n" "$c_dim" "$(PadRight "service" "$width")" "ports" "$c_reset"
    while IFS= read -r name; do
        printf "  %b%s%b  %b│%b  %s\n" "$c_teal" "$(PadRight "$name" "$width")" "$c_reset" "$c_dim" "$c_reset" "${ports[$name]}"
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

VarIsSet() {
    local name="$1"
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    eval "[ \"\${${name}+x}\" = x ]"
}

VarValue() {
    local name="$1"
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    eval "printf '%s' \"\${${name}-}\""
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

# Expand $VAR, ${VAR}, ${VAR:-default}, and ${VAR-default} from the sourced env file.
ExpandComposeValue() {
    local input="$1"
    local result=""
    local rest="$input"
    local name default match value

    while [ -n "$rest" ]; do
        if [[ "$rest" == \$\$* ]]; then
            result+='$'
            rest="${rest:2}"
            continue
        fi

        if [[ "$rest" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)(:-)([^}]*)\} ]]; then
            name="${BASH_REMATCH[1]}"
            default="${BASH_REMATCH[3]}"
            match="${BASH_REMATCH[0]}"
            if VarIsSet "$name"; then
                value="$(VarValue "$name")"
                if [ -z "$value" ]; then
                    value="$default"
                fi
            else
                value="$default"
            fi
            result+="$value"
            rest="${rest:${#match}}"
            continue
        fi

        if [[ "$rest" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)-([^}]*)\} ]]; then
            name="${BASH_REMATCH[1]}"
            default="${BASH_REMATCH[2]}"
            match="${BASH_REMATCH[0]}"
            if VarIsSet "$name"; then
                value="$(VarValue "$name")"
            else
                value="$default"
            fi
            result+="$value"
            rest="${rest:${#match}}"
            continue
        fi

        if [[ "$rest" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; then
            name="${BASH_REMATCH[1]}"
            match="${BASH_REMATCH[0]}"
            if VarIsSet "$name"; then
                value="$(VarValue "$name")"
            else
                value=""
            fi
            result+="$value"
            rest="${rest:${#match}}"
            continue
        fi

        if [[ "$rest" =~ ^\$([A-Za-z_][A-Za-z0-9_]*) ]]; then
            name="${BASH_REMATCH[1]}"
            match="${BASH_REMATCH[0]}"
            if VarIsSet "$name"; then
                value="$(VarValue "$name")"
            else
                value=""
            fi
            result+="$value"
            rest="${rest:${#match}}"
            continue
        fi

        result+="${rest:0:1}"
        rest="${rest:1}"
    done

    printf '%s' "$result"
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

    output=$("${DockerCmd[@]}" --file "$file" --env-file "$envFile" config --images 2>"$err")
    status=$?
    if [ "$status" -eq 0 ]; then
        rm -f "$err"
        while IFS= read -r line || [ -n "$line" ]; do
            line="$(CleanImageRef "$line")"
            [ -n "$line" ] && printf '%s\n' "$line"
        done <<< "$output"
        return 0
    fi

    output=$("${DockerCmd[@]}" --file "$file" --env-file "$envFile" config 2>"$err")
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
        exp="$(ExpandComposeValue "$img")"
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
    printf "  %b%s%b  %s  %b│%b  %b%s%b  %b│%b  %s\n" \
        "$color" "$mark" "$c_reset" \
        "$(PadRight "$path" "$path_w")" \
        "$c_dim" "$c_reset" \
        "$tag_color" "$(PadRight "$tag" "$tag_w")" "$c_reset" \
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
    local answer img_ref include_disabled=0 pull_enabled=0

    if [ -n "$folder" ] && [ "$folder" != "all" ]; then
        Banner "images $folder"
    else
        Banner "images"
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
        printf "%b     %s  │  %s  │  %s%b\n" "$c_dim" \
            "$(PadRight "service" "$svc_width")" "$(PadRight "tag" "$tag_width")" "image" "$c_reset"
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
        printf '    %s\n' "${missing_refs[@]}"
    fi
    if [[ "$stale_count" -eq 0 ]]; then
        Say ok "Nothing to pull."
        return 0
    fi
    Say warn "${stale_count} image(s) have updates:"
    printf '    %s\n' "${stale_refs[@]}"

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
    Banner "key"
    if [[ -z "${HOME:-}" ]]; then
        Say bad "HOME is not set."
        exit 1
    fi
    host="${EXTRA_ARGS[0]:-}"
    if [[ -z "$host" && -n "${folder:-}" ]]; then
        host="$folder"
    fi
    if [[ ${#EXTRA_ARGS[@]} -gt 1 ]] || { [[ -n "$host" ]] && ! MoveHostOk "$host"; }; then
        Say bad "Key takes an optional host."
        Say info "dc key"
        Say info "dc key root@other-host"
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
if [[ "$(printf '%s' "${action:-}" | tr '[:upper:]' '[:lower:]')" == "bashrc" ]]; then
    PrintBashrc
    exit 0
fi
CheckEnv;
CheckEnvVariables;
if [[ "$(printf '%s' "${action:-}" | tr '[:upper:]' '[:lower:]')" == "path" ]]; then
    Path
    exit 0
fi
LowerCaseArguments;
if [[ "$action" == "receive" ]]; then
    Receive
    exit $?
fi
CheckDockerCompose;
CheckAction;

exit 0
