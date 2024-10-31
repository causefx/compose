#!/bin/bash
VERSION=v1.1.0
### ChangeNotes: Added new list visual, run version check on start of script - See README.md for past changes.
GITHUB="https://github.com/causefx/compose"
GITHUB_RAWURL="https://raw.githubusercontent.com/causefx/compose/main/compose.sh"
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
    status=$($DockerBin ls -a --filter name=$1 --format=table | grep -Eo '(running|paused|stopped|exited)')
     if [ -n "$status" ]; then
        return 0
    else
        return 1
    fi
}

ReturnStatus() {
    CheckFolderSupplied $1
    status=$($DockerBin ls -a --filter name=$1 --format=table | grep -Eo '(running|paused|stopped|exited)')
     if [ -n "$status" ]; then
        echo $status
    else
        echo "N/A"
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
            echo "Starting services..."
            SimpleAction "up -d" "$folder"
            ;;
        down)
            echo "Stopping services..."
            SimpleAction "down" $folder
            ;;
        start)
            Start $folder
            ;;
        stop)
            Stop $folder
            ;;
        restart)
            echo "Restarting services..."
            SimpleAction "restart" $folder
            ;;
        pause)
            echo "Pausing services..."
            SimpleAction "pause" $folder
            ;;
        unpause)
            echo "Unpausing services..."
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
        create)
            echo "Creating service..."
            Create $folder
            ;;
        remove)
            Remove $folder
            ;;
        version)
            CheckVersion
            ;;
        *)
            echo "Invalid option. Please use up, down, restart, list, create, enable or disable."
            Help
            exit
            ;;
    esac
    if [ -z "$action" ]; then
        echo "Invalid option. Please use up, down, restart, list, create, enable or disable."
        exit
    fi
}

CheckVersion() {
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
    fi
}

UpdateCurl() {
  cp "$SCRIPT_PATH" "$SCRIPT_PATH".bak
  if [[ $(builtin type -P curl) ]]; then
    curl -L $GITHUB_RAWURL > "$SCRIPT_PATH" ; chmod +x "$SCRIPT_PATH"
    printf "\n%s\n" "--- starting over with the updated version ---"
    exec "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}" # run the new script with old arguments
    exit 1 # exit the old instance
  elif [[ $(builtin type -P wget) ]]; then
    wget $GITHUB_RAWURL -O "$SCRIPT_PATH" ; chmod +x "$SCRIPT_PATH"
    printf "\n%s\n" "--- starting over with the updated version ---"
    exec "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}" # run the new script with old arguments
    exit 1 # exit the old instance
  else
    printf "curl/wget not available - download the update manually: %s \n" "$GITHUB"
  fi
}

Update() {
  cd "$SCRIPT_WORKING_DIR" || { printf "Path error, skipping update.\n" ; return ; }
  if [[ $(builtin type -P git) ]] && [[ "$(git ls-remote --get-url 2>/dev/null)" =~ .*"mag37/dockcheck".* ]] ; then
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
    printf "%15s    %s     %s\n" "Service" "Status" "  Container";
    for dir in $APPS/*/; do
        path=$(basename $dir)
        status=$(ReturnStatus $path)
        if [ -z "$status" ]; then
            status="No container"
        fi
        if [ -f "$dir/$COMPOSE_FILE" ]; then
            #echo -e $path ['\033[32menabled\033[0m'] - [$status]
            printf "%15s    %b%s%b     %s\n" $path "$c_green" "Enabled " "$c_reset" $status;
        fi
        if [ -f "$dir/$COMPOSE_FILE_DISABLED" ]; then
            #echo -e $path ['\033[31mdisabled\033[0m'] - [$status]
            printf "%15s    %b%s%b     %s\n" $path "$c_red" "Disabled" "$c_reset" $status;
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
        echo "$APPS/$2/$COMPOSE_FILE"
        if [ -f "$APPS/$2/$COMPOSE_FILE" ]; then
            echo "doing it for $2"
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

# Do the Things
CheckEnv;
CheckEnvVariables;
LowerCaseArguments;
CheckDockerCompose;
CheckVersion;
CheckAction;

exit 0
