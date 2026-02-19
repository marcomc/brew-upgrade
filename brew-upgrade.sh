#!/usr/bin/env bash

DEBUG=false
if [[ "${DEBUG}" == "true" ]]; then
  set -x
fi

CONFIG_FILE="${HOME}/.brew-upgrade.conf"
HOMEBREW_LOG="${HOME}/Library/Logs/brew-upgrade.log"
BREW_PATH="/opt/homebrew/bin/brew"
EMAIL_SUMMARY=false
EMAIL_TO=""
EMAIL_FROM_NAME="brew-upgrade"
EMAIL_SUBJECT_PREFIX="[brew-upgrade]"
EMAIL_CONFIG="${HOME}/.config/msmtp/config"
DRY_RUN_EMAIL=false

BREW_UPGRADE_ARGS=()
STDOUT_LINES=()
UPGRADED_ITEMS=()
CASK_ITEMS=()

print_usage() {
  cat <<'USAGE'
Usage: brew-upgrade.sh [OPTIONS] [BREW_UPGRADE_OPTIONS]

Runs `brew update` and `brew upgrade`, writes logs, and shows a macOS notification.

Options:
  --config <path>                 Config file path. Default: ~/.brew-upgrade.conf
  --email-summary                 Enable summary email after run completion.
  --email-to <address>            Recipient address (any valid email domain).
  --email-from-name <name>        Email display name.
  --email-subject-prefix <text>   Subject prefix.
  --email-config <path>           msmtp config path.
  --dry-run-email                 Print email payload and skip send.
  --help                          Show this help message.

Unknown options are passed through to `brew upgrade`.
USAGE
}

trim_whitespace() {
  local input

  input="$1"
  input="${input#"${input%%[![:space:]]*}"}"
  input="${input%"${input##*[![:space:]]}"}"
  printf '%s\n' "${input}"
}

apply_config_value() {
  local key
  local raw_value
  local parsed_value

  key="$1"
  raw_value="$2"

  case "${key}" in
    HOMEBREW_LOG|BREW_PATH|EMAIL_TO|EMAIL_FROM_NAME|EMAIL_SUBJECT_PREFIX|EMAIL_CONFIG)
      parsed_value="$(eval "printf '%s' ${raw_value}")"
      case "${key}" in
        HOMEBREW_LOG) HOMEBREW_LOG="${parsed_value}" ;;
        BREW_PATH) BREW_PATH="${parsed_value}" ;;
        EMAIL_TO) EMAIL_TO="${parsed_value}" ;;
        EMAIL_FROM_NAME) EMAIL_FROM_NAME="${parsed_value}" ;;
        EMAIL_SUBJECT_PREFIX) EMAIL_SUBJECT_PREFIX="${parsed_value}" ;;
        EMAIL_CONFIG) EMAIL_CONFIG="${parsed_value}" ;;
        *) ;;
      esac
      ;;
    *) ;;
  esac
}

load_config_file() {
  local path
  local line
  local key
  local value

  path="$1"
  if [[ ! -f "${path}" ]]; then
    return
  fi

  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ -z "${line}" || "${line}" == \#* ]]; then
      continue
    fi

    if [[ "${line}" != *=* ]]; then
      continue
    fi

    key="${line%%=*}"
    value="${line#*=}"
    key="$(trim_whitespace "${key}")"
    value="$(trim_whitespace "${value}")"

    apply_config_value "${key}" "${value}"
  done <"${path}"
}

append_log() {
  local message

  message="$1"
  printf '%s\n' "${message}" >>"${HOMEBREW_LOG}"
}

warn_message() {
  local message

  message="$1"
  append_log "WARNING: ${message}"
  printf 'WARNING: %s\n' "${message}" >&2
}

contains_item() {
  local needle
  local item

  needle="$1"
  shift

  for item in "$@"; do
    if [[ "${item}" == "${needle}" ]]; then
      return 0
    fi
  done

  return 1
}

expand_path() {
  local raw_path

  raw_path="$1"
  if [[ "${raw_path}" == ~/* ]]; then
    printf '%s/%s\n' "${HOME}" "${raw_path#~/}"
    return
  fi

  printf '%s\n' "${raw_path}"
}

add_unique_item() {
  local name
  name="$1"

  if ! contains_item "${name}" "${UPGRADED_ITEMS[@]}"; then
    UPGRADED_ITEMS+=("${name}")
  fi
}

add_unique_cask() {
  local name
  name="$1"

  if ! contains_item "${name}" "${CASK_ITEMS[@]}"; then
    CASK_ITEMS+=("${name}")
  fi
}

parse_stdout_line() {
  local line

  line="$1"

  if [[ "${line}" =~ ^==\>\ Upgrading\ Cask\ ([^[:space:]]+) ]]; then
    add_unique_item "${BASH_REMATCH[1]}"
    add_unique_cask "${BASH_REMATCH[1]}"
  elif [[ "${line}" =~ ^==\>\ Upgrading\ ([^[:space:]]+) ]]; then
    add_unique_item "${BASH_REMATCH[1]}"
  fi

  if [[ "${line}" =~ of\ Cask\ ([^[:space:]]+) ]]; then
    add_unique_cask "${BASH_REMATCH[1]}"
  fi
}

run_brew_command() {
  local stdout_file
  local stderr_file
  local status
  local line

  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"

  if "$@" >"${stdout_file}" 2>"${stderr_file}"; then
    status=0
  else
    status=$?
  fi

  while IFS= read -r line; do
    append_log "${line}"
    STDOUT_LINES+=("${line}")
    parse_stdout_line "${line}"
  done <"${stdout_file}"

  while IFS= read -r line; do
    local stderr_timestamp

    append_log "${line}"
    stderr_timestamp="$(date +"%Y/%m/%d %H:%M:%S")"
    printf '> %s | %s\n' "${stderr_timestamp}" "${line}" >&2
  done <"${stderr_file}"

  rm -f -- "${stdout_file}" "${stderr_file}"
  return "${status}"
}

build_summary() {
  local status_text
  local now_text
  local host_text
  local formulae_text
  local casks_text
  local item
  local formulae_items

  status_text="$1"
  now_text="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  host_text="$(hostname)"

  formulae_items=()
  for item in "${UPGRADED_ITEMS[@]}"; do
    if ! contains_item "${item}" "${CASK_ITEMS[@]}"; then
      formulae_items+=("${item}")
    fi
  done

  if [[ "${#formulae_items[@]}" -gt 0 ]]; then
    formulae_text=$(printf '%s\n' "${formulae_items[@]}")
  else
    formulae_text="(none)"
  fi

  if [[ "${#CASK_ITEMS[@]}" -gt 0 ]]; then
    casks_text=$(printf '%s\n' "${CASK_ITEMS[@]}")
  else
    casks_text="(none)"
  fi

  cat <<EOF_SUMMARY
brew-upgrade summary

Date/Time: ${now_text}
Host: ${host_text}
Status: ${status_text}

Formulae Upgraded:
${formulae_text}

Casks Upgraded:
${casks_text}

Log Path:
${HOMEBREW_LOG}
EOF_SUMMARY
}

extract_from_address() {
  local config_path
  local from_line
  local host_name

  config_path="$1"
  from_line="$(awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*;/ { next }
    $1 == "from" { print $2; exit }
  ' "${config_path}")"

  if [[ -n "${from_line}" ]]; then
    printf '%s\n' "${from_line}"
    return
  fi

  host_name="$(hostname)"
  printf '%s@%s\n' "${USER}" "${host_name}"
}

send_summary_email() {
  local status_text
  local resolved_email_config
  local from_address
  local subject
  local payload
  local message_date
  local summary_body

  status_text="$1"

  if [[ "${EMAIL_SUMMARY}" != "true" ]]; then
    return
  fi

  if [[ -z "${EMAIL_TO}" ]]; then
    warn_message "--email-summary is enabled but --email-to is missing. Skipping email."
    return
  fi

  if ! command -v msmtp >/dev/null 2>&1; then
    warn_message "msmtp is not installed or not in PATH. Skipping email summary."
    return
  fi

  resolved_email_config="$(expand_path "${EMAIL_CONFIG}")"
  if [[ ! -f "${resolved_email_config}" ]]; then
    warn_message "msmtp config not found at ${resolved_email_config}. Skipping email summary."
    return
  fi

  from_address="$(extract_from_address "${resolved_email_config}")"
  subject="${EMAIL_SUBJECT_PREFIX} brew upgrade ${status_text} on $(hostname)"
  message_date="$(LC_ALL=C date -R)"
  summary_body="$(build_summary "${status_text}")"

  payload="$(cat <<EOF_PAYLOAD
From: ${EMAIL_FROM_NAME} <${from_address}>
To: ${EMAIL_TO}
Subject: ${subject}
Date: ${message_date}
Content-Type: text/plain; charset=UTF-8

${summary_body}
EOF_PAYLOAD
)"

  if [[ "${DRY_RUN_EMAIL}" == "true" ]]; then
    printf '%s\n' "${payload}"
    append_log "Email dry run enabled; payload printed to stdout and not sent."
    return
  fi

  if printf '%s\n' "${payload}" | msmtp --file "${resolved_email_config}" -- "${EMAIL_TO}"; then
    append_log "Email summary sent to ${EMAIL_TO}."
  else
    warn_message "Failed to send summary email with msmtp."
  fi
}

if [[ "$#" -gt 0 ]]; then
  args=("$@")
  index=0
  while [[ ${index} -lt ${#args[@]} ]]; do
    if [[ "${args[${index}]}" == "--config" && $((index + 1)) -lt ${#args[@]} ]]; then
      CONFIG_FILE="${args[$((index + 1))]}"
    fi
    index=$((index + 1))
  done
fi

CONFIG_FILE="$(expand_path "${CONFIG_FILE}")"
load_config_file "${CONFIG_FILE}"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --config)
      if [[ -z "${2:-}" ]]; then
        printf 'Error: --config requires a path.\n' >&2
        exit 2
      fi
      CONFIG_FILE="$2"
      shift 2
      ;;
    --email-summary)
      EMAIL_SUMMARY=true
      shift
      ;;
    --email-to)
      if [[ -z "${2:-}" ]]; then
        printf 'Error: --email-to requires an address.\n' >&2
        exit 2
      fi
      EMAIL_TO="$2"
      shift 2
      ;;
    --email-from-name)
      if [[ -z "${2:-}" ]]; then
        printf 'Error: --email-from-name requires a value.\n' >&2
        exit 2
      fi
      EMAIL_FROM_NAME="$2"
      shift 2
      ;;
    --email-subject-prefix)
      if [[ -z "${2:-}" ]]; then
        printf 'Error: --email-subject-prefix requires a value.\n' >&2
        exit 2
      fi
      EMAIL_SUBJECT_PREFIX="$2"
      shift 2
      ;;
    --email-config)
      if [[ -z "${2:-}" ]]; then
        printf 'Error: --email-config requires a path.\n' >&2
        exit 2
      fi
      EMAIL_CONFIG="$2"
      shift 2
      ;;
    --dry-run-email)
      DRY_RUN_EMAIL=true
      shift
      ;;
    --help)
      print_usage
      exit 0
      ;;
    *)
      BREW_UPGRADE_ARGS+=("$1")
      shift
      ;;
  esac
done

append_log ""
append_log "Running brew update followed by brew upgrade..."
CURRENT_DATE="$(date)"
append_log "${CURRENT_DATE}"
append_log ""

run_brew_command "${BREW_PATH}" update
RETVAL=$?
if [[ "${RETVAL}" -eq 0 ]]; then
  run_brew_command "${BREW_PATH}" upgrade "${BREW_UPGRADE_ARGS[@]}"
  RETVAL=$?
fi

if [[ "${RETVAL}" -eq 0 ]]; then
  osascript -e 'display notification "Homebrew packages were upgraded successfully!" with title "brew upgrade" sound name "Purr"'
  send_summary_email "success"
else
  osascript -e 'display notification "Homebrew packages upgrade failed. Check the log for more details." with title "brew upgrade" sound name "Sosumi"'
  send_summary_email "failure"
fi

exit "${RETVAL}"
