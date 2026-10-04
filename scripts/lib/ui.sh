#!/usr/bin/env bash

tunlet_init_language() {
  case "${TUNLET_LANG:-zh}" in
    en|en_*|en-*) TUNLET_LANG="en" ;;
    *) TUNLET_LANG="zh" ;;
  esac
  export TUNLET_LANG

  TUNLET_UI_BOLD=""
  TUNLET_UI_DIM=""
  TUNLET_UI_BLUE=""
  TUNLET_UI_GREEN=""
  TUNLET_UI_YELLOW=""
  TUNLET_UI_RED=""
  TUNLET_UI_RESET=""
  if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    TUNLET_UI_BOLD=$'\033[1m'
    TUNLET_UI_DIM=$'\033[2m'
    TUNLET_UI_BLUE=$'\033[34m'
    TUNLET_UI_GREEN=$'\033[32m'
    TUNLET_UI_YELLOW=$'\033[33m'
    TUNLET_UI_RED=$'\033[31m'
    TUNLET_UI_RESET=$'\033[0m'
  fi
}

tunlet_text() {
  if [[ "${TUNLET_LANG:-zh}" == "en" ]]; then
    printf '%s' "$2"
  else
    printf '%s' "$1"
  fi
}

tunlet_ui_title() {
  local title
  title="$(tunlet_text "$1" "$2")"
  printf '\n%s%sTunlet · %s%s\n' \
    "${TUNLET_UI_BOLD}" "${TUNLET_UI_BLUE}" "${title}" "${TUNLET_UI_RESET}"
  printf '%s\n' '────────────────────────'
}

tunlet_ui_step() {
  printf '%s→%s %s\n' \
    "${TUNLET_UI_BLUE}" "${TUNLET_UI_RESET}" "$(tunlet_text "$1" "$2")"
}

tunlet_ui_ok() {
  printf '%s✓%s %s\n' \
    "${TUNLET_UI_GREEN}" "${TUNLET_UI_RESET}" "$(tunlet_text "$1" "$2")"
}

tunlet_ui_warn() {
  printf '%s!%s %s\n' \
    "${TUNLET_UI_YELLOW}" "${TUNLET_UI_RESET}" "$(tunlet_text "$1" "$2")"
}

tunlet_ui_error() {
  printf '%s×%s %s\n' \
    "${TUNLET_UI_RED}" "${TUNLET_UI_RESET}" "$(tunlet_text "$1" "$2")" >&2
}

tunlet_ui_note() {
  printf '%s  %s%s\n' \
    "${TUNLET_UI_DIM}" "$(tunlet_text "$1" "$2")" "${TUNLET_UI_RESET}"
}

tunlet_ui_prompt() {
  printf '%s›%s %s' \
    "${TUNLET_UI_BLUE}" "${TUNLET_UI_RESET}" "$(tunlet_text "$1" "$2")"
}

tunlet_normalize_server() {
  local server
  local endpoint
  local host

  server="$(printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -n "${server}" ]] || return 1
  case "${server}" in
    https://*|http://*) ;;
    [Hh][Tt][Tt][Pp][Ss]://*) server="https://${server#*://}" ;;
    [Hh][Tt][Tt][Pp]://*) server="http://${server#*://}" ;;
    *://*) return 2 ;;
    *) server="https://${server}" ;;
  esac
  endpoint="${server#*://}"
  host="${endpoint%%/*}"
  [[ -n "${host}" && "${host}" != *[[:space:]]* ]] || return 1
  printf '%s\n' "${server}"
}

tunlet_init_language
