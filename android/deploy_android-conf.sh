#!/usr/bin/env bash
set -euo pipefail

# Usage: ./deploy_android-conf.sh <conf-file> <env>
#
# Wrapper around deploy_android.sh that reads a brand's settings from the same
# conf web/deploy_web-conf.sh reads, and builds the member app's APK for one
# environment. The brand folder is the conf's directory.
#
# Uses from the conf:
#   ENVS, CORE_URL, GENERATOR, <env>_CORE_REF, <env>_API_URL  (as for the web)
#   <env>_ANDROID_ID      The app's application id, e.g. org.example.club.beta.
#                         Required here; a conf without it still builds the web.
# Optional:
#   <env>_ANDROID_NAME    The app's name on the phone (default: the brand's
#                         club.json shortName, as on a web home screen)
#   <env>_APP_URL, <env>_WEBSITE_URL   passed on as for the web
#
# A plain http:// API (the dev server) makes the generator allow cleartext
# traffic in the app; an https:// one does not.
#
# Environment overrides:
#   WORK_DIR   where the core clone, the generated project and out-android/ go
#              (default: <env>/ beside this tooling checkout, as for the web)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: $0 <conf-file> <env>"
CONF_FILE="$1"
ENV="$2"

[ -f "$CONF_FILE" ] || die "conf file not found: $CONF_FILE"
CONF_FILE="$(cd "$(dirname "$CONF_FILE")" && pwd)/$(basename "$CONF_FILE")"
BRAND_DIR="$(dirname "$CONF_FILE")"

# shellcheck disable=SC1090
source "$CONF_FILE"

declare -p ENVS >/dev/null 2>&1 && [ ${#ENVS[@]} -gt 0 ] \
    || die "$CONF_FILE must define ENVS=(...) with at least one entry"
ENV_OK=false
for e in "${ENVS[@]}"; do [ "$e" = "$ENV" ] && ENV_OK=true && break; done
[ "$ENV_OK" = true ] || die "unknown env '$ENV'. Allowed: ${ENVS[*]}"

need() {
    local v
    for v in "$@"; do [ -n "${!v:-}" ] || die "$CONF_FILE must define $v"; done
}
env_val() { local v="${ENV}_$1"; printf '%s' "${!v:-}"; }

need CORE_URL GENERATOR "${ENV}_CORE_REF" "${ENV}_API_URL" "${ENV}_ANDROID_ID"

ARGS=(
    --brand "$BRAND_DIR" --env "$ENV"
    --core-url "$CORE_URL" --core-ref "$(env_val CORE_REF)" --generator "$GENERATOR"
    --api-url "$(env_val API_URL)" --android-id "$(env_val ANDROID_ID)"
    --work-dir "${WORK_DIR:-$(dirname "$(dirname "$SCRIPT_DIR")")/$ENV}"
)
[ -n "$(env_val ANDROID_NAME)" ] && ARGS+=(--android-name "$(env_val ANDROID_NAME)")
[ -n "$(env_val APP_URL)" ]      && ARGS+=(--app-url "$(env_val APP_URL)")
[ -n "$(env_val WEBSITE_URL)" ]  && ARGS+=(--website-url "$(env_val WEBSITE_URL)")

exec "$SCRIPT_DIR/deploy_android.sh" "${ARGS[@]}"
