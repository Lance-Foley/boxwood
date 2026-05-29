#!/usr/bin/env bats
# Unit tests for confirm() in lib/colors.sh.
#
# confirm <prompt> [default] is destructive-aware:
#   default 'Y' → benign      (Enter = yes; under WS_ASSUME_YES auto-yes,  rc 0)
#   default 'N' → destructive (Enter = no;  under WS_ASSUME_YES auto-NO,   rc 1)
#   default omitted → fail-safe N
# Under WS_ASSUME_YES it ALWAYS echoes the chosen answer ("y (auto)"/"n (auto)")
# and never reaches `read` (no hang). load_ws sources the engine, which sources
# lib/colors.sh, so confirm() is defined in this shell.

load 'helper'

setup() {
  load_ws
}

# ─── WS_ASSUME_YES: benign vs destructive ───────────────────────────────────────

@test "confirm: benign default-Y auto-yeses under WS_ASSUME_YES" {
  export WS_ASSUME_YES=1
  run confirm "Keep going?" Y </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"(auto)"* ]]
}

@test "confirm: destructive default-N auto-NOs under WS_ASSUME_YES" {
  export WS_ASSUME_YES=1
  run confirm "Drop the database?" N </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"(auto)"* ]]
}

@test "confirm: omitted default is fail-safe (auto-NO) under WS_ASSUME_YES" {
  export WS_ASSUME_YES=1
  run confirm "Proceed?" </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"(auto)"* ]]
}

@test "confirm: never blocks on read under WS_ASSUME_YES (no-stdin-hang)" {
  # Closing stdin proves confirm returns without reaching `read`. Both the
  # benign and destructive branches must complete with stdin shut.
  export WS_ASSUME_YES=1
  run confirm "ok?" Y </dev/null
  [ "$status" -eq 0 ]
  run confirm "drop?" N </dev/null
  [ "$status" -ne 0 ]
}

# ─── Interactive (no WS_ASSUME_YES) ─────────────────────────────────────────────
# Piped stdin must reach `read`, so run in a subshell with a real pipe.

@test "confirm: interactive 'y' returns 0" {
  unset WS_ASSUME_YES
  run bash -c "export WS_HOME='$WS_HOME'; unset WS_ASSUME_YES; source '$WS_BIN'; echo y | confirm 'Proceed?'"
  [ "$status" -eq 0 ]
}

@test "confirm: interactive 'n' returns nonzero" {
  unset WS_ASSUME_YES
  run bash -c "export WS_HOME='$WS_HOME'; unset WS_ASSUME_YES; source '$WS_BIN'; echo n | confirm 'Proceed?' Y"
  [ "$status" -ne 0 ]
}

@test "confirm: interactive empty reply applies benign default Y (returns 0)" {
  unset WS_ASSUME_YES
  run bash -c "export WS_HOME='$WS_HOME'; unset WS_ASSUME_YES; source '$WS_BIN'; echo '' | confirm 'Keep?' Y"
  [ "$status" -eq 0 ]
}

@test "confirm: interactive empty reply applies destructive default N (returns nonzero)" {
  unset WS_ASSUME_YES
  run bash -c "export WS_HOME='$WS_HOME'; unset WS_ASSUME_YES; source '$WS_BIN'; echo '' | confirm 'Drop?' N"
  [ "$status" -ne 0 ]
}

@test "confirm: hint reflects the default ([Y/n] for benign, [y/N] for destructive)" {
  export WS_ASSUME_YES=1
  run confirm "benign?" Y </dev/null
  [[ "$output" == *"[Y/n]"* ]]
  run confirm "destructive?" N </dev/null
  [[ "$output" == *"[y/N]"* ]]
}
