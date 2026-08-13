#!/bin/bash
START=$(date +%s)

./check_release.sh 2>&1 | while IFS= read -r line; do
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
done
BUILD_EXIT=${PIPESTATUS[0]}

END=$(date +%s)
ELAPSED=$((END - START))
printf '\n=== Finished with exit code %d ===\n' "$BUILD_EXIT"
printf '=== Total elapsed: %02d:%02d:%02d ===\n' $((ELAPSED/3600)) $((ELAPSED%3600/60)) $((ELAPSED%60))
exit "$BUILD_EXIT"
