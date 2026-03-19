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

# --- File distribution ---

count_files() {
  find "$1" -name "*.ex" -o -name "*.heex" 2>/dev/null | wc -l | tr -d ' '
}

TOTAL_SRC_FILES=$(count_files lib)

# Core areas (lib/phoenix_kit/ + lib/phoenix_kit_web/ + lib/mix/ + lib/phoenix_kit.ex)
CORE_WEB_COMPONENTS=$(count_files lib/phoenix_kit_web/components)
CORE_MIGRATIONS=$(count_files lib/phoenix_kit/migrations)
CORE_MIX_TASKS=$(count_files lib/mix)
CORE_WEB_LIVE=$(count_files lib/phoenix_kit_web/live)
CORE_INSTALL=$(count_files lib/phoenix_kit/install)
CORE_USERS=$(count_files lib/phoenix_kit/users)
CORE_WEB_USERS=$(count_files lib/phoenix_kit_web/users)
CORE_WEB_CONTROLLERS=$(count_files lib/phoenix_kit_web/controllers)
CORE_UTILS=$(count_files lib/phoenix_kit/utils)
CORE_DASHBOARD=$(($(count_files lib/phoenix_kit/dashboard) + $(count_files lib/phoenix_kit_web/dashboard)))
CORE_CONFIG=$(count_files lib/phoenix_kit/config)

# Module files
MODULES_TOTAL=$(count_files lib/modules)

# Core total = total - modules
CORE_TOTAL=$((TOTAL_SRC_FILES - MODULES_TOTAL))

# Core subcategory sum
CORE_CATEGORIZED=$((CORE_WEB_COMPONENTS + CORE_MIGRATIONS + CORE_MIX_TASKS + CORE_WEB_LIVE + CORE_INSTALL + CORE_USERS + CORE_WEB_USERS + CORE_WEB_CONTROLLERS + CORE_UTILS + CORE_DASHBOARD + CORE_CONFIG))
CORE_OTHER=$((CORE_TOTAL - CORE_CATEGORIZED))

# Per-module counts (sorted by count descending)
MODULE_ROWS=""
for d in lib/modules/*/; do
  name=$(basename "$d")
  count=$(count_files "$d")
  MODULE_ROWS="${MODULE_ROWS}${count} ${name}\n"
done
MODULE_ROWS_SORTED=$(printf '%b' "$MODULE_ROWS" | sort -rn)

# Helper: format percentage
pct() {
  local n=$1 total=$2
  if [ "$total" -eq 0 ]; then echo "0.0"; return; fi
  awk "BEGIN { printf \"%.1f\", ($n / $total) * 100 }"
}

# Helper: capitalize first letter
capitalize() {
  echo "$1" | sed 's/\b\(.\)/\u\1/g; s/_/ /g'
}

# Build the file distribution table for the report
build_dist_table() {
  local total=$TOTAL_SRC_FILES

  echo "| Category | Files | % |"
  echo "|---|---|---|"
  echo "| **CORE** | **$CORE_TOTAL** | **$(pct $CORE_TOTAL $total)%** |"

  # Core subcategories (only show if > 0, sorted by count desc)
  local -a names=("Web Components" "Migrations" "Mix Tasks" "Web LiveViews" "Install" "Users" "Web Users" "Web Controllers" "Utils" "Dashboard" "Config" "Other core")
  local -a counts=($CORE_WEB_COMPONENTS $CORE_MIGRATIONS $CORE_MIX_TASKS $CORE_WEB_LIVE $CORE_INSTALL $CORE_USERS $CORE_WEB_USERS $CORE_WEB_CONTROLLERS $CORE_UTILS $CORE_DASHBOARD $CORE_CONFIG $CORE_OTHER)

  # Sort subcategories by count (descending)
  local sorted
  sorted=$(for i in "${!names[@]}"; do
    echo "${counts[$i]} ${names[$i]}"
  done | sort -rn)

  while IFS= read -r line; do
    local c="${line%% *}"
    local n="${line#* }"
    if [ "$c" -gt 0 ]; then
      echo "| \`├\` $n | $c | $(pct "$c" "$total")% |"
    fi
  done <<< "$sorted"

  echo "| **MODULES** | **$MODULES_TOTAL** | **$(pct $MODULES_TOTAL $total)%** |"

  # Per-module rows
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local c="${line%% *}"
    local n="${line#* }"
    local display_name
    display_name=$(capitalize "$n")
    echo "| \`├\` $display_name | $c | $(pct "$c" "$total")% |"
  done <<< "$MODULE_ROWS_SORTED"

  echo "| **TOTAL** | **$total** | **100.0%** |"
}

FILE_DIST_TABLE=$(build_dist_table)

# --- Terminal output: box-drawing table ---

print_box_table() {
  local total=$TOTAL_SRC_FILES
  local col1=22 col2=7 col3=7

  local h_line
  h_line=$(printf '─%.0s' $(seq 1 $col1))
  local h2
  h2=$(printf '─%.0s' $(seq 1 $col2))
  local h3
  h3=$(printf '─%.0s' $(seq 1 $col3))

  # Pad text to display width (handles multi-byte UTF-8 chars)
  pad_right() {
    local text="$1" width="$2"
    local display_len=${#text}
    # Count multi-byte chars (each box char = 3 bytes but 1 display width)
    local byte_len=$(printf '%s' "$text" | wc -c)
    local extra=$((byte_len - display_len))
    local pad_width=$((width + extra))
    printf "%-${pad_width}s" "$text"
  }

  row() {
    printf "  │ %s│ %5s │ %5s │\n" "$(pad_right "$1" $col1)" "$2" "$3"
  }

  echo "  ┌${h_line}┬${h2}┬${h3}┐"
  row "Category" "Files" "%"
  echo "  ├${h_line}┼${h2}┼${h3}┤"
  row "CORE" "$CORE_TOTAL" "$(pct $CORE_TOTAL $total)%"

  # Core subcategories sorted
  local sorted
  sorted=$(
    local -a names=("Web Components" "Migrations" "Mix Tasks" "Web LiveViews" "Install" "Users" "Web Users" "Web Controllers" "Utils" "Dashboard" "Config" "Other core")
    local -a counts=($CORE_WEB_COMPONENTS $CORE_MIGRATIONS $CORE_MIX_TASKS $CORE_WEB_LIVE $CORE_INSTALL $CORE_USERS $CORE_WEB_USERS $CORE_WEB_CONTROLLERS $CORE_UTILS $CORE_DASHBOARD $CORE_CONFIG $CORE_OTHER)
    for i in "${!names[@]}"; do echo "${counts[$i]} ${names[$i]}"; done | sort -rn
  )

  while IFS= read -r line; do
    local c="${line%% *}"
    local n="${line#* }"
    if [ "$c" -gt 0 ]; then
      echo "  ├${h_line}┼${h2}┼${h3}┤"
      row "├ $n" "$c" "$(pct "$c" "$total")%"
    fi
  done <<< "$sorted"

  echo "  ├${h_line}┼${h2}┼${h3}┤"
  row "MODULES" "$MODULES_TOTAL" "$(pct $MODULES_TOTAL $total)%"

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local c="${line%% *}"
    local n="${line#* }"
    local display_name
    display_name=$(capitalize "$n")
    echo "  ├${h_line}┼${h2}┼${h3}┤"
    row "├ $display_name" "$c" "$(pct "$c" "$total")%"
  done <<< "$MODULE_ROWS_SORTED"

  echo "  ├${h_line}┼${h2}┼${h3}┤"
  row "TOTAL" "$total" "100.0%"
  echo "  └${h_line}┴${h2}┴${h3}┘"
}

# Print to terminal
echo ""
echo "  File Distribution ($TOTAL_SRC_FILES source files)"
echo ""
print_box_table
echo ""

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

## File Distribution

$FILE_DIST_TABLE

## Top-Level Modules

$TOP_MODULES

## Totals

- **$TOTAL_LINES** total lines (Elixir + HEEx + test)
- **$((EX_FILES + HEEX_FILES + TEST_FILES))** total files
EOF

echo "Report saved to $OUTFILE"
