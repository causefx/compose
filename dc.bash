# Sourced from ~/.bashrc. See README.md.
COMPOSE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_SH="$COMPOSE_HOME/compose.sh"

# Prints "name|flags|options" for each visible action in the compose.sh ActionSpec.
_dc_actions() {
    awk -F'|' '
        /^# @actions$/ {p=1; next}
        /^# @end$/ {exit}
        p && !/^#/ && NF > 1 && $2 !~ /h/ {print $1 "|" $2 "|" $5}
    ' "$COMPOSE_SH"
}

# Prints the options column for action $1.
_dc_action_opts() {
    local name flags opts
    while IFS='|' read -r name flags opts; do
        if [[ "$name" == "$1" ]]; then
            printf '%s' "$opts"
            return
        fi
    done < <(_dc_actions)
}

# Prints action names whose flags contain $1.
_dc_actions_flag() {
    local name flags out=""
    while IFS='|' read -r name flags _; do
        [[ "$flags" == *"$1"* ]] && out+="$name "
    done < <(_dc_actions)
    printf '%s' "${out% }"
}

dc() {
    local action="${1:-}"
    shift || true
    local service="" flags
    local -a extra=()
    flags="$(awk -F'|' -v a="$action" '
        /^# @actions$/ {p=1; next}
        /^# @end$/ {exit}
        p && $1 == a {print $2; exit}
    ' "$COMPOSE_SH")"
    if [[ "$flags" == *s* && $# -gt 0 && "$1" != -* ]]; then
        service="$1"
        shift
    fi
    extra=("$@")
    if [[ -n "$service" ]]; then
        "$COMPOSE_SH" -a "$action" -s "$service" -- "${extra[@]}"
    elif [[ ${#extra[@]} -gt 0 ]]; then
        "$COMPOSE_SH" -a "$action" -- "${extra[@]}"
    else
        "$COMPOSE_SH" -a "$action"
    fi
}

_dc_apps_dir() {
    local env_file="$COMPOSE_HOME/.env"
    local line value

    if [[ -f "$env_file" ]]; then
        line="$(grep -E '^[[:space:]]*APPS=' "$env_file" | tail -n 1)"
        value="${line#*=}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"
        if [[ -n "$value" && -d "$value" ]]; then
            printf '%s' "$value"
            return
        fi
    fi

    printf '%s' "$COMPOSE_HOME"
}

_dc_archive_dir() {
    local env_file="$COMPOSE_HOME/.env"
    local apps line value

    apps="$(_dc_apps_dir)"
    if [[ -f "$env_file" ]]; then
        line="$(grep -E '^[[:space:]]*ARCHIVE=' "$env_file" | tail -n 1)"
        value="${line#*=}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"
        value="${value//\$APPS/$apps}"
        if [[ -n "$value" ]]; then
            printf '%s' "$value"
            return
        fi
    fi
    printf '%s' "$apps/.archive"
}

_dc_compose_hosts() {
    local file="$HOME/.ssh/compose-hosts" short user
    local opts=""

    [[ -f "$file" ]] || return 0
    while read -r short user; do
        [[ -n "$short" ]] || continue
        opts+=" $short"
    done < "$file"
    printf '%s' "${opts# }"
}

_dc_completions() {
    local cur opts_a opts_s opts_arch opts_hosts apps archive dir name flags opts
    local a_name a_flags a_opts
    cur="${COMP_WORDS[COMP_CWORD]}"

    opts_a=""
    flags=""
    opts=""
    while IFS='|' read -r a_name a_flags a_opts; do
        opts_a+="$a_name "
        if [[ "$a_name" == "${COMP_WORDS[1]:-}" ]]; then
            flags="$a_flags"
            opts="$a_opts"
        fi
    done < <(_dc_actions)
    opts_a="${opts_a% }"
    apps="$(_dc_apps_dir)"
    opts_s="all"
    for dir in "$apps"/*/; do
        [[ -d "$dir" ]] || continue
        name="$(basename "$dir")"
        opts_s+=" $name"
    done
    archive="$(_dc_archive_dir)"
    opts_arch="all"
    for dir in "$archive"/*/; do
        [[ -d "$dir" ]] || continue
        name="$(basename "$dir")"
        opts_arch+=" $name"
    done

    if [[ "$COMP_CWORD" -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "$opts_a" -- "$cur") )
    elif [[ "$COMP_CWORD" -eq 2 && "${COMP_WORDS[1]}" == "docs" ]]; then
        COMPREPLY=( $(compgen -W "$opts_a" -- "$cur") )
    elif [[ "$COMP_CWORD" -eq 2 && "$cur" == -* && -n "$opts" ]]; then
        COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    elif [[ "$COMP_CWORD" -eq 2 && "${COMP_WORDS[1]}" == "unarchive" ]]; then
        COMPREPLY=( $(compgen -W "$opts_arch" -- "$cur") )
    elif [[ "$COMP_CWORD" -eq 2 && ( "${COMP_WORDS[1]}" == "move" || "${COMP_WORDS[1]}" == "rename" ) ]]; then
        COMPREPLY=( $(compgen -W "$opts_s ${opts_arch#all }" -- "$cur") )
    elif [[ "$COMP_CWORD" -eq 2 && "$flags" == *s* ]]; then
        COMPREPLY=( $(compgen -W "$opts_s" -- "$cur") )
    elif [[ "$COMP_CWORD" -eq 2 && -n "$opts" ]]; then
        COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    elif [[ "$COMP_CWORD" -eq 3 && "${COMP_WORDS[1]}" == "move" ]]; then
        opts_hosts="$(_dc_compose_hosts)"
        COMPREPLY=( $(compgen -W "$opts_hosts" -- "$cur") )
    elif [[ "$COMP_CWORD" -eq 3 && "${COMP_WORDS[1]}" == "schedule" && ( "${COMP_WORDS[2]}" == "add" || "${COMP_WORDS[2]}" == "remove" ) ]]; then
        COMPREPLY=( $(compgen -W "$(_dc_actions_flag j)" -- "$cur") )
    elif [[ "$COMP_CWORD" -eq 3 && "$flags" == *s* && -n "$opts" ]]; then
        COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    elif [[ "$COMP_CWORD" -eq 4 && "${COMP_WORDS[1]}" == "schedule" && "${COMP_WORDS[2]}" == "add" ]]; then
        COMPREPLY=( $(compgen -W "$(_dc_action_opts "${COMP_WORDS[3]}")" -- "$cur") )
    fi
}

complete -F _dc_completions dc
