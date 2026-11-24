#!/usr/bin/env bash

_LIB="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=output.sh
source "$_LIB/output.sh"
# shellcheck source=validate.sh
source "$_LIB/validate.sh"
# shellcheck source=config.sh
source "$_LIB/config.sh"
# shellcheck source=comfyui.sh
source "$_LIB/comfyui.sh"
# shellcheck source=remote.sh
source "$_LIB/remote.sh"
# shellcheck source=live.sh
source "$_LIB/live.sh"
# shellcheck source=router.sh
source "$_LIB/router.sh"
# shellcheck source=tunnel.sh
source "$_LIB/tunnel.sh"
# shellcheck source=bench.sh
source "$_LIB/bench.sh"
