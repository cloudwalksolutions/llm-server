#!/usr/bin/env bash

load_target() {
    if [[ -f .env ]]; then
        # shellcheck disable=SC1091
        source .env
    fi
    REMOTE_HOST="${LLM_SSH_HOST:-}"
    REMOTE_USER="${LLM_SSH_USER:-}"
    REMOTE_JUMP="${LLM_SSH_JUMP:-}"

    # Not fatal: offline work (rendering, validation) needs no credentials.
    if _is_local_host; then
        SSH_AUTH="local"
    elif [[ -n "${SSH_KEY:-}" ]]; then
        SSH_AUTH="key"
        SSH_KEY="${SSH_KEY/#\~/$HOME}"
    elif [[ -n "${SSH_PASS:-}" ]]; then
        SSH_AUTH="password"
    else
        SSH_AUTH="none"
    fi

    export REMOTE_HOST REMOTE_USER REMOTE_JUMP SSH_AUTH SSH_KEY SSH_PASS
}

# True if REMOTE_HOST is this machine (no SSH needed)
_is_local_host() {
    [[ "$REMOTE_HOST" == "localhost" || "$REMOTE_HOST" == "127.0.0.1" || "$REMOTE_HOST" == "$(hostname)" ]] && return 0
    hostname -I 2>/dev/null | tr ' ' '\n' | grep -qx "$REMOTE_HOST"
}

# SSH command as an argv array, so nothing goes through eval
_ssh_argv() {
    if [[ "$SSH_AUTH" == "key" ]]; then
        printf '%s\0' ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no
    else
        printf '%s\0' sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no
    fi
    if [[ -n "${REMOTE_JUMP:-}" ]]; then
        printf '%s\0' -J "$REMOTE_JUMP"
    fi
}

_ssh_run() {
    local -a argv=()
    mapfile -d '' -t argv < <(_ssh_argv)
    "${argv[@]}" "$@"
}

_no_auth() {
    _cfg_err "No SSH authentication configured for $REMOTE_USER@$REMOTE_HOST"
    echo "Set SSH_KEY or SSH_PASS in .env" >&2
}

test_ssh() {
    case "$SSH_AUTH" in
        local) return 0 ;;
        none)  _no_auth; return 1 ;;
        *)     _ssh_run -o ConnectTimeout=5 "$REMOTE_USER@$REMOTE_HOST" true 2>/dev/null ;;
    esac
}

remote_exec() {
    case "$SSH_AUTH" in
        local) bash -c "$*"; return ;;
        none)  _no_auth; return 1 ;;
        *)     _ssh_run "$REMOTE_USER@$REMOTE_HOST" "$*" ;;
    esac
}

# Single-quote a string for safe interpolation into a remote shell
_shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

remote_exec_sudo() {
    if [[ "$SSH_AUTH" == "none" ]]; then
        _no_auth
        return 1
    fi
    if [[ "$SSH_AUTH" == "local" ]]; then
        if [[ -n "${SSH_PASS:-}" ]]; then
            printf '%s\n' "$SSH_PASS" | sudo -S bash -c "$*"
        else
            sudo bash -c "$*"
        fi
    elif [[ -n "${SSH_PASS:-}" ]]; then
        _ssh_run "$REMOTE_USER@$REMOTE_HOST" "printf '%s\n' $(_shq "$SSH_PASS") | sudo -S bash -c $(_shq "$*")"
    else
        _ssh_run "$REMOTE_USER@$REMOTE_HOST" "sudo bash -c $(_shq "$*")"
    fi
}

# Write stdin to a privileged path on the target.
# remote_exec_sudo consumes stdin to feed `sudo -S` the password, so content
# must never be piped through it — it arrives empty. Stage via a temp file.
remote_write_sudo() {
    local dest="$1" mode="${2:-644}" tmp owner
    tmp="/tmp/.llama-deploy.$$.${RANDOM}"

    remote_exec "cat > $tmp" || return 1
    owner=$(remote_exec "stat -c '%U:%G' $dest 2>/dev/null" \
         || remote_exec "stat -c '%U:%G' ${dest%/*} 2>/dev/null" || echo "")
    if [[ -n "$owner" ]]; then
        remote_exec_sudo "install -m $mode -o ${owner%%:*} -g ${owner##*:} $tmp $dest && rm -f $tmp"
    else
        remote_exec_sudo "install -m $mode $tmp $dest && rm -f $tmp"
    fi
}

# Read a key from an instance conf on the target.
# `grep | cut || echo default` can never work: the pipeline exits with cut's
# status, which is always 0. Check for emptiness explicitly instead.
remote_conf_value() {
    local file="$1" key="$2" default="${3:-}" value=""
    value=$(remote_exec "grep '^$key=' $file 2>/dev/null | cut -d= -f2-" 2>/dev/null) || value=""
    value="${value%$'\r'}"
    if [[ -z "$value" ]]; then
        printf '%s' "$default"
    else
        printf '%s' "$value"
    fi
}
