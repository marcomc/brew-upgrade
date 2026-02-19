# AGENTS Instructions

## Bash Script Changes

- Always run `shellcheck --enable=all` on every modified bash script before finishing.
- Fix all `shellcheck` findings directly in code.
- Do not silence findings with `# shellcheck disable=...` unless explicitly requested by the user.

## Markdown Changes

- Always run `markdownlint --fix` for modified Markdown files.
- Re-run `markdownlint` after fixing to confirm zero remaining issues.
- Line-length (`MD013`) is intentionally disabled in this repository config.
