#!/bin/bash
VERSION=v1.6.0
### ChangeNotes: Added images, pull, and dc.bash. See README.md for past changes.
GITHUB="https://github.com/causefx/compose"
GITHUB_RAWURL="https://raw.githubusercontent.com/causefx/compose/main/compose.sh"
GITHUB_RAW_DC="https://raw.githubusercontent.com/causefx/compose/main/dc.bash"
SCRIPT_ARGS=( "$@" )
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
SCRIPT_WORKING_DIR="$(dirname "$SCRIPT_PATH")"

### Check if there's a new release of the script:
LATEST_RELEASE="$(curl -s -r 0-50 $GITHUB_RAWURL | sed -n "/VERSION/s/VERSION=//p" | tr -d '"')"
LATEST_CHANGES="$(curl -s -r 0-200 $GITHUB_RAWURL | sed -n "/ChangeNotes/s/### ChangeNotes: //p")"

### Colors:
c_red="\033[0;31m"
c_green="\033[0;32m"
c_yellow="\033[0;33m"
c_blue="\033[0;34m"
c_teal="\033[0;36m"
c_reset="\033[0m"

### Help Function:
Help() {
  echo "Syntax:     compose.sh [OPTIONS]"     
  echo "Example:    compose.sh -a list"
  echo
  echo "Options:"
  echo "-h         Print this Help."
  echo "-a         Action to perform."
  echo "-f | -s    Folder/Service name."
  echo "-e         (Optional) ENV full file path. | Default: $SCRIPT_WORKING_DIR/.env"
  printf "%s\n" "--- Available Actions ---"
  printf "%s %15s\n" "Action" "     Description";
  printf "%s %15s\n" "Help" "       This help menu";
  printf "%s %15s\n" "Up" "         Create and start containers";
  printf "%s %15s\n" "Down" "       Stop and remove containers, networks";
  printf "%s %15s\n" "Start" "      Start service(s)";
  printf "%s %15s\n" "Stop" "       Stop service(s)";
  printf "%s %15s\n" "Restart" "    Restart service container(s)";
  printf "%s %15s\n" "Pause" "      Pause service(s)";
  printf "%s %15s\n" "Unpause" "    Unpause service(s)";
  printf "%s %15s\n" "Enable" "     Enable service(s)";
  printf "%s %15s\n" "Disable" "    Disable service(s)";
  printf "%s %15s\n" "List" "       List service(s)";
  printf "%s %15s\n" "Images" "     List compose images and tags";
  printf "%s %15s\n" "Pull" "       Pull compose images; asks about disabled";
  printf "%s %15s\n" "Create" "     Create service";
  printf "%s %15s\n" "Remove" "     Remove service";
  printf "%s %15s\n" "Version" "    Display version";
  printf "%s %15s\n" "Update" "     Update script";
  printf "%s %15s\n" "Ports" "      Show ports from ENV file";
  printf "%s %15s\n" "Edit" "       Edit service";
  printf "%s %15s\n" "Env" "        Edit env file";

}

while getopts "ha:f:s:e:" options; do
  case "${options}" in
    a) action=${OPTARG} ;;
    f|s) folder=${OPTARG} ;;
    e) envFile=${OPTARG} ;;
    h|*) Help ; exit 0 ;;
  esac
done

LowerCaseArguments() {
    action=$(echo "$action" | tr '[:upper:]' '[:lower:]')
    folder=$(echo "$folder" | tr '[:upper:]' '[:lower:]')
}


CheckEnv() {
    if [ -z "$envFile" ]; then
        envFile="$SCRIPT_WORKING_DIR/.env"
    fi

    if [ ! -f $envFile ]; then
        echo -e "\033[31mEnv file does not exist...\033[0m [$envFile]"
        exit
    fi

    source $envFile
}

CheckEnvVariables() {
    if [ -z "$COMPOSE_FILE" ]; then
        echo -e "\033[31mVariable not set for:\033[0m [COMPOSE_FILE]"
        exit
    fi

    if [ -z "$COMPOSE_FILE_DISABLED" ]; then
        echo -e "\033[31mVariable not set for:\033[0m [COMPOSE_FILE_DISABLED]"
        exit
    fi

    if [ -z "$STUB_FILE" ]; then
        echo -e "\033[31mVariable not set for:\033[0m [STUB_FILE]"
        exit
    fi

    if [ -z "$APPS" ]; then
        echo -e "\033[31mVariable not set for:\033[0m [APPS]"
        exit
    fi
}

CheckDockerCompose() {
    if docker compose version &> /dev/null ; then DockerBin="docker compose" ;
    elif docker-compose -v &> /dev/null; then DockerBin="docker-compose" ;
    printf "%s\n" "No docker binaries available, exiting."
    exit 1
    fi
}

CheckStatus() {
    CheckFolderSupplied $1
    status=$($DockerBin ls -a --filter name=$1 --format=table | grep -Eos '(running|paused|stopped|exited)')
     if [ -n "$status" ]; then
        return 0
    else
        return 1
    fi
}

ReturnStatus() {
    CheckFolderSupplied $1
    status=$($DockerBin ls -a --filter name="$1" --format=table | grep -w "^$1 " | grep -Eo '(exited\([0-9]+\)|running\([0-9]+\)|paused\([0-9]+\)|stopped\([0-9]+\))' | paste -sd ', ' -)

    if [ -n "$status" ]; then
        echo $status
    else
        echo " - "
    fi
}

CheckFolderSupplied() {
    if [ -z "$1" ]; then
        echo "Service name not supplied..."
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
    case $action in
        up)
            printf "%s\n" "--- Starting services ---"
            SimpleAction "up -d" "$folder"
            ;;
        down)
            printf "%s\n" "--- Stopping services ---"
            SimpleAction "down" $folder
            ;;
        start)
            Start $folder
            ;;
        stop)
            Stop $folder
            ;;
        restart)
            printf "%s\n" "--- Restarting services ---"
            SimpleAction "restart" $folder
            ;;
        build)
            printf "%s\n" "--- Building services ---"
            SimpleAction "build" $folder
            ;;
        pause)
            printf "%s\n" "--- Pausing services ---"
            SimpleAction "pause" $folder
            ;;
        unpause)
            printf "%s\n" "--- Unpausing services ---"
            SimpleAction "unpause" $folder
            ;;
        enable)
            echo -e "\033[32mEnabling service\033[0m [$folder]"
            Toggle enable $folder
            ;;
        disable)
            echo -e "\033[31mDisabling service\033[0m [$folder]"
            Toggle disable $folder
            ;;
        list)
            List
            ;;
        images)
            ShowImages list
            ;;
        pull)
            ShowImages pull
            ;;
        create)
            printf "%s\n" "--- Creating service ---"
            Create $folder
            ;;
        remove)
            Remove $folder
            ;;
        version)
            printf "%s\n" "--- Version ${VERSION} ---"
            ;;
        update)
            CheckVersion "silent"
            ;;
        ports)
            CheckPorts
            ;;
        edit)
            EditFile $folder
            ;;
        env)
            EditFile env
            ;;
        help)
            Help
            ;;
        *)
            echo "Invalid option. Please use up, down, restart, list, images, pull, create, enable or disable."
            Help
            exit
            ;;
    esac
    if [ -z "$action" ]; then
        echo "Invalid option. Please use up, down, restart, list, images, pull, create, enable or disable."
        exit
    fi
}

CheckVersion() {
    local silent="$1"  # Accept an optional parameter

    ### Check if LATEST_RELEASE is empty and skip if so
    if [[ -z "$LATEST_RELEASE" ]]; then
        return
    fi

    ### Bypass if all
    if [[ "$folder" == "all" ]] ; then
        return
    fi
    
    ### Version check & initiate self update
    if [[ "$VERSION" != "$LATEST_RELEASE" ]] ; then
        printf "New version available! %b%s%b ⇒ %b%s%b \n Change Notes: %s \n" "$c_yellow" "$VERSION" "$c_reset" "$c_green" "$LATEST_RELEASE" "$c_reset" "$LATEST_CHANGES"
        if [[ -z "$AutoUp" ]] ; then
            read -r -p "Would you like to update? y/[n]: " SelfUpdate
            [[ "$SelfUpdate" =~ [yY] ]] && Update
        fi
    elif [[ "$silent" ]]; then
        # Print "Already up-to-date" message only if `silent` is set
        printf "%s\n" "--- Already up-to-date ---"
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
  local tmp_script tmp_dc dc_path
  dc_path="$SCRIPT_WORKING_DIR/dc.bash"

  if [[ -z "$(builtin type -P curl)" && -z "$(builtin type -P wget)" ]]; then
    printf "curl/wget not available - download the update manually: %s \n" "$GITHUB"
    return
  fi

  tmp_script="$(mktemp)" || return
  tmp_dc="$(mktemp)" || { rm -f "$tmp_script"; return; }

  if ! DownloadFile "$GITHUB_RAWURL" "$tmp_script" || ! DownloadFile "$GITHUB_RAW_DC" "$tmp_dc"; then
    rm -f "$tmp_script" "$tmp_dc"
    printf "Download failed. Script was not changed.\n"
    return
  fi

  cp "$SCRIPT_PATH" "$SCRIPT_PATH".bak
  if [[ -f "$dc_path" ]]; then
    cp "$dc_path" "$dc_path".bak
  fi

  if ! cp "$tmp_script" "$SCRIPT_PATH" || ! cp "$tmp_dc" "$dc_path"; then
    cp "$SCRIPT_PATH".bak "$SCRIPT_PATH"
    if [[ -f "$dc_path".bak ]]; then
      cp "$dc_path".bak "$dc_path"
    fi
    rm -f "$tmp_script" "$tmp_dc"
    printf "Could not install the update.\n"
    return
  fi

  chmod +x "$SCRIPT_PATH"
  rm -f "$tmp_script" "$tmp_dc"
  printf "\n%s\n" "--- starting over with the updated version ---"
  exec "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}" # run the new script with old arguments
  exit 1 # exit the old instance
}

Update() {
  cd "$SCRIPT_WORKING_DIR" || { printf "Path error, skipping update.\n" ; return ; }
  if [[ -n "$(builtin type -P git)" ]] && [[ "$(git ls-remote --get-url 2>/dev/null)" =~ .*"causefx/compose".* ]] ; then
    printf "\n%s\n" "Pulling the latest version."
    git pull --force || { printf "Git error, manually pull/clone.\n" ; return ; }
    printf "\n%s\n" "--- starting over with the updated version ---"
    cd - || { printf "Path error.\n" ; return ; }
    exec "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}" # run the new script with old arguments
    exit 1 # exit the old instance
  else
    cd - || { printf "Path error.\n" ; return ; }
    UpdateCurl
  fi
}

List() {
    printf "%25s    %s     %s\n" "Service" "Status" "  Container(s)";
    for dir in $APPS/*/; do
        path=$(basename $dir)
        status=$(ReturnStatus $path)
        if [ -z "$status" ]; then
            status="No container"
        fi
        if [ -f "$dir/$COMPOSE_FILE" ]; then
            #echo -e $path ['\033[32menabled\033[0m'] - [$status]
            printf "%25s    %b%s%b     %s\n" $path "$c_green" "Enabled " "$c_reset" $status;
        fi
        if [ -f "$dir/$COMPOSE_FILE_DISABLED" ]; then
            #echo -e $path ['\033[31mdisabled\033[0m'] - [$status]
            printf "%25s    %b%s%b     %s\n" $path "$c_red" "Disabled" "$c_reset" $status;
        fi
    done
}

Toggle() {
    action=$1
    folder=$2
    CheckFolderSupplied $2
    fileName=$( [ "$action" == "enable" ] && echo "$COMPOSE_FILE_DISABLED" || echo "$COMPOSE_FILE" )
    newFileName=$( [ "$action" == "enable" ] && echo "$COMPOSE_FILE" || echo "$COMPOSE_FILE_DISABLED" )

    for file in "$APPS/$folder"/*; do
        if [ -f "$file" ] && [ "${file##*/}" == $fileName ]; then
            if [ $newFileName == $COMPOSE_FILE_DISABLED ]; then
                if CheckStatus $folder; then
                    read -p "Service is currently running, do you want to stop and remove it? (y/n) " removeAnswer
                    if [[ "$removeAnswer" == [yY] ]]; then
                        echo "Stopping and removing container..."
                        $DockerBin --file $APPS/$folder/$COMPOSE_FILE --env-file $envFile down
                        echo "Service removed..."
                    else
                        echo "Keeping service..."
                    fi
                fi
            fi
            mv "$file" "$APPS/$folder/$newFileName"
        fi
    done
    if [ ! -f "$APPS/$folder/$COMPOSE_FILE" ] && [ ! -f "$APPS/$folder/$COMPOSE_FILE_DISABLED" ]; then
        echo "Service does not exist"
    else
        echo "Service $action""d"
    fi
}

Remove() {
    echo "Removing service..."
    CheckFolderSupplied $1
    if CheckStatus $1; then
        echo "Service is running... stopping now..."
        $DockerBin --file $APPS/$1/$COMPOSE_FILE --env-file $envFile down
    fi
    if [ -d "$APPS/$1" ]; then
        read -p "Are you sure you want to delete the service folder: $APPS/$1? (y/n) " removeAnswer
        if [[ "$removeAnswer" == [yY] ]]; then
            read -p "Are you absolutely sure? This cannot be undone (y/n) " removeAnswerConfirm
            if [[ "$removeAnswerConfirm" == [yY] ]]; then
                echo "Deleting folder..."
                rm -r $APPS/$1
                echo "Folder deleted..."
            else
                echo "Keeping folder..."
            fi
        else
            echo "Keeping folder..."
        fi
    else
        echo "Service does not exist..."
    fi
}

BulkAction() {
    if [ -z "$2" ] || [ "$2" == "all" ]; then
        if [ "$2" != "all" ]; then
            read -p "No folder/service was provided - Would you like to loop through all services? ([Y]es/[n]o) " answer
        else
            answer="Y"
        fi
        if [[ "$answer" == [yY] ]]; then
            for dir in $APPS/*/; do
                if [ -f "$dir/$COMPOSE_FILE" ]; then
                    $DockerBin --file $dir$COMPOSE_FILE --env-file $envFile $1
                fi
            done
        else
            echo "Exiting"
        fi
        exit
    else
        if [ -f "$APPS/$2/$COMPOSE_FILE" ]; then
            printf "%s\n" "--- Performing actions for $2 ---"
            $DockerBin --file $APPS/$2/$COMPOSE_FILE --env-file $envFile $1
        fi
    fi
}

SimpleAction() {
    if CheckFolderSuppliedNoExit "$2"; then
        BulkAction "$1" "$2"
    else
        BulkAction "$1"
    fi
}

Stop() {
    if CheckFolderSuppliedNoExit "$1"; then
        BulkAction stop "$1"
    else
        BulkAction stop
    fi
}

EditFile() {
    if [ "$1" == "env" ]; then
        file_to_edit="$envFile"
    else
        file_to_edit="$APPS/$1/$COMPOSE_FILE"
        backup_file_to_edit="$APPS/$1/$COMPOSE_FILE_DISABLED"
        
        # Only check the folder if $1 is not "env"
        if ! CheckFolderSuppliedNoExit "$1"; then
            echo -e "\033[31mError: No service name supplied\033[0m"
            exit 1
        fi
    fi

    # Check for existence of files
    if [ -f "$file_to_edit" ]; then
        echo -e "\033[32mUsing primary file: $file_to_edit\033[0m"
    elif [ -f "$backup_file_to_edit" ]; then
        echo -e "\033[33mPrimary file not found. Using backup file: $backup_file_to_edit\033[0m"
        file_to_edit="$backup_file_to_edit"
    else
        echo -e "\033[31mError: Neither primary nor backup file exists\033[0m"
        echo -e "\033[31mChecked:\n - $file_to_edit\n - $backup_file_to_edit\033[0m"
        exit 1
    fi
    
    printf "%s\n" "--- Editing $1 file ---"

    if ! command -v nano &> /dev/null; then
        vim "$file_to_edit"
    else
        nano "$file_to_edit"
    fi
}


Start() {
    if CheckFolderSuppliedNoExit "$1"; then
        BulkAction start "$1"
    else
        BulkAction start
    fi
    #CheckFolderSupplied $1
    #if CheckStatus $1; then
    #    echo "Starting service now..."
    #    $DockerBin --file $APPS/$1/$COMPOSE_FILE --env-file $envFile start
    #else
    #    $DockerBin --file $APPS/$1/$COMPOSE_FILE --env-file $envFile up -d
    #fi
}

Up() {
    if CheckFolderSuppliedNoExit $1; then
        BulkAction "up -d" "$1"
    else
        BulkAction "up -d"
    fi
}

Down() {
    if CheckFolderSuppliedNoExit $1; then
        BulkAction down $1
    else
        BulkAction down
    fi
}

Create() {
    if ! CheckFolderSuppliedNoExit $1; then
        read -r -p "What should we name the service: " folder
        folder=$(echo "$folder" | tr '[:upper:]' '[:lower:]')
    fi
    

    if [ ! -f "$STUB_FILE" ]; then
        echo -e "\033[31mError: Stub File does not exist\033[0m [$folder]"
        exit
    fi

    if [ -d "$APPS/$folder" ]; then
        echo -e "\033[33mService already exists\033[0m [$folder]"
        exit
    fi

    read -r -p "Enter the container image: " image
    if [ -z "$image" ]; then
        echo "Image not supplied..."
        exit
    fi

    mkdir -p "$APPS/$folder"
    cp "$STUB_FILE" "$APPS/$folder/$COMPOSE_FILE_DISABLED"
    sed -i -e "s|{{SERVICE}}|$folder|g" -e "s|{{IMAGE}}|$image|g" "$APPS/$folder/$COMPOSE_FILE_DISABLED"
    echo -e "\033[32mService created successfully\033[0m [$folder]"
    echo -e "\033[33mService is disabled - please edit the compose file before enabling\033[0m"
    
    exit
}

CheckPorts() {
    printf "%15s    %s\n" "Service" "Port(s)";
    declare -A ports  # Associative array to store service names and their ports

    while IFS='=' read -r key value; do
        # Check if the line contains `_PORT_` and is not a comment
        if [[ $key == *_PORT_* && ! $key =~ ^# ]]; then
            # Extract the part before `_PORT_` and capitalize it
            name="${key%%_PORT_*}"
            # Append the port if the service name already exists, otherwise create new entry
            if [[ -n "${ports[$name]}" ]]; then
                ports[$name]+=" | $value"
            else
                ports[$name]="$value"
            fi
        fi
    done < "$envFile"

    # Output the services and their ports
    for name in "${!ports[@]}"; do
        printf "%15s    %s\n" "${name^^}:" "${ports[$name]}"
    done
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

    output=$($DockerBin --file "$file" --env-file "$envFile" config --images 2>"$err")
    status=$?
    if [ "$status" -eq 0 ]; then
        rm -f "$err"
        while IFS= read -r line || [ -n "$line" ]; do
            line="$(CleanImageRef "$line")"
            [ -n "$line" ] && printf '%s\n' "$line"
        done <<< "$output"
        return 0
    fi

    output=$($DockerBin --file "$file" --env-file "$envFile" config 2>"$err")
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
        echo -e "${c_yellow}Warning:${c_reset} could not resolve every image in $(basename "$(dirname "$file")")/$(basename "$file")" >&2
    fi

    if [ ${#refs[@]} -gt 0 ]; then
        printf '%s\n' "${refs[@]}"
    fi
}

PrintMissingTags() {
    local ref missing=0
    for ref in "$@"; do
        if [ "$(ImageTag "$ref")" = "-" ]; then
            missing=$((missing+1))
        fi
    done
    if [ "$missing" -gt 0 ]; then
        printf "%s\n" "${missing} image(s) have no tag and will pull as latest."
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
    local dir path path_lc state file img tag row_key state_color state_label
    local answer img_ref include_disabled=0 pull_enabled=0
    local had_nullglob=0

    if shopt -q nullglob; then
        had_nullglob=1
    fi
    shopt -s nullglob

    if [ -n "$folder" ] && [ "$folder" != "all" ]; then
        printf "%s\n" "--- Compose images for ${folder} ---"
    else
        printf "%s\n" "--- Compose images ---"
    fi
    printf "%25s  %-8s  %-18s  %s\n" "Service" "Status" "Tag" "Image"

    for dir in "$APPS"/*/; do
        [ -d "$dir" ] || continue
        path="$(basename "$dir")"
        path_lc="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
        if [ -n "$folder" ] && [ "$folder" != "all" ] && [ "$path_lc" != "$folder" ]; then
            continue
        fi

        for state in Enabled Disabled; do
            if [ "$state" = "Enabled" ]; then
                file="${dir}${COMPOSE_FILE}"
                state_color="$c_green"
                state_label="Enabled "
            else
                file="${dir}${COMPOSE_FILE_DISABLED}"
                state_color="$c_red"
                state_label="Disabled"
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
                printf "%25s  %b%s%b  %-18s  %s\n" "$path" "$state_color" "$state_label" "$c_reset" "$tag" "$img"
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
    done

    if [ "$had_nullglob" -eq 0 ]; then
        shopt -u nullglob
    fi

    if [ -n "$folder" ] && [ "$folder" != "all" ] && [ "$found_file" -eq 0 ]; then
        echo "Service does not exist..."
        exit 1
    fi

    for img_ref in "${disabled_refs[@]}"; do
        if [ -z "${seen_enabled[$img_ref]+x}" ]; then
            disabled_only_refs+=("$img_ref")
        fi
    done

    printf "\n%s\n" "${count} image(s) listed, ${#pull_refs[@]} unique."
    if [ ${#disabled_only_refs[@]} -gt 0 ]; then
        printf "%s\n" "${#disabled_only_refs[@]} image(s) are only used by disabled services."
    fi

    if [ "$mode" != "pull" ]; then
        PrintMissingTags "${pull_refs[@]}"
        return 0
    fi

    if [ ${#enabled_refs[@]} -eq 0 ] && [ ${#disabled_only_refs[@]} -eq 0 ]; then
        echo "No images to pull."
        return 0
    fi

    if [ ${#enabled_refs[@]} -gt 0 ]; then
        if [ -n "$folder" ]; then
            pull_enabled=1
        else
            read -r -p "Pull ${#enabled_refs[@]} unique image(s) from enabled services? ([Y]es/[n]o) " answer
            if [[ "$answer" == [yY] ]]; then
                pull_enabled=1
            fi
        fi
    fi

    if [ ${#disabled_only_refs[@]} -gt 0 ]; then
        if [ "$pull_enabled" -eq 1 ]; then
            read -r -p "Also pull ${#disabled_only_refs[@]} image(s) from disabled services? ([y]es/[N]o) " answer
        else
            read -r -p "Pull ${#disabled_only_refs[@]} image(s) from disabled services? ([y]es/[N]o) " answer
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
        echo "No images to pull."
        return 0
    fi

    PrintMissingTags "${chosen_refs[@]}"

    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${c_red}docker is not available, cannot pull images.${c_reset}"
        exit 1
    fi

    total=${#chosen_refs[@]}
    for img_ref in "${chosen_refs[@]}"; do
        printf "%s\n" "--- Pulling (${index}/${total}) ${img_ref} ---"
        if ! docker pull "$img_ref"; then
            echo -e "${c_red}Failed to pull${c_reset} [${img_ref}]"
            failed=$((failed+1))
        fi
        index=$((index+1))
    done

    if [ "$failed" -gt 0 ]; then
        echo -e "${c_red}${failed} image(s) failed to pull${c_reset}"
        exit 1
    fi
    echo -e "${c_green}Pulled ${total} image(s)${c_reset}"
}

# Do the Things
CheckEnv;
CheckEnvVariables;
LowerCaseArguments;
CheckDockerCompose;
CheckVersion;
CheckAction;

exit 0
