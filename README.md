# Docker Compose Helper
Personal docker compose management

## Setup
Coming soon

### .bashrc
#### Change path to compose file on both functions
```
# Define helper function
function dc { /home/docker/docker/compose.sh -a "$1" -s "$2"; }

# Define the autocompletion function for dc
_dc_completions() {
    local cur prev opts_a opts_s
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    
    # Define possible completions for the first argument (for -a)
    opts_a="action help up down start stop restart pause unpause enable disable list create remove version update ports edit env"
    
    # Populate opts_s with directories in a specific folder for the second argument (for -s)
    opts_s=$(ls -d /home/docker/docker/*/ 2>/dev/null | xargs -n 1 basename)

    # Determine whether we're completing the first or second argument
    if [[ "$COMP_CWORD" -eq 1 ]]; then
        # Suggest options for the first argument
        COMPREPLY=( $(compgen -W "$opts_a" -- "$cur") )
    elif [[ "$COMP_CWORD" -eq 2 ]]; then
        # Suggest options for the second argument
        COMPREPLY=( $(compgen -W "$opts_s" -- "$cur") )
    fi
}

# Register the completion function for dc
complete -F _dc_completions dc
```

## Changes

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
