#!/usr/bin/env bash
# Preflight for the Morphe settings plugin declared in settings.gradle.kts.
#
# Gradle reports any failure to fetch a plugin marker (including HTTP 401/403
# from GitHub Packages) as "Plugin ... was not found", hiding the real cause.
# This script checks the same coordinates directly and reports the HTTP status.
#
# 1. Verifies the pinned version exists as an upstream release tag (no credentials).
# 2. If GITHUB_ACTOR/GITHUB_TOKEN are set, requests the plugin marker POM from the
#    GitHub Packages repository declared in settings.gradle.kts. The token is passed
#    to curl on stdin and is never printed or placed on the command line.
#
# Usage: tools/check-morphe-plugin-access.sh [--require-credentials]
set -euo pipefail

require_credentials=false
case "${1:-}" in
  "") ;;
  --require-credentials) require_credentials=true ;;
  *)
    echo "Usage: $0 [--require-credentials]" >&2
    exit 2
    ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
settings="$root/settings.gradle.kts"
plugin_id="app.morphe.patches"
upstream="https://github.com/MorpheApp/morphe-patches-gradle-plugin"

error() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error::$*"
  else
    echo "error: $*" >&2
  fi
}

version="$(sed -nE 's/^[[:space:]]*id\("app\.morphe\.patches"\)[[:space:]]+version[[:space:]]+"([^"]+)".*/\1/p' "$settings" | head -n1)"
repo_url="$(sed -nE 's#^[[:space:]]*url[[:space:]]*=[[:space:]]*uri\("(https://maven\.pkg\.github\.com/[^"]+)"\).*#\1#p' "$settings" | head -n1)"

if [[ -z "$version" ]]; then
  error "Could not find id(\"$plugin_id\") version \"...\" in settings.gradle.kts."
  exit 1
fi
if [[ -z "$repo_url" ]]; then
  error "Could not find the GitHub Packages plugin repository in settings.gradle.kts."
  exit 1
fi

echo "Morphe settings plugin: $plugin_id $version"
echo "Plugin repository: $repo_url"

if git ls-remote --exit-code --tags "$upstream" "refs/tags/v$version" >/dev/null 2>&1; then
  echo "Upstream release tag v$version: found"
else
  error "Morphe plugin version $version has no upstream release tag v$version ($upstream/tags)."
  exit 1
fi

if [[ -z "${GITHUB_ACTOR:-}" || -z "${GITHUB_TOKEN:-}" ]]; then
  if [[ "$require_credentials" == true ]]; then
    error "GITHUB_ACTOR and GITHUB_TOKEN must be set to check GitHub Packages access."
    exit 1
  fi
  echo "GitHub Packages marker check: skipped (no credentials; GitHub Packages returns HTTP 401 without them)"
  exit 0
fi

group_path="${plugin_id//.//}"
artifact="$plugin_id.gradle.plugin"
marker_url="${repo_url%/}/$group_path/$artifact/$version/$artifact-$version.pom"

curl_quote() {
  local value="${1//\\/\\\\}"
  printf '"%s"' "${value//\"/\\\"}"
}

# Redirects are not followed, so credentials are never sent to another host.
status="$(
  printf 'user = %s\n' "$(curl_quote "$GITHUB_ACTOR:$GITHUB_TOKEN")" |
    curl --config - --silent --show-error --output /dev/null \
      --write-out '%{http_code}' --max-time 60 --retry 2 \
      "$marker_url"
)" || status="${status:-000}"

case "$status" in
  2?? | 3??)
    echo "GitHub Packages marker $artifact:$version: accessible (HTTP $status)"
    ;;
  401)
    error "GitHub Packages rejected the credentials for $artifact:$version (HTTP 401). Use a valid, unexpired personal access token (classic) with the read:packages scope; the Maven registry does not accept fine-grained tokens. Gradle reports this as 'plugin was not found'."
    exit 1
    ;;
  403)
    error "GitHub Packages denied access to $artifact:$version (HTTP 403). The token needs the read:packages scope and read access to MorpheApp packages (authorize it for SSO if required)."
    exit 1
    ;;
  404)
    error "GitHub Packages has no $artifact:$version marker at $repo_url (HTTP 404). Check the plugin version and repository owner."
    exit 1
    ;;
  *)
    error "Could not check $artifact:$version at $repo_url (HTTP $status)."
    exit 1
    ;;
esac
