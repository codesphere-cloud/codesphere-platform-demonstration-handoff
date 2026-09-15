#!/usr/bin/env bash
# Verifies the dev toolchain before `mise run setup` touches anything.
#
# Goal: the only things a developer's machine has to provide are mise,
# direnv, and Docker. Everything else (node, pnpm, jq, gh) should resolve to
# the versions pinned in .mise.toml. This script checks that expectation and
# fails fast with a specific, actionable message instead of a confusing
# failure three steps later.
#
# Usage: bash infrastructure/dev/doctor.sh   (also runs as `mise run doctor`)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

PASS=0
WARN=0
FAIL=0

ok() {
	echo "  OK   $*"
	PASS=$((PASS + 1))
}

warn() {
	echo "  WARN $*"
	WARN=$((WARN + 1))
}

bad() {
	echo "  FAIL $*"
	FAIL=$((FAIL + 1))
}

expected_from_mise_toml() {
	# Pulls a pinned version out of .mise.toml, e.g. expected_from_mise_toml node
	sed -nE "s/^${1}[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\1/p" .mise.toml | head -n1
}

echo "== mise itself =="
if command -v mise >/dev/null 2>&1; then
	ok "mise found: $(mise --version 2>/dev/null | head -n1)"
else
	bad "mise is not installed. See https://mise.jdx.dev/ (README Prerequisites)."
fi

echo ""
echo "== direnv =="
if command -v direnv >/dev/null 2>&1; then
	ok "direnv found: $(direnv --version 2>/dev/null)"
	# direnv's "Found RC allowed" line reports a status code, not a boolean:
	# 0 means allowed. Older/newer direnv builds have printed this as "true"
	# instead of "0" — accept both.
	if direnv status 2>/dev/null | grep -qE "Found RC allowed (0|true)\b"; then
		ok "direnv: .envrc is allowed for $REPO_ROOT"
	else
		warn "direnv: .envrc not allowed yet here. Run 'direnv allow'."
	fi
else
	bad "direnv is not installed. See https://direnv.net/ (README Prerequisites)."
fi

echo ""
echo "== mise-managed CLIs (node, pnpm, jq, gh) =="
check_tool_version() {
	local tool="$1" version_cmd="$2" version_regex="$3"
	local expected actual
	expected="$(expected_from_mise_toml "$tool")"

	if ! command -v "$tool" >/dev/null 2>&1; then
		bad "$tool not found on PATH. Run 'mise install' (and 'direnv allow' if not already)."
		return
	fi

	actual="$(eval "$version_cmd" 2>/dev/null | grep -oE "$version_regex" | head -n1)"

	if [ -z "$expected" ]; then
		ok "$tool found: $actual (no pin to compare against)"
	elif [ "$actual" = "$expected" ]; then
		ok "$tool $actual (matches .mise.toml pin)"
	else
		warn "$tool $actual does not match .mise.toml pin ($expected). Likely resolving from outside mise — check 'which $tool' and that direnv is active."
	fi
}

check_tool_version node "node -v" '[0-9]+\.[0-9]+\.[0-9]+'
check_tool_version pnpm "pnpm -v" '[0-9]+\.[0-9]+\.[0-9]+'

if command -v jq >/dev/null 2>&1; then
	ok "jq found: $(jq --version 2>/dev/null)"
else
	bad "jq not found on PATH. Run 'mise install'. Required by infrastructure/preview/scaffold.sh."
fi

if command -v gh >/dev/null 2>&1; then
	ok "gh found: $(gh --version 2>/dev/null | head -n1)"
else
	bad "gh not found on PATH. Run 'mise install'. Required by infrastructure/preview/scaffold.sh."
fi

echo ""
echo "== host prerequisite: Docker =="
if command -v docker >/dev/null 2>&1; then
	ok "docker CLI found: $(docker --version 2>/dev/null)"
	if docker info >/dev/null 2>&1; then
		ok "Docker daemon is reachable"
	else
		bad "Docker CLI found but the daemon is not reachable. Start Docker Desktop (or the Docker daemon) — see README Troubleshooting."
	fi
	if docker compose version >/dev/null 2>&1; then
		ok "docker compose plugin found: $(docker compose version 2>/dev/null | head -n1)"
	else
		bad "'docker compose' (v2 plugin) not found. Update Docker Desktop, or install the compose plugin separately."
	fi
else
	bad "docker not found. Install Docker Desktop (or a compatible engine) — this is the one dependency mise/direnv can't provide."
fi

echo ""
echo "== preview scaffolding readiness (optional, only needed for infrastructure/preview/scaffold.sh) =="
if command -v gh >/dev/null 2>&1; then
	if gh auth status >/dev/null 2>&1; then
		ok "gh is authenticated"
	else
		warn "gh is installed but not authenticated. Run 'gh auth login' before running scaffold.sh."
	fi
fi
for tool in curl openssl; do
	if command -v "$tool" >/dev/null 2>&1; then
		ok "$tool found (system-provided, used by scaffold.sh)"
	else
		warn "$tool not found. Required only by infrastructure/preview/scaffold.sh; install via your OS package manager."
	fi
done

echo ""
echo "== summary =="
echo "  $PASS passed, $WARN warnings, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
	echo ""
	echo "doctor found blocking issues — fix the FAIL items above before running 'mise run setup'."
	exit 1
fi

if [ "$WARN" -gt 0 ]; then
	echo ""
	echo "doctor passed with warnings — safe to continue, but review the WARN items above."
fi

exit 0
