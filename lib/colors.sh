#!/usr/bin/env bash
# Terminal output helpers

# Real escape bytes (via $'…') so colors render under cat/printf as well as echo -e.
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m' # No Color

info()    { echo -e "${BLUE}▸${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
error()   { echo -e "${RED}✗${NC} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}$*${NC}\n"; }
dim()     { echo -e "${DIM}$*${NC}"; }

# confirm <prompt> [default]
#   default 'Y' → benign      (Enter = yes; under WS_ASSUME_YES auto-yes, returns 0)
#   default 'N' → destructive (Enter = no;  under WS_ASSUME_YES auto-NO,  returns 1)
#   default omitted → behaves like the original bare [y/N] prompt: empty reply = no,
#     and under WS_ASSUME_YES it auto-NOs (fail-safe).
# Under WS_ASSUME_YES the chosen answer is ALWAYS echoed ("y (auto)" / "n (auto)")
# so headless logs show what happened, and `read` is never reached (no hang).
confirm() {
  local prompt="${1:-Continue?}"
  local default="${2:-N}"
  local hint="[y/N]"; [[ "$default" =~ ^[Yy]$ ]] && hint="[Y/n]"
  echo -en "${YELLOW}${prompt} ${hint}${NC} "
  if [[ -n "${WS_ASSUME_YES:-}" ]]; then
    if [[ "$default" =~ ^[Yy]$ ]]; then
      echo "y (auto)"; return 0
    else
      echo "n (auto)"; return 1
    fi
  fi
  local reply
  read -r reply
  [[ -z "$reply" ]] && reply="$default"
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
