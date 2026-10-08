#!/bin/bash
set -euo pipefail

if (( $# == 0 || $# % 2 != 0 )); then
  echo "Usage: $0 'Check name' 'step outcome' [...]" >&2
  exit 2
fi
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"

printf '| Check | Result |\n| --- | --- |\n' >> "$GITHUB_STEP_SUMMARY"
while (( $# > 0 )); do
  check_name="$1"
  outcome="$2"
  shift 2
  case "$outcome" in
    success) result='✅ Passed' ;;
    failure)
      result='❌ Failed — see the diagnostic artifact'
      printf '::warning::%s failed. See the diagnostic artifact.\n' "$check_name"
      ;;
    cancelled) result='⏹ Cancelled' ;;
    skipped|'') result='⏭ Not run' ;;
    *) result='⚠ Unknown — inspect the job log' ;;
  esac
  printf '| %s | %s |\n' "$check_name" "$result" >> "$GITHUB_STEP_SUMMARY"
done
