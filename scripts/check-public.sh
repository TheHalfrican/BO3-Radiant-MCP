#!/usr/bin/env bash
# Public pre-push check. Everything pushed to origin is mirrored to a public
# GitHub repo, so this fails if the commits being pushed contain game files,
# decompiled code, secrets, private hostnames, or local user paths.
#
# Usage:
#   scripts/check-public.sh                 check commits not yet on origin/main
#   scripts/check-public.sh <rev-range>...  check the given git rev-list arguments
#   scripts/check-public.sh --hook          read pre-push hook lines from stdin
#
# Patterns are assembled from pieces so this script does not trip itself.

set -u
cd "$(git rev-parse --show-toplevel)" || exit 2

ZERO=0000000000000000000000000000000000000000
problems=()
fail() { problems+=("$1"); }

# --- Work out which commits to check -----------------------------------------
ranges=()
if [ "${1:-}" = "--hook" ]; then
  while read -r _local_ref local_sha _remote_ref remote_sha; do
    [ -z "${local_sha:-}" ] && continue
    [ "$local_sha" = "$ZERO" ] && continue  # branch deletion
    if [ "$remote_sha" = "$ZERO" ]; then
      ranges+=("$local_sha --not --remotes=origin")
    else
      ranges+=("$remote_sha..$local_sha")
    fi
  done
elif [ $# -gt 0 ]; then
  ranges+=("$*")
elif git rev-parse -q --verify origin/main >/dev/null; then
  ranges+=("origin/main..HEAD")
else
  ranges+=("HEAD")
fi

commits=$(for r in "${ranges[@]}"; do
  # shellcheck disable=SC2086
  git rev-list $r
done | sort -u)

if [ -z "$commits" ]; then
  echo "check-public: nothing to check"
  exit 0
fi
count=$(echo "$commits" | wc -l | tr -d ' ')

# --- Private values from .env (never stored in this script) -----------------
private_hosts=()
if [ -f .env ]; then
  while IFS='=' read -r key value; do
    case "$key" in
      GITEA_REMOTE)
        host=$(echo "$value" | sed -E 's#^[a-z+]+://##; s#^[^@/]*@##; s#[:/].*$##')
        [ -n "$host" ] && private_hosts+=("$host")
        ;;
      BO3_ROOT)
        [ -z "${BO3_ROOT:-}" ] && BO3_ROOT="$value"
        ;;
    esac
  done < .env
fi
[ -n "${USERNAME:-}" ] && user_name="$USERNAME" || user_name="${USER:-}"

# --- 1. File names added or modified anywhere in the pushed history ----------
dot='\.'
forbidden_ext="${dot}(exe|dll|pdb|ff|xpak|gdt|sabs|sabl|fd|fgr|ipak)$"
ghidra_ext="${dot}(gzf|gpr|rep|lst|xml|c|cc|cpp|h|hpp)$"

files=$(for c in $commits; do
  git diff-tree --root --no-commit-id -r --name-only --diff-filter=ACMR "$c"
done | sort -u)

while IFS= read -r f; do
  [ -z "$f" ] && continue
  base=${f##*/}
  if echo "$f" | grep -Eiq "$forbidden_ext"; then
    fail "game/binary file type: $f"
  fi
  if echo "$f" | grep -Eiq '\.map$' && ! echo "$f" | grep -q '^server/test/fixtures/'; then
    fail ".map outside server/test/fixtures/: $f"
  fi
  if echo "$f" | grep -q '^re/' && echo "$f" | grep -Eiq "$ghidra_ext"; then
    fail "possible Ghidra export or decompiled source under re/: $f"
  fi
  if [ "$base" = ".env" ] || { echo "$base" | grep -q '^\.env\.' && [ "$base" != ".env.example" ]; }; then
    fail "env file: $f"
  fi
  if echo "$f" | grep -q '^backups/'; then
    fail "backup file: $f"
  fi
  # GSC/CSC identical to a stock script
  if echo "$f" | grep -Eiq '\.(gsc|csc)$' && [ -n "${BO3_ROOT:-}" ] && [ -d "$BO3_ROOT/share/raw" ]; then
    ours=$(git show "HEAD:$f" 2>/dev/null | git hash-object --stdin)
    while IFS= read -r stock; do
      [ "$(git hash-object "$stock")" = "$ours" ] && fail "identical to stock script: $f"
    done < <(find "$BO3_ROOT/share/raw" -iname "$base" 2>/dev/null)
  fi
done <<< "$files"

# Binary files of any kind other than images
while IFS=$'\t' read -r added deleted path; do
  [ "$added" = "-" ] && [ "$deleted" = "-" ] || continue
  echo "$path" | grep -Eiq '\.(png|jpe?g|gif|ico|svg|webp)$' && continue
  fail "binary file: $path"
done < <(for c in $commits; do git diff-tree --root --no-commit-id -r --numstat "$c"; done | sort -u)

# --- 2. Content of added lines -----------------------------------------------
content_patterns=(
  "local user path|[A-Za-z]:[\\\\/]+Users[\\\\/]+[A-Za-z0-9._-]+"
  "private IP|(^|[^0-9.])(10\\.[0-9]{1,3}|192\\.168|172\\.(1[6-9]|2[0-9]|3[01])|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7]))\\.[0-9]{1,3}\\.[0-9]{1,3}"
  "Tailscale hostname|[A-Za-z0-9-]+\\.[A-Za-z0-9-]+\\.ts""\\.net"
  "GitHub token|gh""[pousr]_[A-Za-z0-9]{30,}|github""_pat_[A-Za-z0-9_]{30,}"
  "AWS key|AK""IA[0-9A-Z]{16}"
  "private key|-----BEGIN [A-Z ]*PRIVATE ""KEY-----"
  "Slack token|xox""[baprs]-[A-Za-z0-9-]{10,}"
)
for h in "${private_hosts[@]}"; do
  content_patterns+=("private host from .env|$(printf '%s' "$h" | sed 's/[.[\*^$()+?{|]/\\&/g')")
done
if [ -n "$user_name" ]; then
  content_patterns+=("local username|[\\\\/]$(printf '%s' "$user_name" | sed 's/[.[\*^$()+?{|]/\\&/g')([\\\\/]|\$)")
fi

decomp_marker="\\bundefined""[1248]?\\b|\\bin_stack""_[0-9a-f]+|/\\* WARN""ING: |\\bextraout""_[A-Z]+|\\bunaff""_[A-Za-z0-9]+"

added=$(for c in $commits; do git show --format= -p --no-color --no-ext-diff "$c"; done |
  awk '/^\+\+\+ /{ f=$2; sub(/^b\//,"",f); next } /^\+/{ print f "\t" substr($0,2) }')

for entry in "${content_patterns[@]}"; do
  label=${entry%%|*}
  regex=${entry#*|}
  hits=$(printf '%s\n' "$added" | grep -E -- "$regex" | cut -f1 | sort -u)
  while IFS= read -r p; do
    [ -n "$p" ] && fail "$label in $p"
  done <<< "$hits"
done

# Decompiler output: flag files with several Ghidra pseudo-C markers
while read -r n p; do
  [ "$n" -ge 5 ] && fail "decompiler-style output ($n marker lines) in $p"
done < <(printf '%s\n' "$added" | grep -E -- "$decomp_marker" | cut -f1 | sort | uniq -c)

# --- Report -------------------------------------------------------------------
if [ ${#problems[@]} -gt 0 ]; then
  echo "check-public: FAILED ($count commit(s) checked). Fix the commits; never bypass with --no-verify." >&2
  printf '  - %s\n' "${problems[@]}" | sort -u >&2
  exit 1
fi
echo "check-public: OK ($count commit(s) checked)"
