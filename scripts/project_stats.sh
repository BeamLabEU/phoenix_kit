#!/usr/bin/env bash
#
# Collect PhoenixKit project statistics and save a dated report.
# Usage: ./scripts/project_stats.sh
# Output: dev_docs/status/stats/YYYY-MM-DD-project-stats.md

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

DATE=$(date +%Y-%m-%d)
OUTDIR="dev_docs/status/stats"
OUTFILE="$OUTDIR/$DATE-project-stats.md"

mkdir -p "$OUTDIR"

# --- Gather stats ---

VERSION=$(grep '@version "' mix.exs | head -1 | sed 's/.*"\(.*\)".*/\1/')
MIGRATION_VERSION=$(ls lib/phoenix_kit/migrations/postgres/v*.ex 2>/dev/null | sed 's/.*\/v\([0-9]*\)\.ex/\1/' | sort -rn | head -1)
GIT_COMMITS=$(git log --oneline | wc -l | tr -d ' ')
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
GIT_SHA=$(git rev-parse --short HEAD)

# Source files
EX_FILES=$(find lib -name "*.ex" | wc -l | tr -d ' ')
HEEX_FILES=$(find lib -name "*.heex" | wc -l | tr -d ' ')
EX_LINES=$(find lib -name "*.ex" -exec cat {} + | wc -l | tr -d ' ')
HEEX_LINES=$(find lib -name "*.heex" -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')
COMMENT_LINES=$(find lib -name "*.ex" -exec cat {} + | grep -cE '^\s*#' || true)
BLANK_LINES=$(find lib -name "*.ex" -exec cat {} + | grep -c '^$' || true)
EFFECTIVE_LINES=$((EX_LINES - COMMENT_LINES - BLANK_LINES))

# Modules and functions
MODULES=$(grep -r "^defmodule " lib/ --include="*.ex" | wc -l | tr -d ' ')
FUNCTIONS=$(grep -rE '^\s+(def |defp )' lib/ --include="*.ex" | wc -l | tr -d ' ')
MACROS=$(grep -r "defmacro " lib/ --include="*.ex" | wc -l | tr -d ' ')

# Tests
TEST_FILES=$(find test -name "*.ex" -o -name "*.exs" | wc -l | tr -d ' ')
TEST_MODULES=$(grep -r "^defmodule " test/ --include="*.ex" --include="*.exs" | wc -l | tr -d ' ')
TEST_CASES=$(grep -rc 'test "' test/ --include="*.exs" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')
TEST_LINES=$(find test -name "*.ex" -o -name "*.exs" | xargs cat 2>/dev/null | wc -l | tr -d ' ')

# Dependencies
DEPS=$(grep -A 200 "defp deps" mix.exs | grep "{:" | wc -l | tr -d ' ')

# Top-level modules
TOP_MODULES=$(ls -d lib/phoenix_kit/*/ 2>/dev/null | sed 's|lib/phoenix_kit/||;s|/||' | sort | paste -sd, - | sed 's/,/, /g')

# Total lines
TOTAL_LINES=$((EX_LINES + HEEX_LINES + TEST_LINES))

# --- Write report ---

cat > "$OUTFILE" <<EOF
# PhoenixKit Project Stats — $DATE

**Version:** $VERSION | **Branch:** $GIT_BRANCH | **Commit:** $GIT_SHA | **Migration:** v$MIGRATION_VERSION

## Source Code (lib/)

| Metric | Count |
|---|---|
| Elixir files (.ex) | $EX_FILES |
| HEEx templates (.heex) | $HEEX_FILES |
| Modules | $MODULES |
| Functions (def/defp) | $FUNCTIONS |
| Macros (defmacro) | $MACROS |
| Lines of Elixir | $EX_LINES |
| Lines of HEEx | $HEEX_LINES |
| Comment lines | $COMMENT_LINES |
| Blank lines | $BLANK_LINES |
| Effective code lines | $EFFECTIVE_LINES |

## Tests (test/)

| Metric | Count |
|---|---|
| Test files | $TEST_FILES |
| Test modules | $TEST_MODULES |
| Test cases | $TEST_CASES |
| Lines of test code | $TEST_LINES |

## Project

| Metric | Value |
|---|---|
| Version | $VERSION |
| Migration version | v$MIGRATION_VERSION |
| Dependencies | $DEPS |
| Git commits | $GIT_COMMITS |

## Top-Level Modules

$TOP_MODULES

## Totals

- **$TOTAL_LINES** total lines (Elixir + HEEx + test)
- **$((EX_FILES + HEEX_FILES + TEST_FILES))** total files
EOF

echo "Report saved to $OUTFILE"
