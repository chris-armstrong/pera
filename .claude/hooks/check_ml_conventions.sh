#!/usr/bin/env bash
# Mechanical OCaml convention checks fired on Write/Edit tool use.
# Reads hook JSON from stdin; checks .ml files only.

set -euo pipefail

input=$(cat)
tool=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null || true)
file=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path',''))" 2>/dev/null || true)

[[ -z "$file" ]] && exit 0
[[ "$file" != *.ml ]] && exit 0
[[ ! -f "$file" ]] && exit 0

violations=()

# 1. open Containers must be present in every .ml file
if ! grep -q "^open Containers" "$file"; then
  violations+=("MISSING: 'open Containers' not found at top of $file (pera-specific.md §1)")
fi

# 2. Structural equality on non-primitive expressions (heuristic: `x = y` where x is not an int/string literal)
# Flag any `= ` that isn't inside a comment and looks like structural eq on values
if grep -nP '(?<![!=<>])(?<!\(\*.*) = (?![=>])' "$file" | grep -vP '^\s*\(\*' | grep -vP '"[^"]*"' | grep -vP '^\s*\|' | grep -qP '\w+ = \w+'; then
  lines=$(grep -nP '(?<![!=<>])(?<!\(\*.*) = (?![=>])' "$file" | grep -vP '^\s*\(\*' | grep -vP 'type\s' | grep -P '\w+ = \w+' | head -5)
  if [[ -n "$lines" ]]; then
    violations+=("POSSIBLE STRUCTURAL EQ: check for Stdlib.(=) usage in $file — use type-specific equality (partial-functions.md §5):")
    violations+=("  $lines")
  fi
fi

# 3. ocamlformat check
if command -v ocamlformat &>/dev/null; then
  if ! ocamlformat --check "$file" 2>/dev/null; then
    violations+=("FORMATTING: $file needs ocamlformat — run: ocamlformat -i $file")
  fi
fi

if [[ ${#violations[@]} -gt 0 ]]; then
  echo "=== OCaml Convention Violations ==="
  for v in "${violations[@]}"; do
    echo "  $v"
  done
  echo ""
  echo "Fix these before the reviewer runs. See docs/guidelines/ for details."
  exit 1
fi

exit 0
