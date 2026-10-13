#!/usr/bin/env bash
# Let the GPU of a unified-memory AMD host take its memory from GTT, up to 120 GiB, instead of a
# fixed BIOS carve-out. Sets the kernel arguments; they take effect at the next boot, together
# with the BIOS UMA frame buffer set to its minimum. `make verify` checks both.
#
# Usage: ./scripts/gpu-memory.sh [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

load_config || exit 1
test_ssh || { echo -e "${RED}Cannot reach target${NC}" >&2; exit 1; }

WANT="ttm.pages_limit=31457280"
args=$(remote_exec_sudo "grubby --info=DEFAULT" | sed -n 's/^args="\(.*\)"$/\1/p')
echo "default kernel args: $args"

if [[ " $args " == *" $WANT "* && "$args" != *amd_iommu=off* && "$args" != *amdgpu.gttsize* ]]; then
    echo -e "${GREEN}already set${NC}"
    exit 0
fi

CMD="grubby --update-kernel=ALL --remove-args='amd_iommu amdgpu.gttsize ttm.pages_limit' --args='$WANT'"
if ((DRY_RUN)); then
    echo -e "${YELLOW}DRY RUN — would run:${NC} $CMD"
    exit 0
fi
remote_exec_sudo "$CMD"
echo -e "${GREEN}set${NC}: $(remote_exec_sudo "grubby --info=DEFAULT" | sed -n 's/^args=//p')"
echo "Next: set the BIOS UMA frame buffer to its minimum, reboot, then make verify"
