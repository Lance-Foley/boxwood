#!/usr/bin/env bash
# Terminal output helpers

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}▸${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
error()   { echo -e "${RED}✗${NC} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}$*${NC}\n"; }
dim()     { echo -e "${DIM}$*${NC}"; }

confirm() {
  local prompt="${1:-Continue?}"
  echo -en "${YELLOW}${prompt} [y/N]${NC} "
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

prompt_choice() {
  local prompt="$1"
  shift
  local options=("$@")
  echo -e "${YELLOW}${prompt}${NC}"
  for i in "${!options[@]}"; do
    echo -e "  ${BOLD}$((i + 1)))${NC} ${options[$i]}"
  done
  echo -en "${YELLOW}Choice: ${NC}"
  read -r choice
  echo "$choice"
}
