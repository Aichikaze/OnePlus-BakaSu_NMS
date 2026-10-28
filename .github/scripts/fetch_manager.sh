#!/usr/bin/env bash
set -euo pipefail

for v in UPSTREAM DRIVER_VER BASE_VERSION OUT_DIR GH_TOKEN GITHUB_ENV; do
  [ -n "${!v:-}" ] || { echo "::error::fetch_manager: $v is not set"; exit 1; }
done

mkdir -p "$OUT_DIR"
want=$((DRIVER_VER - BASE_VERSION))
if [ "$want" -le 0 ]; then
  echo "::warning::driver build $DRIVER_VER is not above the base $BASE_VERSION; not attaching a manager"
  exit 0
fi

count_of() {
  curl -fsSI -H "Authorization: Bearer $GH_TOKEN" "https://api.github.com/repos/$UPSTREAM/commits?sha=$1&per_page=1" \
    | tr -d '\r' | sed -n 's/^[Ll]ink:.*page=\([0-9]*\)>; rel="last".*/\1/p'
}

run_id="" run_sha="" run_count=0
while read -r id sha; do
  c="$(count_of "$sha" || true)"
  [[ "$c" =~ ^[0-9]+$ ]] || continue
  if [ "$c" -le "$want" ] && [ "$c" -gt "$run_count" ]; then
    run_id="$id" run_sha="$sha" run_count="$c"
    [ "$c" -eq "$want" ] && break
  fi
done < <(gh run list -R "$UPSTREAM" -w 'Build Manager' -b main -s success -L 40 --json databaseId,headSha,event \
  -q '.[] | select(.event != "pull_request") | "\(.databaseId) \(.headSha)"')

if [ -z "$run_id" ]; then
  echo "::warning::no successful Build Manager run on $UPSTREAM main at or before driver build $DRIVER_VER; not attaching a manager"
  exit 0
fi
echo "manager run $run_id at ${run_sha:0:8} (commit count $run_count, driver count $want)"

dl="$(mktemp -d)"
if ! gh run download "$run_id" -R "$UPSTREAM" -n Manager-release -n Spoofed-Manager-release --dir "$dl" 2>/dev/null; then
  echo "run download refused with this token; taking the artifacts through nightly.link"
  for name in Manager-release Spoofed-Manager-release; do
    aid="$(gh api "repos/$UPSTREAM/actions/runs/$run_id/artifacts" -q ".artifacts[] | select(.name == \"$name\" and (.expired | not)) | .id" | head -n1)"
    if [ -z "$aid" ]; then
      echo "::warning::artifact $name of run $run_id has expired; not attaching a manager"
      exit 0
    fi
    curl -fsSL --retry 3 --retry-delay 5 "https://nightly.link/$UPSTREAM/actions/artifacts/$aid.zip" -o "$dl/$name.zip"
    mkdir -p "$dl/$name"
    unzip -qo "$dl/$name.zip" -d "$dl/$name"
  done
fi

normal="$(find "$dl/Manager-release" -name '*-arm64-v8a-release.apk' | head -n1)"
spoofed="$(find "$dl/Spoofed-Manager-release" -name '*-arm64-v8a-release.apk' | head -n1)"
if [ -z "$normal" ] || [ -z "$spoofed" ]; then
  echo "::warning::run $run_id carries no arm64-v8a manager APK pair; not attaching a manager"
  find "$dl" -name '*.apk'
  exit 0
fi

build="$(basename "$normal" | sed -nE 's/.*_([0-9]+)-arm64-v8a-release\.apk$/\1/p')"
[[ "$build" =~ ^[0-9]+$ ]] || build=$((run_count + BASE_VERSION))
if [ "$build" -ne $((run_count + BASE_VERSION)) ]; then
  echo "::warning::manager APK says build $build but its commit count gives $((run_count + BASE_VERSION))"
fi
if cmp -s "$normal" "$spoofed"; then
  echo "::warning::the normal and spoofed APKs of run $run_id are byte-identical; not attaching a manager"
  exit 0
fi

aapt="$(command -v aapt || true)"
[ -n "$aapt" ] || aapt="$(find "${ANDROID_HOME:-/usr/local/lib/android/sdk}/build-tools" -name aapt 2>/dev/null | sort -V | tail -n1 || true)"
pkg_of() {
  [ -n "$aapt" ] || return 0
  "$aapt" dump badging "$1" 2>/dev/null | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -n1 || true
}
normal_pkg="$(pkg_of "$normal")"
spoofed_pkg="$(pkg_of "$spoofed")"

cp "$normal" "$OUT_DIR/BakaSU_${build}_normal.apk"
cp "$spoofed" "$OUT_DIR/BakaSU_${build}_spoofed.apk"

note=""
if [ "$build" -ne "$DRIVER_VER" ]; then
  note=" (the kernels report $DRIVER_VER; the commits in between did not touch the manager, so upstream did not rebuild it)"
fi

{
  echo "MGR_BUILD=$build"
  echo "MGR_RUN=$run_id"
  echo "MGR_SHA=$run_sha"
  echo "MGR_NORMAL=BakaSU_${build}_normal.apk"
  echo "MGR_SPOOFED=BakaSU_${build}_spoofed.apk"
  echo "MGR_NORMAL_PKG=$normal_pkg"
  echo "MGR_SPOOFED_PKG=$spoofed_pkg"
  echo "MGR_NOTE=$note"
} >> "$GITHUB_ENV"

echo "attached BakaSU manager $build from run $run_id: ${normal_pkg:-?} / ${spoofed_pkg:-?}"
ls -la "$OUT_DIR"
