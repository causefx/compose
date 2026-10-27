#!/bin/bash
VERSION=v1.7.12
### ChangeNotes: One action list drives help and completion.
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

### Colors:
c_red="\033[0;31m"
c_green="\033[0;32m"
c_yellow="\033[0;33m"
c_blue="\033[0;34m"
c_teal="\033[0;36m"
c_dim="\033[2m"
c_reset="\033[0m"

Banner() {
    printf "%b── %s ──%b\n" "$c_teal" "$*" "$c_reset"
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
    read -r -p "$(printf "  %b?%b  %s " "$c_teal" "$c_reset" "$1")" reply
    printf '%s' "$reply"
}

PaintStatus() {
    local text="$1"
    local color="$c_dim"
    local lower
    lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
        *running*|*healthy*) color="$c_green" ;;
        *paused*|*restarting*|*created*) color="$c_yellow" ;;
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
ps|Show container(s)|compose|ps
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
                CheckVersion
                ;;
            update)
                Banner "update"
                CheckVersion "silent"
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
    local silent="$1"  # Accept an optional parameter

    LATEST_RELEASE="$(curl -s -r 0-50 "$GITHUB_RAWURL" | sed -n "/VERSION/s/VERSION=//p" | tr -d '"')"
    LATEST_CHANGES="$(curl -s -r 0-200 "$GITHUB_RAWURL" | sed -n "/ChangeNotes/s/### ChangeNotes: //p")"

    ### Check if LATEST_RELEASE is empty and skip if so
    if [[ -z "$LATEST_RELEASE" ]]; then
        if [[ "$silent" ]]; then
            Say warn "Could not check for updates."
        fi
        return
    fi

    ### Version check & initiate self update
    if [[ "$VERSION" != "$LATEST_RELEASE" ]] ; then
        Say warn "New version available: $VERSION → $LATEST_RELEASE"
        Say info "Change notes: $LATEST_CHANGES"
        if [[ -z "$AutoUp" ]] ; then
            SelfUpdate="$(Ask "Would you like to update? [y/N]")"
            [[ "$SelfUpdate" =~ [yY] ]] && Update
        fi
    elif [[ "$silent" ]]; then
        # Print "Already up-to-date" message only if `silent` is set
        Say ok "Already up to date."
    fi
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
  Say ok "Starting over with the updated version."
  exec "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}" # run the new script with old arguments
  exit 1 # exit the old instance
}

Update() {
  cd "$SCRIPT_WORKING_DIR" || { Say bad "Path error, skipping update." ; return ; }
  if [[ -n "$(builtin type -P git)" ]] && [[ "$(git ls-remote --get-url 2>/dev/null)" =~ .*"causefx/compose".* ]] ; then
    Say info "Pulling the latest version."
    git pull --force || { Say bad "Git error, manually pull/clone." ; return ; }
    Say ok "Starting over with the updated version."
    cd - || { Say bad "Path error." ; return ; }
    exec "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}" # run the new script with old arguments
    exit 1 # exit the old instance
  else
    cd - || { Say bad "Path error." ; return ; }
    UpdateCurl
  fi
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

    if ! command -v nano &> /dev/null; then
        vim "$file_to_edit"
    else
        nano "$file_to_edit"
    fi
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
        tag_width="$(ColumnWidth 3 "${disp_tag[@]}")"
        printf "%b      %s  │  %s%b\n" "$c_dim" "$(PadRight "tag" "$tag_width")" "image" "$c_reset"
        for i in "${!disp_path[@]}"; do
            if [[ "$prev" != "${disp_path[$i]}|${disp_state[$i]}" ]]; then
                if [[ "${disp_state[$i]}" == "Enabled" ]]; then
                    mark="✔"
                    color="$c_green"
                else
                    mark="✘"
                    color="$c_red"
                fi
                printf "  %b%s%b  %s\n" "$color" "$mark" "$c_reset" "${disp_path[$i]}"
                prev="${disp_path[$i]}|${disp_state[$i]}"
            fi
            tag_color="$c_dim"
            [[ "${disp_tag[$i]}" == "-" ]] && tag_color="$c_yellow"
            printf "      %b%s%b  %b│%b  %s\n" \
                "$tag_color" "$(PadRight "${disp_tag[$i]}" "$tag_width")" "$c_reset" \
                "$c_dim" "$c_reset" "${disp_img[$i]}"
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
