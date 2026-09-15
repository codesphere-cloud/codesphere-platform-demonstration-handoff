#!/usr/bin/env bash
# Phase 0 IaC for PR preview environments.
#
# Provisions everything preview-deployment.yml needs, from one gitignored env
# file:
#   1. GitHub repo secrets/variables (via `gh`)
#   2. The Codesphere team shared vault + Postgres secrets referenced by
#      ci.dev.yml (via the Codesphere Public API)
#
# Idempotent: safe to re-run. GitHub secret/variable writes always overwrite;
# the Codesphere shared vault and its keys are only created/stored if missing
# (pass FORCE=1 to overwrite existing vault secret values too).
#
# Usage:
#   bash infrastructure/preview/scaffold.sh                    # uses ./preview.env next to this script
#   bash infrastructure/preview/scaffold.sh path/to/other.env   # explicit env file
#
# Every precondition is checked up front — this script fails on the first
# missing tool, missing value, or rejected credential, with a specific
# message, before touching GitHub or Codesphere.

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

fail() {
	echo "error: $*" >&2
	exit 1
}

info() {
	echo "==> $*"
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "'$1' is required but not installed."
}

# Never let a secret value hit the log even indirectly: this repo's temp files
# always go through mktemp, live under a private tmp dir, and are removed by
# the trap below regardless of how the script exits.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------------------------------------------------------------------------
# 1. Load env file
# ---------------------------------------------------------------------------

ENV_FILE="${1:-$SCRIPT_DIR/preview.env}"

[ -f "$ENV_FILE" ] || fail "env file not found at '$ENV_FILE'. Copy infrastructure/preview/preview.env.example to preview.env and fill it in first."

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# ---------------------------------------------------------------------------
# 2. Prerequisite checks — fail early, before any network calls
# ---------------------------------------------------------------------------

info "Checking prerequisites..."

need gh
need curl
need jq
need openssl

gh auth status >/dev/null 2>&1 || fail "gh is not authenticated. Run 'gh auth login' first."

[ -n "${CS_TOKEN:-}" ] || fail "CS_TOKEN is empty in '$ENV_FILE'. Generate a Codesphere API token under Account Settings > API Keys."
[ -n "${CS_TEAM_NAME:-}" ] || fail "CS_TEAM_NAME is empty in '$ENV_FILE'."
[ -n "${CS_SHARED_VAULT:-}" ] || fail "CS_SHARED_VAULT is empty in '$ENV_FILE'."
[ -n "${CS_API:-}" ] || fail "CS_API is empty in '$ENV_FILE'."

# Expanded below as "${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"}" rather than plain
# "${GH_REPO_ARGS[@]}" — under `set -u`, macOS's default /bin/bash (3.2) treats
# expanding an empty array as an unbound-variable error. This idiom is the
# portable way to expand "zero or more args" under `set -u` on bash 3.2+.
GH_REPO_ARGS=()
if [ -n "${GITHUB_REPO:-}" ]; then
	GH_REPO_ARGS=(-R "$GITHUB_REPO")
fi

# `gh repo view` is the one gh subcommand that takes the repo as a positional
# argument instead of via -R/--repo (unlike gh secret/variable set below), so
# it needs its own branch here rather than reusing GH_REPO_ARGS.
if [ -n "${GITHUB_REPO:-}" ]; then
	gh repo view "$GITHUB_REPO" >/dev/null 2>&1 \
		|| fail "gh could not resolve repository '$GITHUB_REPO' (from GITHUB_REPO in '$ENV_FILE'). Check the owner/name and that gh has access to it."
else
	gh repo view >/dev/null 2>&1 \
		|| fail "gh could not resolve the target repository from the current git remote. Set GITHUB_REPO in '$ENV_FILE' (owner/name) or run this from inside the repo."
fi

# ---------------------------------------------------------------------------
# 3. Validate the Codesphere token and resolve the team id
# ---------------------------------------------------------------------------

info "Validating CS_TOKEN against $CS_API..."

teams_file="$TMP_DIR/teams.json"
teams_code=$(curl -sS -o "$teams_file" -w '%{http_code}' \
	-H "Authorization: Bearer $CS_TOKEN" \
	"$CS_API/teams") || fail "Could not reach $CS_API/teams. Check CS_API and network access."

[ "$teams_code" = "200" ] || fail "Codesphere API rejected CS_TOKEN (HTTP $teams_code) at $CS_API/teams. The token is missing, invalid, or expired."

TEAM_ID=$(jq -r --arg n "$CS_TEAM_NAME" '.[] | select(.name == $n) | .id' "$teams_file" | head -n1)

if [ -z "$TEAM_ID" ] || [ "$TEAM_ID" = "null" ]; then
	available=$(jq -r '.[].name' "$teams_file" | paste -sd, -)
	fail "Team '$CS_TEAM_NAME' not found for this token. Available teams: ${available:-none}."
fi

info "Resolved team '$CS_TEAM_NAME' -> id $TEAM_ID"

# ---------------------------------------------------------------------------
# 4. GitHub: secrets + variables
# ---------------------------------------------------------------------------

setup_github() {
	info "Setting GitHub secrets and variables..."

	CS_API_ORIGIN="${CS_API%/api}"

	# Read the secret from stdin by omitting --body. Do NOT write `--body -`:
	# gh treats the argument to --body as a literal value (it has no stdin
	# sentinel), so `--body -` silently stores the single character "-" and
	# ignores the piped token. Piping with no --body flag is the correct way.
	printf '%s' "$CS_TOKEN" | gh secret set CS_TOKEN "${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"}" \
		|| fail "Failed to set GitHub secret CS_TOKEN. Check gh permissions on this repo."

	gh variable set CS_TEAM_NAME "${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"}" --body "$CS_TEAM_NAME" \
		|| fail "Failed to set GitHub variable CS_TEAM_NAME."

	gh variable set CS_SHARED_VAULT "${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"}" --body "$CS_SHARED_VAULT" \
		|| fail "Failed to set GitHub variable CS_SHARED_VAULT."

	gh variable set CODESPHERE_INSTANCE_URL "${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"}" --body "$CS_API_ORIGIN" \
		|| fail "Failed to set GitHub variable CODESPHERE_INSTANCE_URL."

	info "GitHub: set secret CS_TOKEN; set variables CS_TEAM_NAME, CS_SHARED_VAULT, CODESPHERE_INSTANCE_URL."
}

# ---------------------------------------------------------------------------
# 5. Codesphere: shared vault + Postgres secrets (idempotent)
# ---------------------------------------------------------------------------

setup_codesphere() {
	info "Ensuring Codesphere shared vault '$CS_SHARED_VAULT' exists..."

	vaults_file="$TMP_DIR/vaults.json"
	vaults_code=$(curl -sS -o "$vaults_file" -w '%{http_code}' \
		-H "Authorization: Bearer $CS_TOKEN" \
		"$CS_API/vault/teams/$TEAM_ID/shared") \
		|| fail "Could not list shared vaults for team $TEAM_ID."

	[ "$vaults_code" = "200" ] || fail "Listing shared vaults failed (HTTP $vaults_code). Check that the token has team read access."

	if jq -e --arg v "$CS_SHARED_VAULT" 'index($v) != null' "$vaults_file" >/dev/null; then
		info "Shared vault '$CS_SHARED_VAULT' already exists — skipping creation."
	else
		create_code=$(curl -sS -o "$TMP_DIR/create_vault.json" -w '%{http_code}' \
			-X POST \
			-H "Authorization: Bearer $CS_TOKEN" \
			-H 'Content-Type: application/json' \
			-d "$(jq -n --arg name "$CS_SHARED_VAULT" '{name: $name}')" \
			"$CS_API/vault/teams/$TEAM_ID/shared") \
			|| fail "Could not create shared vault '$CS_SHARED_VAULT'."

		[ "$create_code" = "200" ] || [ "$create_code" = "201" ] \
			|| fail "Creating shared vault '$CS_SHARED_VAULT' failed (HTTP $create_code). Check that the token has team write access."

		info "Created shared vault '$CS_SHARED_VAULT'."
	fi

	info "Checking existing secret keys in '$CS_SHARED_VAULT'..."

	keys_file="$TMP_DIR/keys.json"
	keys_code=$(curl -sS -o "$keys_file" -w '%{http_code}' \
		-H "Authorization: Bearer $CS_TOKEN" \
		"$CS_API/vault/teams/$TEAM_ID/shared/$CS_SHARED_VAULT/keys") \
		|| fail "Could not list keys in shared vault '$CS_SHARED_VAULT'."

	[ "$keys_code" = "200" ] || fail "Listing keys in shared vault '$CS_SHARED_VAULT' failed (HTTP $keys_code)."

	has_key() {
		jq -e --arg k "$1" 'index($k) != null' "$keys_file" >/dev/null
	}

	# Build the payload of keys to (re)write: anything missing, or everything
	# if FORCE=1 was requested.
	payload="$TMP_DIR/secrets_payload.json"
	echo '{}' >"$payload"

	add_secret_if_needed() {
		local key="$1"
		local value="$2"

		if [ "${FORCE:-0}" != "1" ] && has_key "$key"; then
			info "  $key already set in vault — skipping (set FORCE=1 to overwrite)."
			return
		fi

		jq --arg k "$key" --arg v "$value" '. + {($k): $v}' "$payload" >"$payload.tmp"
		mv "$payload.tmp" "$payload"
		info "  $key will be (re)written."
	}

	pg_password="${POSTGRES_PASSWORD:-}"
	if [ -z "$pg_password" ]; then
		pg_password="$(openssl rand -base64 24)"
		info "  POSTGRES_PASSWORD not set in '$ENV_FILE' — generated a random value."
	fi

	pg_superuser_password="${POSTGRES_SUPERUSER_PASSWORD:-}"
	if [ -z "$pg_superuser_password" ]; then
		pg_superuser_password="$(openssl rand -base64 24)"
		info "  POSTGRES_SUPERUSER_PASSWORD not set in '$ENV_FILE' — generated a random value."
	fi

	add_secret_if_needed POSTGRES_PASSWORD "$pg_password"
	add_secret_if_needed POSTGRES_SUPERUSER_PASSWORD "$pg_superuser_password"

	if [ "$(jq 'length' "$payload")" = "0" ]; then
		info "No vault secrets need writing."
		return
	fi

	store_code=$(curl -sS -o "$TMP_DIR/store_secrets.json" -w '%{http_code}' \
		-X POST \
		-H "Authorization: Bearer $CS_TOKEN" \
		-H 'Content-Type: application/json' \
		-d "@$payload" \
		"$CS_API/vault/teams/$TEAM_ID/shared/$CS_SHARED_VAULT/secrets") \
		|| fail "Could not write secrets to shared vault '$CS_SHARED_VAULT'."

	[ "$store_code" = "200" ] || [ "$store_code" = "201" ] \
		|| fail "Writing secrets to shared vault '$CS_SHARED_VAULT' failed (HTTP $store_code)."

	info "Codesphere: shared vault '$CS_SHARED_VAULT' is populated with the required Postgres secrets."
}

# ---------------------------------------------------------------------------
# 6. Run + summary
# ---------------------------------------------------------------------------

setup_github
setup_codesphere

cat <<EOF

Preview environment scaffolding complete.

GitHub (${GITHUB_REPO:-current repo}):
  secret    CS_TOKEN
  variable  CS_TEAM_NAME              = $CS_TEAM_NAME
  variable  CS_SHARED_VAULT           = $CS_SHARED_VAULT
  variable  CODESPHERE_INSTANCE_URL   = ${CS_API%/api}

Codesphere team '$CS_TEAM_NAME' (id $TEAM_ID):
  shared vault '$CS_SHARED_VAULT' with POSTGRES_PASSWORD, POSTGRES_SUPERUSER_PASSWORD

Next step: open a pull request. .github/workflows/preview-deployment.yml will
create a preview workspace from ci.dev.yml and post the link on the PR.
EOF
