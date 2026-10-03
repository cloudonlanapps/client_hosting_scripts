#!/usr/bin/env bash
set -euo pipefail

# deploy_web.sh — build a brand's Flutter web frontends from a core repository's
# templates, and publish them behind nginx. Generic: every name, URL and ref
# arrives as a parameter; nothing here knows a product, a repository or a
# branch. A wrapper (one per organisation) supplies them.
#
#   deploy_web.sh --action <run|build|publish|release> --brand <dir> --env <label>
#                 --core-url <git url> --core-ref <branch> --generator <dir in core>
#                 --api-url <url> --app-url <url> [--website-url <url>]
#                 [--website-aliases "<host> ..."] [--redirect-hosts "<host> ..."]
#                 --work-dir <dir> [--out-dir <dir>] [--no-hosting]
#                 [--ssh-user <u> --ssh-host <h> --ssh-port <p>]
#                 [--app-port 8080] [--website-port 8081]
#                 [--publish-command "<cmd>"] [--release-command "<cmd>"]
#
#   build    clone the core at --core-ref into <work>/core, run its generator
#            for the app (and the website when the brand has website/), flutter
#            build web, and write <out>/: app/, website/, build.info, and unless
#            --no-hosting, nginx/ (port-80 vhosts) and README.md (DNS, web roots,
#            nginx and certbot steps for this environment).
#   run      build, then serve app/ and website/ on localhost.
#   publish  rsync the last build to /var/www/<host> on the VPS, and nginx/ and
#            the README to ~/web_deploy/<brand>-<env>/. Refuses a --no-hosting
#            build, or one built for other hosts than these parameters name.
#   release  build, then publish.
#
# The generator is <core>/<generator>, a Dart package whose bin/generate.dart
# takes --target app|website --brand --out --api-url [--app-url]
# [--website-url] and creates a project that `flutter build web` builds.
#
# URLs are used whole: an IP or any domain, with or without a subdomain.
# Requires git, flutter, rsync, python3 (for run); publish needs SSH access.

die() { echo "ERROR: $*" >&2; exit 1; }

ACTION="" BRAND_DIR="" ENV_NAME="" BRAND=""
CORE_URL="" CORE_REF="" GENERATOR=""
API_URL="" APP_URL="" WEBSITE_URL="" WEBSITE_ALIASES="" REDIRECT_HOSTS=""
WORK="" OUT="" HOSTING=1
SSH_USER="" SSH_HOST="" SSH_PORT=""
APP_PORT=8080 WEBSITE_PORT=8081
PUBLISH_COMMAND="" RELEASE_COMMAND=""

while [ $# -gt 0 ]; do
    case "$1" in
        --no-hosting) HOSTING=0; shift; continue ;;
        -h|--help) sed -n '4,33p' "$0"; exit 0 ;;
    esac
    [ $# -ge 2 ] || die "$1 needs a value"
    case "$1" in
        --action)          ACTION="$2" ;;
        --brand)           BRAND_DIR="$2" ;;
        --brand-name)      BRAND="$2" ;;
        --env)             ENV_NAME="$2" ;;
        --core-url)        CORE_URL="$2" ;;
        --core-ref)        CORE_REF="$2" ;;
        --generator)       GENERATOR="$2" ;;
        --api-url)         API_URL="$2" ;;
        --app-url)         APP_URL="$2" ;;
        --website-url)     WEBSITE_URL="$2" ;;
        --website-aliases) WEBSITE_ALIASES="$2" ;;
        --redirect-hosts)  REDIRECT_HOSTS="$2" ;;
        --work-dir)        WORK="$2" ;;
        --out-dir)         OUT="$2" ;;
        --ssh-user)        SSH_USER="$2" ;;
        --ssh-host)        SSH_HOST="$2" ;;
        --ssh-port)        SSH_PORT="$2" ;;
        --app-port)        APP_PORT="$2" ;;
        --website-port)    WEBSITE_PORT="$2" ;;
        --publish-command) PUBLISH_COMMAND="$2" ;;
        --release-command) RELEASE_COMMAND="$2" ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift 2
done

case "$ACTION" in run|build|publish|release) ;; *) die "--action must be run, build, publish or release" ;; esac
for pair in "--brand:$BRAND_DIR" "--env:$ENV_NAME" "--api-url:$API_URL" "--app-url:$APP_URL" "--work-dir:$WORK"; do
    [ -n "${pair#*:}" ] || die "${pair%%:*} is required"
done
case "$ACTION" in
    run|build|release)
        for pair in "--core-url:$CORE_URL" "--core-ref:$CORE_REF" "--generator:$GENERATOR"; do
            [ -n "${pair#*:}" ] || die "${pair%%:*} is required to build"
        done ;;
esac

BRAND_DIR="$(cd "$BRAND_DIR" 2>/dev/null && pwd)" || die "brand folder not found"
[ -n "$BRAND" ] || BRAND="$(basename "$BRAND_DIR")"
mkdir -p "$WORK"; WORK="$(cd "$WORK" && pwd)"
[ -n "$OUT" ] || OUT="$WORK/out"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"

# host_of <url> — the host of a whole URL: no scheme, credentials, port or path.
host_of() {
    local h="${1#*://}"
    h="${h%%/*}"; h="${h##*@}"; h="${h%%:*}"
    printf '%s' "$h"
}
is_ip() { [[ "$1" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; }
check_url() {
    [[ "$2" =~ ^https?://[^/]+ ]] || die "$1 must be a whole http(s) URL, got '$2'"
}

check_url --api-url "$API_URL"
check_url --app-url "$APP_URL"
HAS_WEBSITE=0
[ -d "$BRAND_DIR/website" ] && HAS_WEBSITE=1
if [ "$HAS_WEBSITE" -eq 1 ]; then
    [ -n "$WEBSITE_URL" ] || die "the brand has website/, so --website-url is required"
    check_url --website-url "$WEBSITE_URL"
    [ -z "$REDIRECT_HOSTS" ] || die "--redirect-hosts is for a brand without a website"
else
    [ -z "$WEBSITE_URL$WEBSITE_ALIASES" ] || die "--website-url/--website-aliases given, but the brand has no website/ folder"
fi

APP_HOST="$(host_of "$APP_URL")"
API_HOST="$(host_of "$API_URL")"
SITE_HOST=""
SITE_NAMES=()
if [ "$HAS_WEBSITE" -eq 1 ]; then
    SITE_HOST="$(host_of "$WEBSITE_URL")"
    SITE_NAMES=("$SITE_HOST")
    # shellcheck disable=SC2206
    [ -n "$WEBSITE_ALIASES" ] && SITE_NAMES+=($WEBSITE_ALIASES)
fi
# shellcheck disable=SC2206
REDIRECT_NAMES=($REDIRECT_HOSTS)

# Every host this build answers for; publish checks it against the build.
HOSTS_LINE="app=$APP_HOST website=${SITE_NAMES[*]:-} redirect=${REDIRECT_NAMES[*]:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES="$SCRIPT_DIR/templates"
STAGING="web_deploy/$BRAND-$ENV_NAME"   # relative to the SSH user's home
SELF="$SCRIPT_DIR/deploy_web.sh"
[ -n "$PUBLISH_COMMAND" ] || PUBLISH_COMMAND="$SELF --action publish …"
[ -n "$RELEASE_COMMAND" ] || RELEASE_COMMAND="$SELF --action release …"

# render <template> [KEY value]... — replace each @@KEY@@ with value.
render() {
    local text
    text="$(<"$1")"
    shift
    while [ $# -gt 0 ]; do
        text=${text//"@@$1@@"/$2}
        shift 2
    done
    printf '%s\n' "$text"
}

# sync_repo <url> <branch> <dir> — make <dir> exactly origin/<branch>, cloning
# if needed, and set SYNCED_SHA. (Not called inside $(...): command
# substitution does not inherit set -e, so a failed clone would go unnoticed.)
sync_repo() {
    local url="$1" ref="$2" dir="$3" commit
    if [ ! -d "$dir/.git" ]; then
        echo "==> Cloning $url"
        git clone -q "$url" "$dir"
    fi
    git -C "$dir" remote set-url origin "$url"
    git -C "$dir" fetch -q --prune --tags --force origin
    commit="$(git -C "$dir" rev-parse -q --verify "origin/$ref^{commit}")" \
        || die "$url has no branch '$ref'"
    git -C "$dir" checkout -q -f --detach "$commit"
    git -C "$dir" clean -q -fdx
    SYNCED_SHA="$(git -C "$dir" rev-parse --short HEAD)"
}

# generate <app|website> <out> [generator flags]...
generate() {
    local target="$1" out="$2"
    shift 2
    rm -rf "$out"
    (
        cd "$WORK/core/$GENERATOR"
        dart pub get >/dev/null
        dart run bin/generate.dart --target "$target" --brand "$BRAND_DIR" \
            --out "$out" --api-url "$API_URL" "$@"
    )
}

# build_web <project dir> <dest> — build, cache-bust, copy build/web to <dest>.
build_web() {
    local dir="$1" dest="$2"
    (
        cd "$dir"
        rm -rf build/web
        flutter build web --release --dart-define="BUILD_TIMESTAMP=$TS"

        # Cache-bust the two files index.html loads, so a new build is never
        # masked by a cached old one. The service worker would cache them
        # again; drop it. `sed -i.bak` works on both GNU and BSD sed.
        cd build/web
        mv main.dart.js "main.${TS}.dart.js"
        sed -i.bak "s/main\.dart\.js/main.${TS}.dart.js/g" flutter_bootstrap.js
        mv flutter_bootstrap.js "flutter_bootstrap.${TS}.js"
        sed -i.bak "s/flutter_bootstrap\.js/flutter_bootstrap.${TS}.js/g" index.html
        rm -f ./*.bak flutter_service_worker.js
    )
    rm -rf "$dest"
    cp -R "$dir/build/web" "$dest"
}

# ── build ───────────────────────────────────────────────────────────────────
do_build() {
    local core_sha flutter_version
    TS="$(date '+%Y%m%d%H%M%S')"
    rm -rf "${OUT:?}"/*

    echo "==> $BRAND $ENV_NAME: $(basename "$CORE_URL" .git) @ $CORE_REF"
    sync_repo "$CORE_URL" "$CORE_REF" "$WORK/core"
    core_sha="$SYNCED_SHA"
    [ -f "$WORK/core/$GENERATOR/bin/generate.dart" ] \
        || die "$CORE_REF ($core_sha) has no $GENERATOR/bin/generate.dart"

    echo "==> app — API $API_URL"
    if [ "$HAS_WEBSITE" -eq 1 ]; then
        generate app "$WORK/app" --website-url "$WEBSITE_URL"
    else
        generate app "$WORK/app"
    fi
    build_web "$WORK/app" "$OUT/app"

    if [ "$HAS_WEBSITE" -eq 1 ]; then
        echo "==> website — API $API_URL"
        generate website "$WORK/website" --app-url "$APP_URL"
        build_web "$WORK/website" "$OUT/website"
    fi

    if [ "$HOSTING" -eq 1 ]; then
        mkdir -p "$OUT/nginx"
        write_nginx
        write_readme "$core_sha"
    fi

    flutter_version="$(flutter --version 2>/dev/null | head -1 | awk '{print $2}')"
    # Written last: publish refuses an output without it, so a build that
    # failed half-way can never be shipped.
    {
        echo "brand=$BRAND"
        echo "env=$ENV_NAME"
        echo "timestamp=$TS"
        echo "core=$(basename "$CORE_URL" .git) $CORE_REF $core_sha"
        echo "tooling=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
        echo "flutter=$flutter_version"
        echo "api=$API_URL"
        echo "hosting=$([ "$HOSTING" -eq 1 ] && echo yes || echo no)"
        echo "hosts=$HOSTS_LINE"
    } > "$OUT/build.info"

    echo "==> Built into $OUT"
    sed 's/^/      /' "$OUT/build.info"
}

write_nginx() {
    render "$TEMPLATES/spa.nginx" \
        ROOT_HOST "$APP_HOST" SERVER_NAMES "$APP_HOST" ROLE "app" \
        BRAND "$BRAND" ENV "$ENV_NAME" EXTRA_LOCATIONS "" \
        > "$OUT/nginx/$APP_HOST"

    if [ "$HAS_WEBSITE" -eq 1 ]; then
        render "$TEMPLATES/spa.nginx" \
            ROOT_HOST "$SITE_HOST" SERVER_NAMES "${SITE_NAMES[*]}" ROLE "website" \
            BRAND "$BRAND" ENV "$ENV_NAME" EXTRA_LOCATIONS "" \
            > "$OUT/nginx/$SITE_HOST"
    elif [ ${#REDIRECT_NAMES[@]} -gt 0 ]; then
        render "$TEMPLATES/redirect.nginx" \
            ROOT_HOST "${REDIRECT_NAMES[0]}" SERVER_NAMES "${REDIRECT_NAMES[*]}" \
            TARGET_HOST "$APP_HOST" BRAND "$BRAND" ENV "$ENV_NAME" \
            > "$OUT/nginx/${REDIRECT_NAMES[0]}"
    fi
}

write_readme() {
    local core_sha="$1" core_name
    local hosts_table dns_table="" dig="" webroots="" links="" certbot check_http="" check_https=""
    local cells="" name h dflags="" vhosts=("$APP_HOST")
    core_name="$(basename "$CORE_URL" .git)"

    hosts_table="| \`$APP_HOST\` | app | $core_name \`$CORE_REF\` ($core_sha) + brand \`$BRAND\` |"
    if [ "$HAS_WEBSITE" -eq 1 ]; then
        for name in "${SITE_NAMES[@]}"; do cells+="${cells:+, }\`$name\`"; done
        hosts_table+=$'\n'"| $cells | website | $core_name \`$CORE_REF\` ($core_sha) + brand \`$BRAND\` |"
        vhosts+=("$SITE_HOST")
    elif [ ${#REDIRECT_NAMES[@]} -gt 0 ]; then
        for name in "${REDIRECT_NAMES[@]}"; do cells+="${cells:+, }\`$name\`"; done
        hosts_table+=$'\n'"| $cells | redirect to \`$APP_HOST\` (no website) | — |"
        vhosts+=("${REDIRECT_NAMES[0]}")
    fi

    add_dns() {  # add_dns <host> <role>
        is_ip "$1" && return 0
        dns_table+="${dns_table:+$'\n'}| \`$1\` | $2 |"
        dig+="${dig:+$'\n'}dig +short A $1"
    }
    add_dns "$APP_HOST" "app"
    for name in "${SITE_NAMES[@]}"; do add_dns "$name" "website"; done
    for name in "${REDIRECT_NAMES[@]}"; do add_dns "$name" "redirect to the app"; done
    add_dns "$API_HOST" "API (deployed separately; listed so the set is complete)"

    webroots="/var/www/$APP_HOST"
    [ "$HAS_WEBSITE" -eq 1 ] && webroots+=" /var/www/$SITE_HOST"
    for h in "${vhosts[@]}"; do
        links+="${links:+$'\n'}sudo ln -sf /etc/nginx/sites-available/$h /etc/nginx/sites-enabled/$h"
    done

    certbot="sudo certbot --nginx --cert-name $APP_HOST -d $APP_HOST"
    if [ "$HAS_WEBSITE" -eq 1 ]; then
        for name in "${SITE_NAMES[@]}"; do dflags+=" -d $name"; done
        certbot+=$'\n'"sudo certbot --nginx --cert-name $SITE_HOST$dflags"
    elif [ ${#REDIRECT_NAMES[@]} -gt 0 ]; then
        for name in "${REDIRECT_NAMES[@]}"; do dflags+=" -d $name"; done
        certbot+=$'\n'"sudo certbot --nginx --cert-name ${REDIRECT_NAMES[0]}$dflags"
    fi

    check_http="curl -sI http://$APP_HOST/ | head -1  # 200"
    check_https="curl -sI https://$APP_HOST/ | head -1  # 200"
    check_https+=$'\n'"curl -sI https://$APP_HOST/some/route | head -1  # 200: app routing"
    for name in "${SITE_NAMES[@]}"; do
        check_http+=$'\n'"curl -sI http://$name/ | head -1  # 200"
        check_https+=$'\n'"curl -sI https://$name/ | head -1  # 200"
    done
    for name in "${REDIRECT_NAMES[@]}"; do
        check_http+=$'\n'"curl -sI http://$name/ | grep -i ^location  # https://$APP_HOST/"
        check_https+=$'\n'"curl -sI https://$name/ | grep -i ^location  # https://$APP_HOST/"
    done

    render "$TEMPLATES/README.env.md" \
        BRAND "$BRAND" ENV "$ENV_NAME" \
        BUILT_AT "$(date '+%Y-%m-%d %H:%M %Z')" \
        HOSTS_TABLE "$hosts_table" API_URL "$API_URL" \
        SSH_PORT "${SSH_PORT:-22}" SSH_TARGET "${SSH_USER:-<user>}@${SSH_HOST:-<vps>}" \
        SSH_HOST "${SSH_HOST:-<vps>}" SSH_USER "${SSH_USER:-<user>}" \
        DNS_TABLE "$dns_table" DIG "$dig" \
        WEBROOTS "$webroots" NGINX_LINKS "$links" CERTBOT "$certbot" \
        CHECK_HTTP "$check_http" CHECK_HTTPS "$check_https" \
        PUBLISH_COMMAND "$PUBLISH_COMMAND" RELEASE_COMMAND "$RELEASE_COMMAND" \
        > "$OUT/README.md"
}

# ── run ─────────────────────────────────────────────────────────────────────
# Serves the built sites on localhost with an SPA fallback (any path that is
# not a file is the app's own route), until interrupted.
do_run() {
    local sites=("$OUT/app:$APP_PORT")
    [ "$HAS_WEBSITE" -eq 1 ] && sites+=("$OUT/website:$WEBSITE_PORT")
    echo "==> Serving $BRAND $ENV_NAME (Ctrl-C to stop)"
    echo "      app      http://localhost:$APP_PORT"
    [ "$HAS_WEBSITE" -eq 1 ] && echo "      website  http://localhost:$WEBSITE_PORT"
    echo "      API      $API_URL (it must accept these localhost origins)"
    python3 - "${sites[@]}" <<'PY'
import functools, http.server, os, sys, threading

class SPA(http.server.SimpleHTTPRequestHandler):
    def send_head(self):
        if not os.path.exists(self.translate_path(self.path)):
            self.path = "/index.html"
        return super().send_head()
    def log_message(self, *args):
        pass

for spec in sys.argv[1:]:
    root, port = spec.rsplit(":", 1)
    handler = functools.partial(SPA, directory=root)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", int(port)), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    threading.Event().wait()
except KeyboardInterrupt:
    pass
PY
}

# ── publish ─────────────────────────────────────────────────────────────────
do_publish() {
    for pair in "--ssh-user:$SSH_USER" "--ssh-host:$SSH_HOST" "--ssh-port:$SSH_PORT"; do
        [ -n "${pair#*:}" ] || die "${pair%%:*} is required to publish"
    done
    local remote="$SSH_USER@$SSH_HOST" roots="/var/www/$APP_HOST"
    local ssh_cmd=(ssh -p "$SSH_PORT" "$remote")
    [ "$HAS_WEBSITE" -eq 1 ] && roots+=" /var/www/$SITE_HOST"

    [ -f "$OUT/build.info" ] || die "nothing built in $OUT: build first"
    grep -qx "hosting=yes" "$OUT/build.info" \
        || die "$OUT was built with --no-hosting; it is for local use only"
    grep -qxF "hosts=$HOSTS_LINE" "$OUT/build.info" \
        || die "$OUT was built for other hosts than these parameters name: build again"

    echo "==> Publishing $BRAND $ENV_NAME to $remote"
    sed 's/^/      /' "$OUT/build.info"

    # nginx/ and the README first, so a first-time run leaves them on the VPS
    # even when the web roots are not there yet.
    "${ssh_cmd[@]}" "mkdir -p $STAGING"
    rsync -azh --delete -e "ssh -p $SSH_PORT" "$OUT/nginx" "$OUT/README.md" "$remote:$STAGING/"
    echo "==> nginx/ and README.md -> ~/$STAGING/"

    if ! "${ssh_cmd[@]}" "bad=0; for d in $roots; do [ -d \$d ] && [ -w \$d ] || { echo \"  missing or not writable: \$d\" >&2; bad=1; }; done; exit \$bad"; then
        die "web roots are not ready: see step 2 of $OUT/README.md (also on the VPS at ~/$STAGING/README.md)"
    fi

    echo "==> app -> /var/www/$APP_HOST/"
    rsync -azh --delete -e "ssh -p $SSH_PORT" "$OUT/app/" "$remote:/var/www/$APP_HOST/"
    if [ "$HAS_WEBSITE" -eq 1 ]; then
        echo "==> website -> /var/www/$SITE_HOST/"
        rsync -azh --delete -e "ssh -p $SSH_PORT" "$OUT/website/" "$remote:/var/www/$SITE_HOST/"
    fi
    echo "==> Done: $BRAND $ENV_NAME published"
}

case "$ACTION" in
    run)     do_build; do_run ;;
    build)   do_build ;;
    publish) do_publish ;;
    release) do_build; do_publish ;;
esac
