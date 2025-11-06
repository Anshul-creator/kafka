#!/usr/bin/env bash
set -u

# Usage: ./run_flaky_min.sh [NUM_RUNS]
RUNS="${1:-10}"
GRADLE_CMD="./gradlew cleanTest test -Pkafka.test.run.flaky=true --rerun-tasks --console=plain"

for i in $(seq 1 "$RUNS"); do
  echo "========== Run $i =========="
  set +e
  $GRADLE_CMD >/tmp/kafka_flaky_run_$i.log 2>&1
  STATUS=$?
  set -e

  if [[ $STATUS -eq 0 ]]; then
    echo "Run $i: PASS (no failures)"
    continue
  fi

  echo "Run $i: FAIL"
  # Find failing testcases from Gradle/JUnit XML reports (per module)
  # Example XML files live under: core/build/test-results/test/*.xml, clients/build/test-results/test/*.xml, etc.
  while IFS= read -r xml; do
    module=$(echo "$xml" | cut -d/ -f1)  # module name (e.g., core, clients, streams, ...)
    # For each <testcase> that has a <failure>, extract classname, name, and failure message (first line)
    awk -v module="$module" '
      BEGIN { RS="</testcase>"; FS="\n" }
      /<failure/ {
        # pull attributes from the <testcase ...> opening line
        match($0, /classname="([^"]+)"/, c); cls=c[1]
        match($0, /name="([^"]+)"/, n);      meth=n[1]
        # message attribute (if present) and first line of failure text
        msg=""
        if (match($0, /<failure[^>]*message="([^"]*)"/, m)) msg=m[1]
        # collapse newlines and grab first non-empty line of failure body (stack trace)
        body=$0
        gsub(/\r/, "", body)
        # extract content between <failure>...</failure>
        if (match(body, /<failure[^>]*>([[:space:][:print:]]*)<\/failure>/, b)) {
          split(b[1], lines, "\n")
          for (k in lines) {
            if (lines[k] ~ /[^[:space:]]/) { if (msg=="") msg=lines[k]; break }
          }
        }
        # Build path to the class HTML report:
        # module/build/reports/tests/test/classes/<fully.qualified.ClassName>.html
        report=module "/build/reports/tests/test/classes/" cls ".html"
        printf("  - %s#%s\n    report: %s\n    error : %s\n", cls, meth, report, msg)
      }
    ' "$xml"
  done < <(ls -1 */build/test-results/test/*.xml 2>/dev/null | sort)

  # Also print where the per-module index pages are
  idx=$(ls -1 */build/reports/tests/test/index.html 2>/dev/null | tr '\n' ' ')
  if [[ -n "$idx" ]]; then
    echo "Module test report index pages: $idx"
  fi
done