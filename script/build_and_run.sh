#!/bin/bash
set -euo pipefail

appports_mode="${1:-run}"
case "$appports_mode" in
  run|--build-only|--debug|--logs|--telemetry|--verify) ;;
  *)
    echo "Usage: $0 [--build-only|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

appports_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
appports_configuration="${APPPORTS_BUILD_CONFIGURATION:-Debug}"
appports_derived="${APPPORTS_DERIVED_DATA_PATH:-$appports_root/build/Development}"
appports_bundle="$appports_derived/Build/Products/$appports_configuration/AppPorts.app"
appports_signing_identity="${APPPORTS_CODE_SIGN_IDENTITY:--}"
appports_signing_team="${APPPORTS_DEVELOPMENT_TEAM:-}"
appports_inject_base_entitlements=YES
if [[ "$appports_configuration" == Release ]]; then
  appports_inject_base_entitlements=NO
fi

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  elif [[ -f /Applications/Xcode.app/Contents/Resources/real_app_path.txt ]]; then
    appports_real_xcode="$(tr -d '\r\n' < /Applications/Xcode.app/Contents/Resources/real_app_path.txt)"
    if [[ -n "$appports_real_xcode" && -d "$appports_real_xcode/Contents/Developer" ]]; then
      export DEVELOPER_DIR="$appports_real_xcode/Contents/Developer"
    fi
  fi
fi

xcodebuild build \
  -project "$appports_root/AppPorts.xcodeproj" \
  -scheme AppPorts \
  -configuration "$appports_configuration" \
  -destination 'platform=macOS' \
  -derivedDataPath "$appports_derived" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$appports_signing_identity" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS="$appports_inject_base_entitlements" \
  DEVELOPMENT_TEAM="$appports_signing_team"

if [[ -d "$appports_bundle" ]]; then
  appports_bundle="$(cd "$appports_bundle" && pwd -P)"
fi

if [[ "$appports_mode" == --build-only ]]; then
  printf 'Built AppPorts: %s\n' "$appports_bundle"
  exit 0
fi

# Only restart this development bundle, after its replacement builds. Other
# AppPorts instances may be performing a migration and must remain untouched.
appports_running_bundle_pids() {
  local appports_pid appports_executable
  while read -r appports_pid appports_executable; do
    if [[ "$appports_executable" == "$appports_bundle/Contents/MacOS/AppPorts" ]]; then
      printf '%s\n' "$appports_pid"
    fi
  done < <(/bin/ps -axo pid=,comm=)
}

while read -r appports_pid; do
  [[ -z "$appports_pid" ]] || kill -TERM "$appports_pid"
done < <(appports_running_bundle_pids)

for appports_attempt in {1..20}; do
  [[ -z "$(appports_running_bundle_pids)" ]] && break
  sleep 0.25
done
if [[ -n "$(appports_running_bundle_pids)" ]]; then
  echo "The previous development AppPorts process is still running." >&2
  exit 1
fi

case "$appports_mode" in
  --debug)
    exec xcrun lldb "$appports_bundle/Contents/MacOS/AppPorts"
    ;;
  *)
    /usr/bin/open -n "$appports_bundle"
    ;;
esac

case "$appports_mode" in
  --logs)
    exec /usr/bin/log stream --info --style compact --predicate 'process == "AppPorts"'
    ;;
  --telemetry)
    exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.shimoko.AppPorts"'
    ;;
  --verify)
    for appports_attempt in {1..20}; do
      if [[ -n "$(appports_running_bundle_pids)" ]]; then
        printf 'Running AppPorts: %s\n' "$appports_bundle"
        exit 0
      fi
      sleep 0.25
    done
    echo "The built AppPorts process did not start." >&2
    exit 1
    ;;
esac
