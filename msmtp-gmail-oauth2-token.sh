#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${HOME}/.config/msmtp/google-oauth-client.json"
ENV_FILE="${HOME}/.local/etc/msmtp-gmail-oauth2-token.env"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
  printf 'error: missing OAuth client config %s\n' "${CONFIG_FILE}" >&2
  exit 1
fi

client_id=$(jq -r '.installed.client_id // .web.client_id // empty' "${CONFIG_FILE}")
client_secret=$(jq -r '.installed.client_secret // .web.client_secret // empty' "${CONFIG_FILE}")
ACCOUNT=${MSMTP_KEYCHAIN_ACCOUNT-your.email@example.com}
SERVICE=${MSMTP_KEYCHAIN_SERVICE-gmail-msmtp-oauth2}
refresh_token=$(security find-generic-password -a "${ACCOUNT}" -s "${SERVICE}" -w)

if [[ -z "${client_id}" || -z "${client_secret}" || -z "${refresh_token}" ]]; then
  printf 'error: missing OAuth client credentials or refresh token\n' >&2
  exit 1
fi

response=$(curl -sS --fail https://oauth2.googleapis.com/token \
  -d client_id="${client_id}" \
  -d client_secret="${client_secret}" \
  -d refresh_token="${refresh_token}" \
  -d grant_type=refresh_token)

access_token=$(jq -r '.access_token // empty' <<<"${response}")

if [[ -z "${access_token}" ]]; then
  printf 'error: failed to obtain access token\n%s\n' "${response}" >&2
  exit 1
fi

printf '%s\n' "${access_token}"
