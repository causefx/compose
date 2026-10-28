#!/bin/bash
VERSION=v1.7.18
### ChangeNotes: edit opens the editor on the terminal.
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
up|Create and start containers|compose|up -d
down|Stop and remove containers, networks|compose|down
start|Start service(s)|compose|start
stop|Stop service(s)|compose|stop
restart|Restart service container(s)|compose|restart
build|Build service image(s)|compose|build
pause|Pause service(s)|compose|pause
unpause|Unpause service(s)|compose|unpause
enable|Enable service(s)|enable
disable|Disable service(s)|disable
list|List service(s)|list
ps|Show container(s)|ps
issue|Show containers that need attention|issue
logs|Show service logs|logs
images|List compose images and tags|images
pull|Pull images and skip ones already current|pull
config|Render compose file(s)|compose|config
create|Create service|create
remove|Remove service|remove
version|Display version|version
update|Update script when a new version exists|update
repull|Re-download repo files|repull
ports|Show ports from ENV file|ports
edit|Edit service|edit
env|Edit env file|env
bashrc|Print the dc.bash source line|bashrc
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
    local name desc handler args
    Banner "help"
    printf "  %bcompose.sh -a <action> [-s service] [-- extra args]%b\n" "$c_dim" "$c_reset"
    printf "  %b-e <file>%b   env file, default %s\n" "$c_dim" "$c_reset" "$SCRIPT_WORKING_DIR/.env"
    printf "  %bexample%b     compose.sh -a logs -s plex -- --tail 100\n\n" "$c_dim" "$c_reset"
    Banner "actions"
    while IFS='|' read -r name desc handler args; do
        printf "  %b%-10s%b  %s\n" "$c_teal" "$name" "$c_reset" "$desc"
    done < <(EachAction)
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
    if docker compose version &> /dev/null; then
        DockerCmd=(docker compose)
    elif docker-compose version &> /dev/null || docker-compose -v &> /dev/null; then
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
            create)
                Banner "create"
                Create "$folder"
                ;;
            remove) Remove "$folder" ;;
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
            edit) EditFile "$folder" ;;
            env) EditFile env ;;
            bashrc) PrintBashrc ;;
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
    local -a row_name=() row_mark=() row_color=() row_status=()
    Banner "list"
    LoadProjectStatus
    while IFS= read -r dir; do
        path="$(basename "$dir")"
        status="$(ReturnStatus "$path")"
        if [ -z "$status" ] || [ "$status" = " - " ]; then
            status="no container"
        fi
        if [ -f "$dir/$COMPOSE_FILE" ]; then
            row_name+=("$path")
            row_mark+=("✔")
            row_color+=("$c_green")
            row_status+=("$status")
            enabled_count=$((enabled_count+1))
        fi
        if [ -f "$dir/$COMPOSE_FILE_DISABLED" ]; then
            row_name+=("$path")
            row_mark+=("✘")
            row_color+=("$c_red")
            row_status+=("$status")
            disabled_count=$((disabled_count+1))
        fi
    done < <(ServiceDirs)
    if [[ ${#row_name[@]} -eq 0 ]]; then
        Say info "No services."
        return
    fi
    width="$(ColumnWidth 7 "${row_name[@]}")"
    printf "%b     %s  │  %s%b\n" "$c_dim" "$(PadRight "service" "$width")" "containers" "$c_reset"
    for i in "${!row_name[@]}"; do
        printf "  %b%s%b  %s  %b│%b  %s\n" \
            "${row_color[$i]}" "${row_mark[$i]}" "$c_reset" \
            "$(PadRight "${row_name[$i]}" "$width")" \
            "$c_dim" "$c_reset" \
            "$(PaintStatus "${row_status[$i]}")"
    done
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
    local prev="" mark color tag_color tag_width i
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
        svc_width="$(ColumnWidth 7 "${disp_path[@]}")"
        tag_width="$(ColumnWidth 3 "${disp_tag[@]}")"
        printf "%b     %s  │  %s  │  %s%b\n" "$c_dim" \
            "$(PadRight "service" "$svc_width")" "$(PadRight "tag" "$tag_width")" "image" "$c_reset"
        for i in "${!disp_path[@]}"; do
            if [[ "${disp_state[$i]}" == "Enabled" ]]; then
                mark="✔"
                color="$c_green"
            else
                mark="✘"
                color="$c_red"
            fi
            tag_color="$c_dim"
            [[ "${disp_tag[$i]}" == "-" ]] && tag_color="$c_yellow"
            printf "  %b%s%b  %s  %b│%b  %b%s%b  %b│%b  %s\n" \
                "$color" "$mark" "$c_reset" \
                "$(PadRight "${disp_path[$i]}" "$svc_width")" \
                "$c_dim" "$c_reset" \
                "$tag_color" "$(PadRight "${disp_tag[$i]}" "$tag_width")" "$c_reset" \
                "$c_dim" "$c_reset" \
                "${disp_img[$i]}"
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

PrintBashrc() {
    printf 'source %q\n' "$SCRIPT_WORKING_DIR/dc.bash"
}

# Do the Things
if [[ "$(printf '%s' "${action:-}" | tr '[:upper:]' '[:lower:]')" == "bashrc" ]]; then
    PrintBashrc
    exit 0
fi
CheckEnv;
CheckEnvVariables;
LowerCaseArguments;
CheckDockerCompose;
CheckAction;

exit 0
