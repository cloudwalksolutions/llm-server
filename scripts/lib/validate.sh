#!/usr/bin/env bash

_cfg_err() { echo -e "${RED}Config error:${NC} $*" >&2; }

# yq prints the literal string "null" for a missing key, which would otherwise
# reach the llama-server CLI as `-c null`.
_require_int() {
    local name="$1" value="$2"
    if [[ "$value" == "null" || -z "$value" ]]; then
        _cfg_err "$name is not set"
        return 1
    fi
    if [[ ! "$value" =~ ^[0-9]+$ ]] || ((value <= 0)); then
        _cfg_err "$name must be a positive integer (got '$value')"
        return 1
    fi
}

# Same, but 0 is legal. llama.cpp uses 0 to mean "disabled" for several knobs
# (--cache-reuse 0 is its own default), so the schema has to be able to say it.
_require_uint() {
    local name="$1" value="$2"
    if [[ "$value" == "null" || -z "$value" ]]; then
        _cfg_err "$name is not set"
        return 1
    fi
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        _cfg_err "$name must be a non-negative integer (got '$value')"
        return 1
    fi
}

_require_enum() {
    local name="$1" value="$2" allowed=" ${*:3} "
    if [[ "$allowed" != *" $value "* ]]; then
        _cfg_err "$name must be one of:${*:3} (got '$value')"
        return 1
    fi
}

# A non-empty scalar. Separate from _require_int because an unset string reaches
# the CLI as the literal "null" and fails as an opaque runtime error instead.
_require_str() {
    local name="$1" value="$2"
    if [[ -z "$value" || "$value" == "null" ]]; then
        _cfg_err "$name is not set"
        return 1
    fi
}

# Rendered confs are read by systemd's EnvironmentFile, which is line-oriented
# and last-wins. A newline in any value therefore injects a whole extra
# assignment — and CONTAINER_IMAGE is the last line rendered, so a crafted value
# there could append LLAMA_API_KEY= and turn off auth on the only reachable path.
_require_no_control_chars() {
    local name="$1" value="$2"
    if [[ "$value" == *[$'\n\r\t']* || "$value" =~ [[:cntrl:]] ]]; then
        _cfg_err "$name contains a control character; it would corrupt the rendered conf"
        return 1
    fi
}

_require_match() {
    local name="$1" value="$2" pattern="$3"
    [[ "$value" =~ $pattern ]] || { _cfg_err "$name must match $pattern (got '$value')"; return 1; }
}

_require_safe_path() {
    local name="$1" value="$2" kind="$3" pattern='^[A-Za-z0-9_./-]+$'
    [[ "$kind" == absolute ]] && pattern='^/[A-Za-z0-9_./-]+$'
    [[ "$kind" == relative ]] && pattern='^[A-Za-z0-9_][A-Za-z0-9_./-]*$'
    _require_match "$name" "$value" "$pattern" || return 1
    [[ "/$value/" == *"/../"* ]] && { _cfg_err "$name may not contain '..'"; return 1; }
    return 0
}
