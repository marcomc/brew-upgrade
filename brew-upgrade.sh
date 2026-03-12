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
DRY_RUN=false
DRY_RUN_EMAIL=false
INFO_PACKAGE=""
SCRIPT_VERSION="0.4.0"

BREW_UPGRADE_ARGS=()
STDOUT_LINES=()
UPGRADED_ITEMS=()
CASK_ITEMS=()
DRY_RUN_ITEMS=()

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
  --dry-run                       Show pending Homebrew upgrades without installing them.
  --info <package>                Show metadata, install files, and changelog details.
  --dry-run-email                 Print email payload and skip send.
  --version                       Print script version.
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

add_unique_dry_run_item() {
  local description
  description="$1"

  if ! contains_item "${description}" "${DRY_RUN_ITEMS[@]}"; then
    DRY_RUN_ITEMS+=("${description}")
  fi
}

parse_stdout_line() {
  local line
  local dry_run_name
  local dry_run_change

  line="$1"

  if [[ "${DRY_RUN}" == "true" ]] && [[ "${line}" =~ ^([^[:space:]]+)[[:space:]]+(.+[[:space:]]+\-\>[[:space:]].+)$ ]]; then
    dry_run_name="${BASH_REMATCH[1]}"
    dry_run_change="${BASH_REMATCH[2]}"
    add_unique_dry_run_item "${dry_run_name} ${dry_run_change}"
    return
  fi

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
    if [[ "${DRY_RUN}" == "true" ]]; then
      printf '%s\n' "${line}"
    fi
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
  local dry_run_text
  local item
  local formulae_items

  status_text="$1"
  now_text="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  host_text="$(hostname)"

  if [[ "${DRY_RUN}" == "true" ]]; then
    if [[ "${#DRY_RUN_ITEMS[@]}" -gt 0 ]]; then
      dry_run_text=$(printf '%s\n' "${DRY_RUN_ITEMS[@]}")
    else
      dry_run_text="(none)"
    fi

    cat <<EOF_SUMMARY
brew-upgrade summary

Date/Time: ${now_text}
Host: ${host_text}
Status: ${status_text}
Mode: dry-run (no packages installed)

Updates Available:
${dry_run_text}

Log Path:
${HOMEBREW_LOG}
EOF_SUMMARY
    return
  fi

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

show_package_info() {
  local package
  local python_path

  package="$1"
  python_path="$(command -v python3 || true)"
  if [[ -z "${python_path}" ]]; then
    printf 'Error: --info requires python3.\n' >&2
    return 1
  fi

  "${python_path}" - "${BREW_PATH}" "${package}" <<'PY'
import json
import os
import re
import subprocess
import sys
import tarfile
import urllib.error
import urllib.request
from pathlib import Path


def run_command(*args, check=True):
    result = subprocess.run(args, capture_output=True, text=True, check=False)
    if check and result.returncode != 0:
        raise subprocess.CalledProcessError(
            result.returncode,
            args,
            output=result.stdout,
            stderr=result.stderr,
        )
    return result


def print_lines(title, lines):
    print(f"{title}:")
    if not lines:
        print("(none)")
        print()
        return

    for line in lines:
        print(f"- {line}")
    print()


def emit_error(message, *, details=None, exit_code=1):
    print(f"Error: {message}", file=sys.stderr)
    if details:
        print(details.strip(), file=sys.stderr)
    sys.exit(exit_code)


def choose_entry(payload, query):
    formulae = payload.get("formulae", [])
    casks = payload.get("casks", [])
    if query.startswith("homebrew/core/") and formulae:
        return "formula", formulae[0]
    if query.startswith("homebrew/cask/") and casks:
        return "cask", casks[0]
    if formulae and not casks:
        return "formula", formulae[0]
    if casks and not formulae:
        return "cask", casks[0]
    if formulae and casks:
        emit_error(
            f'"{query}" matches both a formula and a cask. Use '
            f'"homebrew/core/{query}" or "homebrew/cask/{query}".'
        )
    emit_error(f'Homebrew package "{query}" was not found.')


def display_name(kind, entry):
    if kind == "formula":
        return entry.get("full_name") or entry.get("name")

    names = entry.get("name") or []
    if names:
        return f"{entry.get('full_token')} ({', '.join(names)})"
    return entry.get("full_token") or entry.get("token")


def installed_version(kind, entry):
    if kind == "formula":
        installed = entry.get("installed") or []
        if installed:
            return installed[0].get("version") or "unknown"
        return None
    return entry.get("installed")


def target_version(kind, entry):
    if kind == "formula":
        versions = entry.get("versions") or {}
        return versions.get("stable") or "unknown"
    return entry.get("version") or "unknown"


def flatten_cask_value(kind, value):
    lines = []
    if isinstance(value, str):
        lines.append(f"{kind}: {value}")
    elif isinstance(value, list):
        for item in value:
            lines.extend(flatten_cask_value(kind, item))
    elif isinstance(value, dict):
        for subkey, subvalue in value.items():
            if isinstance(subvalue, str):
                lines.append(f"{kind} ({subkey}): {subvalue}")
            elif isinstance(subvalue, list):
                for item in subvalue:
                    if isinstance(item, str):
                        lines.append(f"{kind} ({subkey}): {item}")
                    else:
                        lines.extend(flatten_cask_value(f"{kind} ({subkey})", item))
            else:
                lines.append(f"{kind} ({subkey}): {json.dumps(subvalue, sort_keys=True)}")
    else:
        lines.append(f"{kind}: {json.dumps(value, sort_keys=True)}")
    return lines


def cask_install_artifacts(entry):
    artifacts = []
    ignored = {
        "zap",
        "uninstall",
        "preflight",
        "postflight",
        "uninstall_preflight",
        "uninstall_postflight",
    }
    for artifact in entry.get("artifacts") or []:
        for kind, value in artifact.items():
            if kind in ignored:
                continue
            artifacts.extend(flatten_cask_value(kind, value))
    return artifacts


def current_bottle_tag(brew_path):
    result = run_command(brew_path, "ruby", "-e", "puts Utils::Bottles.tag.to_sym")
    tag = result.stdout.strip()
    if not tag:
        raise RuntimeError("Unable to determine the Homebrew bottle tag for this machine.")
    return tag


def formula_install_files(brew_path, entry):
    bottle = (entry.get("bottle") or {}).get("stable") or {}
    bottle_files = bottle.get("files") or {}
    if not bottle_files:
        return None, "No stable bottle metadata is available for this formula."

    tag = current_bottle_tag(brew_path)
    if tag not in bottle_files:
        return None, f'No bottle is published for the current tag "{tag}".'

    fetch_result = run_command(brew_path, "fetch", "--force-bottle", entry["name"], check=False)
    if fetch_result.returncode != 0:
        details = fetch_result.stderr.strip() or fetch_result.stdout.strip()
        return None, f"Unable to fetch the bottle archive: {details or 'unknown error'}"

    cache_dir = run_command(brew_path, "--cache").stdout.strip()
    suffix = f".{tag}.bottle.tar.gz"
    needle = f"--{entry['name']}--"
    candidates = [
        path
        for path in Path(cache_dir).rglob("*")
        if path.is_file() and needle in path.name and path.name.endswith(suffix)
    ]
    if not candidates:
        return None, "Bottle archive was fetched but not found in the Homebrew cache."

    archive_path = max(candidates, key=lambda path: path.stat().st_mtime)
    files = []
    with tarfile.open(archive_path, "r:gz") as archive:
        for member in archive.getmembers():
            if not (member.isfile() or member.issym() or member.islnk()):
                continue
            parts = member.name.split("/", 2)
            if len(parts) == 3:
                relative_path = parts[2]
            else:
                relative_path = member.name
            if relative_path:
                files.append(relative_path)

    return sorted(dict.fromkeys(files)), None


def normalize_version(text):
    if not text:
        return None
    candidate = str(text).strip()
    if not candidate:
        return None
    candidate = candidate.rsplit("/", 1)[-1]
    match = re.search(r"v?\d[\w.+-]*", candidate)
    if match:
        candidate = match.group(0)
    candidate = candidate.split(",", 1)[0]
    if candidate.lower().startswith("v") and len(candidate) > 1 and candidate[1].isdigit():
        candidate = candidate[1:]
    candidate = candidate.strip().lower()
    return candidate or None


def version_key(text):
    normalized = normalize_version(text)
    if not normalized:
        return None
    parts = []
    for token in re.findall(r"\d+|[a-z]+", normalized):
        if token.isdigit():
            parts.append((0, int(token)))
        else:
            parts.append((1, token))
    return tuple(parts)


def github_repo_from_urls(urls):
    pattern = re.compile(r"https?://github\.com/([^/]+)/([^/#?]+)")
    for url in urls:
        if not url:
            continue
        match = pattern.search(url)
        if not match:
            continue
        owner = match.group(1)
        repo = match.group(2)
        repo = re.sub(r"\.git$", "", repo)
        return f"{owner}/{repo}"
    return None


def fetch_github_releases(repo):
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/releases?per_page=100",
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "brew-upgrade",
        },
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def changelog_lines(entry, kind, current_version, desired_version):
    if not current_version:
        return ["Not available because the package is not currently installed."]

    current_key = version_key(current_version)
    desired_key = version_key(desired_version)
    if current_key is None or desired_key is None:
        return [
            f"Not available because the versions could not be compared ({current_version} -> {desired_version})."
        ]

    if current_key >= desired_key:
        return [f"No newer release notes are needed; installed version is {current_version}."]

    urls = []
    homepage = entry.get("homepage")
    if homepage:
        urls.append(homepage)

    if kind == "formula":
        stable_url = ((entry.get("urls") or {}).get("stable") or {}).get("url")
        head_url = ((entry.get("urls") or {}).get("head") or {}).get("url")
        urls.extend([stable_url, head_url])
    else:
        urls.append(entry.get("url"))

    repo = github_repo_from_urls(urls)
    if not repo:
        return ["No GitHub release feed could be derived from the package metadata."]

    try:
        releases = fetch_github_releases(repo)
    except urllib.error.HTTPError as exc:
        return [f"GitHub release lookup failed with HTTP {exc.code} for {repo}."]
    except urllib.error.URLError as exc:
        return [f"GitHub release lookup failed for {repo}: {exc.reason}"]

    collected = []
    target_found = False
    for release in releases:
        if release.get("draft") or release.get("prerelease"):
            continue
        release_key = version_key(release.get("tag_name") or release.get("name"))
        if release_key is None:
            continue
        if release_key > desired_key:
            continue
        if release_key <= current_key:
            continue
        if release_key == desired_key:
            target_found = True
        body_lines = []
        for raw_line in (release.get("body") or "").splitlines():
            stripped = raw_line.strip()
            if not stripped:
                continue
            stripped = re.sub(r"^#+\s*", "", stripped)
            stripped = re.sub(r"^[-*]\s*", "", stripped)
            stripped = re.sub(r"^\d+\.\s*", "", stripped)
            if stripped:
                body_lines.append(stripped)
        collected.append(
            {
                "version": release.get("tag_name") or release.get("name") or "unknown",
                "published_at": release.get("published_at") or "unknown date",
                "html_url": release.get("html_url") or "",
                "body_lines": body_lines[:8],
                "truncated": len(body_lines) > 8,
            }
        )

    if not collected:
        return [
            f"No matching GitHub release notes were found between {current_version} and {desired_version} for {repo}."
        ]

    if not target_found:
        collected.insert(
            0,
            {
                "version": desired_version,
                "published_at": "unknown date",
                "html_url": "",
                "body_lines": [f"Latest Homebrew version is {desired_version}, but a matching GitHub release tag was not found."],
                "truncated": False,
            },
        )

    lines = [f"Source: GitHub releases for {repo}"]
    for release in collected:
        lines.append(
            f"{release['version']} ({release['published_at']}): {release['html_url'] or 'release URL unavailable'}"
        )
        if release["body_lines"]:
            for body_line in release["body_lines"]:
                lines.append(f"  {body_line}")
            if release["truncated"]:
                lines.append("  ...")
        else:
            lines.append("  No release note body was published.")
    return lines


def main():
    brew_path = sys.argv[1]
    package = sys.argv[2]
    try:
        info_result = run_command(brew_path, "info", "--json=v2", package, check=False)
    except FileNotFoundError:
        emit_error(f'Homebrew was not found at "{brew_path}".')

    if info_result.returncode != 0:
        emit_error(
            f'Unable to inspect "{package}" with Homebrew.',
            details=info_result.stderr or info_result.stdout,
        )

    payload = json.loads(info_result.stdout)
    kind, entry = choose_entry(payload, package)
    current_version = installed_version(kind, entry)
    desired_version = target_version(kind, entry)

    print(f"Package: {display_name(kind, entry)}")
    print(f"Type: {kind}")
    print(f"Description: {entry.get('desc') or 'No description available.'}")
    print(f"Latest Homebrew version: {desired_version}")
    print(f"Installed version: {current_version or 'not installed'}")
    print()

    if kind == "formula":
        files, files_note = formula_install_files(brew_path, entry)
        if files is None:
            print_lines("Files Homebrew would install", [files_note])
        else:
            print_lines("Files Homebrew would install", files)
    else:
        print_lines("Install artifacts Homebrew would install", cask_install_artifacts(entry))

    print_lines(
        "Changelog since the installed version",
        changelog_lines(entry, kind, current_version, desired_version),
    )


if __name__ == "__main__":
    main()
PY
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
    --dry-run|-n)
      DRY_RUN=true
      BREW_UPGRADE_ARGS+=("$1")
      shift
      ;;
    --info)
      if [[ -z "${2:-}" ]]; then
        printf 'Error: --info requires a package name.\n' >&2
        exit 2
      fi
      INFO_PACKAGE="$2"
      shift 2
      ;;
    --dry-run-email)
      DRY_RUN_EMAIL=true
      shift
      ;;
    --version)
      printf 'brew-upgrade %s\n' "${SCRIPT_VERSION}"
      exit 0
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

if [[ -n "${INFO_PACKAGE}" ]]; then
  if [[ "${DRY_RUN}" == "true" || "${#BREW_UPGRADE_ARGS[@]}" -gt 0 ]]; then
    printf 'Error: --info cannot be combined with brew upgrade options.\n' >&2
    exit 2
  fi
  show_package_info "${INFO_PACKAGE}"
  exit $?
fi

append_log ""
if [[ "${DRY_RUN}" == "true" ]]; then
  append_log "Running brew update followed by brew upgrade --dry-run..."
  printf 'brew-upgrade dry run: showing pending Homebrew upgrades without installing them.\n'
else
  append_log "Running brew update followed by brew upgrade..."
fi
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
  if [[ "${DRY_RUN}" == "true" ]]; then
    osascript -e 'display notification "Homebrew dry run completed. No packages were installed." with title "brew upgrade" sound name "Purr"'
    send_summary_email "dry-run success"
  else
    osascript -e 'display notification "Homebrew packages were upgraded successfully!" with title "brew upgrade" sound name "Purr"'
    send_summary_email "success"
  fi
else
  if [[ "${DRY_RUN}" == "true" ]]; then
    osascript -e 'display notification "Homebrew dry run failed. Check the log for more details." with title "brew upgrade" sound name "Sosumi"'
    send_summary_email "dry-run failure"
  else
    osascript -e 'display notification "Homebrew packages upgrade failed. Check the log for more details." with title "brew upgrade" sound name "Sosumi"'
    send_summary_email "failure"
  fi
fi

exit "${RETVAL}"
