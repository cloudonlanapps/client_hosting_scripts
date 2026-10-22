#!/usr/bin/env bash
set -euo pipefail

# deploy_android.sh — build a brand's member app for Android (an APK) from a
# core repository's app template. Generic: every name, id, URL and ref arrives
# as a parameter; nothing here knows a product, a repository or a branch. A
# wrapper (one per organisation) supplies them.
#
#   deploy_android.sh --brand <dir> --env <label>
#                     --core-url <git url> --core-ref <branch> --generator <dir in core>
#                     --api-url <url> --android-id <application id>
#                     [--android-name <app name>] [--app-url <url>] [--website-url <url>]
#                     --work-dir <dir> [--out-dir <dir>]
#
# Clones the core at --core-ref into <work>/core, runs its generator for the
# app with --android-id (and --android-name), runs `flutter build apk
# --release`, and writes <out>/: <brand>-<env>.apk and build.info.
#
# The generator is <core>/<generator>, a Dart package whose bin/generate.dart
# takes --target app --brand --out --api-url [--app-url] [--website-url]
# --android-id [--android-name] and creates a project that `flutter build apk`
# builds. Requires git and flutter with the Android SDK.

die() { echo "ERROR: $*" >&2; exit 1; }

BRAND_DIR="" ENV_NAME="" BRAND=""
CORE_URL="" CORE_REF="" GENERATOR=""
API_URL="" APP_URL="" WEBSITE_URL="" ANDROID_ID="" ANDROID_NAME=""
WORK="" OUT=""

while [ $# -gt 0 ]; do
    case "$1" in -h|--help) sed -n '4,22p' "$0"; exit 0 ;; esac
    [ $# -ge 2 ] || die "$1 needs a value"
    case "$1" in
        --brand)        BRAND_DIR="$2" ;;
        --brand-name)   BRAND="$2" ;;
        --env)          ENV_NAME="$2" ;;
        --core-url)     CORE_URL="$2" ;;
        --core-ref)     CORE_REF="$2" ;;
        --generator)    GENERATOR="$2" ;;
        --api-url)      API_URL="$2" ;;
        --app-url)      APP_URL="$2" ;;
        --website-url)  WEBSITE_URL="$2" ;;
        --android-id)   ANDROID_ID="$2" ;;
        --android-name) ANDROID_NAME="$2" ;;
        --work-dir)     WORK="$2" ;;
        --out-dir)      OUT="$2" ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift 2
done

for pair in "--brand:$BRAND_DIR" "--env:$ENV_NAME" "--core-url:$CORE_URL" "--core-ref:$CORE_REF" \
            "--generator:$GENERATOR" "--api-url:$API_URL" "--android-id:$ANDROID_ID" "--work-dir:$WORK"; do
    [ -n "${pair#*:}" ] || die "${pair%%:*} is required"
done
[[ "$API_URL" =~ ^https?://[^/]+ ]] || die "--api-url must be a whole http(s) URL, got '$API_URL'"
[[ "$ANDROID_ID" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]] \
    || die "--android-id must look like org.example.app, got '$ANDROID_ID'"

BRAND_DIR="$(cd "$BRAND_DIR" 2>/dev/null && pwd)" || die "brand folder not found"
[ -n "$BRAND" ] || BRAND="$(basename "$BRAND_DIR")"
mkdir -p "$WORK"; WORK="$(cd "$WORK" && pwd)"
[ -n "$OUT" ] || OUT="$WORK/out-android"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# sync_repo <url> <branch> <dir> — make <dir> exactly origin/<branch>, cloning
# if needed, and set SYNCED_SHA. (As in web/deploy_web.sh.)
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

echo "==> $BRAND ($ENV_NAME): Android app $ANDROID_ID against $API_URL"
sync_repo "$CORE_URL" "$CORE_REF" "$WORK/core"
core_sha="$SYNCED_SHA"

project="$WORK/android_app"
rm -rf "$project"
gen_args=(--target app --brand "$BRAND_DIR" --out "$project" --api-url "$API_URL" --android-id "$ANDROID_ID")
[ -n "$ANDROID_NAME" ] && gen_args+=(--android-name "$ANDROID_NAME")
[ -n "$APP_URL" ]      && gen_args+=(--app-url "$APP_URL")
[ -n "$WEBSITE_URL" ]  && gen_args+=(--website-url "$WEBSITE_URL")
(
    cd "$WORK/core/$GENERATOR"
    dart pub get >/dev/null
    dart run bin/generate.dart "${gen_args[@]}"
)

TS="$(date '+%Y%m%d%H%M%S')"
rm -f "$OUT"/*.apk "$OUT/build.info"
(
    cd "$project"
    flutter build apk --release --dart-define="BUILD_TIMESTAMP=$TS"
)
apk="$OUT/$BRAND-$ENV_NAME.apk"
cp "$project/build/app/outputs/flutter-apk/app-release.apk" "$apk"

tool_sha="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
flutter_version="$(flutter --version 2>/dev/null | head -1 | awk '{print $2}')"
{
    echo "brand=$BRAND"
    echo "env=$ENV_NAME"
    echo "built=$TS"
    echo "core=$CORE_URL"
    echo "core_ref=$CORE_REF"
    echo "core_commit=$core_sha"
    echo "tooling_commit=$tool_sha"
    echo "flutter=$flutter_version"
    echo "api=$API_URL"
    echo "android_id=$ANDROID_ID"
    echo "apk=$(basename "$apk")"
} > "$OUT/build.info"
echo "==> built $apk"
sed 's/^/      /' "$OUT/build.info"
