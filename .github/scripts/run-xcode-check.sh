#!/bin/bash
set -euo pipefail

# Keep PR and post-merge invocations identical. Test execution reuses the
# bundle produced by prepare-tests on the same runner.
check="${1:-}"
case "$check" in
  release)
    arguments=(clean build -configuration Release)
    ;;
  prepare-tests)
    arguments=(build-for-testing -configuration Debug)
    ;;
  regression)
    arguments=(test-without-building -configuration Debug
      -skip-testing:AppPortsTests/LocalizationAuditTests)
    ;;
  localization)
    arguments=(test-without-building -configuration Debug
      -only-testing:AppPortsTests/LocalizationAuditTests)
    ;;
  *)
    echo "Usage: $0 {release|prepare-tests|regression|localization}" >&2
    exit 2
    ;;
esac

: "${CI_DERIVED_DATA_PATH:?Set CI_DERIVED_DATA_PATH to a runner-local build directory}"
: "${CI_RESULTS_DIR:?Set CI_RESULTS_DIR to a runner-local diagnostic directory}"
mkdir -p "$CI_RESULTS_DIR"
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

xcodebuild "${arguments[@]}" \
  -project "$repository_root/AppPorts.xcodeproj" \
  -scheme AppPorts \
  -destination 'platform=macOS' \
  -derivedDataPath "$CI_DERIVED_DATA_PATH" \
  -resultBundlePath "$CI_RESULTS_DIR/$check.xcresult" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$CI_RESULTS_DIR/$check.log"
