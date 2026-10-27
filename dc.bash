# Sourced from ~/.bashrc. See README.md.
COMPOSE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_SH="$COMPOSE_HOME/compose.sh"

dc() {
    local action="${1:-}"
    shift || true
    local service=""
    local -a extra=()
    if [[ $# -gt 0 && "$1" != -* ]]; then
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

_dc_completions() {
    local cur opts_a opts_s apps dir name
    cur="${COMP_WORDS[COMP_CWORD]}"

    opts_a="$(awk '
        /^# @actions$/ {p=1; next}
        /^# @end$/ {p=0}
        p && index($0, "|") {
            split($0, a, "|")
            printf "%s ", a[1]
        }
    ' "$COMPOSE_SH")"
    opts_a="${opts_a% }"
    apps="$(_dc_apps_dir)"
    opts_s="all"
    for dir in "$apps"/*/; do
        [[ -d "$dir" ]] || continue
        name="$(basename "$dir")"
        opts_s+=" $name"
    done

    if [[ "$COMP_CWORD" -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "$opts_a" -- "$cur") )
    elif [[ "$COMP_CWORD" -eq 2 ]]; then
        COMPREPLY=( $(compgen -W "$opts_s" -- "$cur") )
    fi
}

complete -F _dc_completions dc
