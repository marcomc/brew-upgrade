# brew-upgrade

`brew-upgrade` is a small macOS helper script that runs `brew update` + `brew upgrade`,
logs output to a file, shows a desktop notification on success/failure, and can send a
plain-text summary email through `msmtp`.

## Features

- Runs Homebrew update and upgrade in one command.
- Appends execution logs to `~/Library/Logs/brew-upgrade.log`.
- Captures both `stdout` and `stderr` from Homebrew operations into the log.
- Forwards unknown options to `brew upgrade` (example: `--greedy`).
- Sends macOS notifications with different sounds for success/failure.
- Optionally sends a summary email (success or failure) when the run completes.

## Requirements

- macOS
- Homebrew installed at `/opt/homebrew/bin/brew`
- `osascript` (bundled with macOS)
- Optional for email summaries: `msmtp` already installed and configured

## Install

```bash
make install
```

Install behavior:

- Installs script to `~/.local/bin/brew-upgrade`
- Seeds user config from `.brew-upgrade.conf.example` to `~/.brew-upgrade.conf` **only if missing**

To also install and load the LaunchAgent for scheduled runs:

```bash
make launchagent-install
```

To unload and remove the LaunchAgent:

```bash
make launchagent-uninstall
```

## User Configuration File

`brew-upgrade` supports a user config file in the same style as `raiplaysound-cli`:
plain `KEY=VALUE` lines (bash-style env file, no sections).

Default location:

- `~/.brew-upgrade.conf`

Supported keys:

- `HOMEBREW_LOG`
- `BREW_PATH`
- `EMAIL_TO`
- `EMAIL_FROM_NAME`
- `EMAIL_SUBJECT_PREFIX`
- `EMAIL_CONFIG`

Create or reset from sample:

```bash
cp .brew-upgrade.conf.example ~/.brew-upgrade.conf
chmod 600 ~/.brew-upgrade.conf
```

Then edit values for your environment (paths, sender name, recipient email, etc.).

## CLI

```bash
./brew-upgrade.sh [OPTIONS] [BREW_UPGRADE_OPTIONS]
```

### Script options

- `--config <path>`: Path to user config file. Default: `~/.brew-upgrade.conf`
- `--email-summary`: Enable summary email sending.
- `--email-to <address>`: Recipient address (any domain; not limited to Gmail).
- `--email-from-name <display name>`: Display name for `From` header.
- `--email-subject-prefix <text>`: Subject prefix.
- `--email-config <path>`: Path to `msmtp` config.
- `--dry-run-email`: Print the generated email payload and skip sending.
- `--help`: Show usage.

Unknown options are passed to `brew upgrade`.

### Examples

Run normally:

```bash
./brew-upgrade.sh
```

Pass Homebrew options:

```bash
./brew-upgrade.sh --greedy
```

Enable summary email:

```bash
./brew-upgrade.sh --greedy --email-summary --email-to you@example.com
```

Use a non-default user config file:

```bash
./brew-upgrade.sh --config /path/to/custom-brew-upgrade.conf --greedy
```

Test email payload only:

```bash
./brew-upgrade.sh --email-summary --email-to ops@example.org --dry-run-email
```

Check logs:

```bash
tail -f ~/Library/Logs/brew-upgrade.log
```

## Gmail Setup for msmtp

`brew-upgrade.sh` does not install or manage `msmtp`; it uses your local SMTP setup.

### Preferred setup: Gmail OAuth2 (recommended)

This is the complete staged setup for the OAuth2 flow used by `msmtp`.

#### Stage 1 — Google Cloud project and API

1. Create/select a Google Cloud project (for example `brew-upgrade`).
2. Enable **Gmail API** for that project.

#### Stage 2 — Google Auth Platform (consent/branding)

In **Google Auth Platform**:

1. Complete **Branding/App information**.
2. Set Audience to **External**.
3. Keep Publishing status as **Testing** during setup.
4. In **Test users**, add the Gmail account that will authorize the app.

> If test users are missing, Google may show: “Access blocked: app has not completed verification process.”

#### Stage 3 — OAuth client

1. Go to **Clients** → **Create client**.
2. Choose application type: **Desktop app** (correct for CLI/installed-app OAuth flow).
3. Save `client_id` and `client_secret`.

#### Stage 4 — Secure secret storage (Bitwarden)

Create a Bitwarden item (Secure Note), e.g. `gmail-msmtp-oauth2`, with fields:

- `client_id`
- `client_secret`
- `refresh_token`
- `gmail_address`

Store real values there (no placeholders in production).

#### Stage 5 — Local config files

Create `~/.config/msmtp/config`:

```conf
defaults
auth           on
tls            on
tls_starttls   on
tls_trust_file /etc/ssl/cert.pem
logfile        ~/.local/state/msmtp/msmtp.log

account gmail-oauth2
host           smtp.gmail.com
port           587
from           your.name@gmail.com
user           your.name@gmail.com
auth           xoauth2
passwordeval   "/Users/<you>/.local/bin/msmtp-gmail-oauth2-token"

account default : gmail-oauth2
```

And create an OAuth client JSON file used by token tools (example path):

- `~/.config/msmtp/google-oauth-client.json`

#### Stage 6 — Generate refresh token

Run:

```bash
oauth2l fetch \
  --credentials ~/.config/msmtp/google-oauth-client.json \
  --scope https://mail.google.com/ \
  --output_format refresh_token \
  --refresh
```

Complete browser consent, then save the printed refresh token to Bitwarden (`refresh_token` field).

#### Stage 7 — Validation

- Validate token helper:

```bash
~/.local/bin/msmtp-gmail-oauth2-token >/dev/null && echo OK
```

- Validate mail transport (example):

```bash
printf "Subject: msmtp test\n\nhello" | msmtp --file ~/.config/msmtp/config your.name@gmail.com
```

### Alternative setup: Gmail App Password

Use this only when OAuth2 is not feasible.

1. Enable Google 2-Step Verification.
2. Generate App Password for Mail.
3. Use `passwordeval` to read it from Keychain.

Example:

```conf
passwordeval "security find-generic-password -a your.name@gmail.com -s gmail-msmtp-app-password -w"
```

Set restrictive permissions:

```bash
chmod 600 ~/.config/msmtp/config ~/.config/msmtp/google-oauth-client.json
chmod 700 ~/.local/bin/msmtp-gmail-oauth2-token
```

## LaunchAgent

The repository ships a ready-to-use template at
`launchagent/com.homebrew.upgrade.plist`. It runs `brew-upgrade` daily at 07:00
with `--greedy --email-summary`. Email recipient and other options are read from
`~/.brew-upgrade.conf`.

Install and load in one step:

```bash
make launchagent-install
```

`make launchagent-install` substitutes `__HOME__` with your actual `$HOME` path,
writes the plist to `~/Library/LaunchAgents/com.homebrew.upgrade.plist`, and
bootstraps the agent. Re-running the command updates and reloads it safely.

To unload and remove:

```bash
make launchagent-uninstall
```

### Why EnvironmentVariables / PATH is required

LaunchAgents run in a minimal shell environment where `PATH` contains only
`/usr/bin:/bin:/usr/sbin:/sbin`. Tools installed by Homebrew (such as `msmtp`,
`bw`, `jq`) live in `/opt/homebrew/bin` and are invisible to the agent without
an explicit `PATH`. The template sets:

```text
/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
```

Without this, `msmtp` is not found and the email step is silently skipped with a
warning in the log (`WARNING: msmtp is not installed or not in PATH`).

### Template

`launchagent/com.homebrew.upgrade.plist` (the `__HOME__` token is expanded by
`make launchagent-install`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>com.homebrew.upgrade</string>

    <key>ProgramArguments</key>
    <array>
      <string>__HOME__/.local/bin/brew-upgrade</string>
      <string>--greedy</string>
      <string>--email-summary</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
      <key>PATH</key>
      <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>

    <key>StartCalendarInterval</key>
    <dict>
      <key>Hour</key>
      <integer>7</integer>
      <key>Minute</key>
      <integer>0</integer>
    </dict>
  </dict>
</plist>
```

To customise schedule, arguments, or install path, edit the template before
running `make launchagent-install`, or override variables:

```bash
make launchagent-install LAUNCHAGENT_LABEL=com.myhost.brew-upgrade
```

## Security Notes

- Keep `~/.config/msmtp/config` private (`chmod 600`).
- Prefer OAuth2 over static passwords.
- If using App Passwords, store them in Keychain and fetch with `passwordeval`.
- Do not commit email credentials, tokens, or machine-specific logs.
- Review the Homebrew and mail logs regularly for failures.

## Project Files

- `brew-upgrade.sh`: main script
- `launchagent/com.homebrew.upgrade.plist`: LaunchAgent template for scheduled runs
- `README.md`: documentation
- `CHANGELOG.md`: version history
- `Makefile`: install/uninstall helper (also seeds user config and manages LaunchAgent)
- `.brew-upgrade.conf.example`: sample user configuration file
- `AGENTS.md`: local contributor instructions
- `.markdownlint.json`: markdown lint config
- `.gitignore`: common ignore rules
