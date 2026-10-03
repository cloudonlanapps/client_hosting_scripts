#!/usr/bin/env bash
set -euo pipefail

# Usage: ./deploy_web-conf.sh <conf-file> <env> <run|build|publish|release>
#
# Wrapper around deploy_web.sh that reads a brand's settings from its conf.
# The conf lives in the brand folder, beside the brand files the generator
# reads; the brand folder is the conf's directory.
#
# Conf file (sourced as bash) must define:
#   ENVS                  Bash array of allowed env names, e.g. ENVS=(dev beta prod)
#   CORE_URL              Git URL of the core repository holding the templates
#   GENERATOR             The generator's folder inside the core
#   <env>_CORE_REF        The core branch this env builds
#   <env>_API_URL         The API, a whole URL
#   <env>_APP_URL         The app's public URL (not for dev)
#   <env>_WEBSITE_URL     The website's public URL (not for dev); required when
#                         the brand folder has website/, refused otherwise
#   SSH_USER, SSH_HOST, SSH_PORT   The VPS publish rsyncs to
#
# Optional:
#   <env>_WEBSITE_ALIASES  More hosts serving the website, space-separated
#   <env>_REDIRECT_HOSTS   Hosts redirecting to the app (brands without a website)
#
# URLs are used whole: an IP or any domain, with or without a subdomain.
# Nothing here derives one URL from another.
#
# The env name "dev" is treated specially: it builds for this machine only.
# Its app and website are served on localhost (DEV_APP_PORT, DEV_WEBSITE_PORT,
# default 8080 and 8081), no nginx or README is written, and it is never
# published.
#
# Environment overrides:
#   WORK_DIR          where the core clone, generated projects and out/ go
#                     (default: <env>/ beside this tooling checkout)
#   PUBLISH_COMMAND, RELEASE_COMMAND   how the env README tells a reader to
#                     publish, e.g. the caller's own wrapper command

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

[ $# -eq 3 ] || die "usage: $0 <conf-file> <env> <run|build|publish|release>"
CONF_FILE="$1"
ENV="$2"
ACTION="$3"

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

if [ "$ENV" = dev ]; then
    case "$ACTION" in publish|release) die "dev is built for this machine only, never published" ;; esac
fi

need() {  # need <var>... — each must be set in the conf
    local v
    for v in "$@"; do [ -n "${!v:-}" ] || die "$CONF_FILE must define $v"; done
}
env_val() { local v="${ENV}_$1"; printf '%s' "${!v:-}"; }

need CORE_URL GENERATOR "${ENV}_CORE_REF" "${ENV}_API_URL"

ARGS=(
    --action "$ACTION" --brand "$BRAND_DIR" --env "$ENV"
    --core-url "$CORE_URL" --core-ref "$(env_val CORE_REF)" --generator "$GENERATOR"
    --api-url "$(env_val API_URL)"
    --work-dir "${WORK_DIR:-$(dirname "$(dirname "$SCRIPT_DIR")")/$ENV}"
)

if [ "$ENV" = dev ]; then
    app_port="${DEV_APP_PORT:-8080}"
    site_port="${DEV_WEBSITE_PORT:-8081}"
    ARGS+=(--no-hosting --app-url "http://localhost:$app_port"
           --app-port "$app_port" --website-port "$site_port")
    [ -d "$BRAND_DIR/website" ] && ARGS+=(--website-url "http://localhost:$site_port")
else
    need "${ENV}_APP_URL"
    ARGS+=(--app-url "$(env_val APP_URL)")
    [ -n "$(env_val WEBSITE_URL)" ]     && ARGS+=(--website-url "$(env_val WEBSITE_URL)")
    [ -n "$(env_val WEBSITE_ALIASES)" ] && ARGS+=(--website-aliases "$(env_val WEBSITE_ALIASES)")
    [ -n "$(env_val REDIRECT_HOSTS)" ]  && ARGS+=(--redirect-hosts "$(env_val REDIRECT_HOSTS)")
    case "$ACTION" in publish|release) need SSH_USER SSH_HOST SSH_PORT ;; esac
    [ -n "${SSH_USER:-}" ] && ARGS+=(--ssh-user "$SSH_USER")
    [ -n "${SSH_HOST:-}" ] && ARGS+=(--ssh-host "$SSH_HOST")
    [ -n "${SSH_PORT:-}" ] && ARGS+=(--ssh-port "$SSH_PORT")
    ARGS+=(--publish-command "${PUBLISH_COMMAND:-$0 $CONF_FILE $ENV publish}"
           --release-command "${RELEASE_COMMAND:-$0 $CONF_FILE $ENV release}")
fi

exec "$SCRIPT_DIR/deploy_web.sh" "${ARGS[@]}"
