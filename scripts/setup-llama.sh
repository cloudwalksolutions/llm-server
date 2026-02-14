#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CONFIG_FILE="config/llama.yaml"
EXAMPLE_FILE="config/llama.example.yaml"

echo -e "${BLUE}llama-server Configuration Setup${NC}\n"

if [[ -f "$CONFIG_FILE" ]]; then
    echo -e "${YELLOW}$CONFIG_FILE already exists${NC}"
    read -rp "Overwrite? (y/N): " overwrite
    [[ ! "$overwrite" =~ ^[Yy]$ ]] && { echo "Cancelled."; exit 0; }
fi

echo "Copying example config..."
cp "$EXAMPLE_FILE" "$CONFIG_FILE"

echo -e "${GREEN}✓ Created $CONFIG_FILE${NC}\n"
echo "Edit the config to customize:"
echo -e "  ${BLUE}\${EDITOR:-vim} $CONFIG_FILE${NC}"
echo -e "\nOr deploy with defaults:"
echo -e "  ${BLUE}make deploy${NC}"
