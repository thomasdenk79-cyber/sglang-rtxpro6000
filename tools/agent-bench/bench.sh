#!/usr/bin/env bash
# Run the agent-review benchmark set. One benchmark set runs at a time: this
# script is sequential by default and each harness gets its own detached
# worktree, so the change probe is attributable to a single harness.
set -uo pipefail

usage() {
  echo "usage: $(basename "$0") [--repo PATH] [--head SHA] [--base SHA] [--branch NAME]" \
       "[--limit SECONDS] [--repeats N] [--out DIR] [--only NAME[,NAME]] [--parallel]"
  exit 2
}

REPO=$PWD
HEADSHA=HEAD
BASESHA=6b501b800181756890561fe3107c2ed551c1d302
BRANCH=flashnext/bf16
LIMIT=900
REPEATS=1
OUT=
ONLY=
PARALLEL=0

while (( $# )); do
  case $1 in
    --repo) REPO=$2; shift 2 ;;
    --head) HEADSHA=$2; shift 2 ;;
    --base) BASESHA=$2; shift 2 ;;
    --branch) BRANCH=$2; shift 2 ;;
    --limit) LIMIT=$2; shift 2 ;;
    --repeats) REPEATS=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --only) ONLY=$2; shift 2 ;;
    --parallel) PARALLEL=1; shift ;;
    *) usage ;;
  esac
done

command -v git >/dev/null || exit 2
[[ -d $REPO/.git || -f $REPO/.git ]] || { echo "not a git repository: $REPO" >&2; exit 2; }
HEADSHA=$(git -C "$REPO" rev-parse "$HEADSHA") || exit 2
[[ -n $OUT ]] || OUT="$REPO/tools/agent-bench/runs/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"
printf 'head=%s\nbase=%s\nbranch=%s\nlimit=%s\nrepeats=%s\nstarted=%s\n' \
  "$HEADSHA" "$BASESHA" "$BRANCH" "$LIMIT" "$REPEATS" "$(date -u +%FT%TZ)" > "$OUT/run-set.env"

PROMPT_TEMPLATE="$REPO/tools/agent-bench/prompt.md"
[[ -r $PROMPT_TEMPLATE ]] || { echo "missing prompt template: $PROMPT_TEMPLATE" >&2; exit 2; }

harness_cmd() {
  local name=$1 worktree=$2 prompt_file=$3 runlog=$4
  case $name in
    opencode) echo "opencode run --format json \"\$(cat '$prompt_file')\"" ;;
    codex) echo "codex exec --sandbox read-only --cd '$worktree' - < '$prompt_file'" ;;
    copilot) echo "copilot -C '$worktree' -p \"\$(cat '$prompt_file')\" --allow-all-tools --trust-folder --output-format text" ;;
    hermes) echo "hermes --usage-file '$runlog.usage.json' chat --query-file '$prompt_file' --oneshot -Q --in '$worktree' --run-budget $((LIMIT - 100)) --format text" ;;
    aider) echo "aider --yes-always --no-stream --dry-run --message-file '$prompt_file'" ;;
    *) return 1 ;;
  esac
}

prepare_prompt() {
  local target=$1
  sed -e "s|{{BASE}}|$BASESHA|g" -e "s|{{HEAD}}|$HEADSHA|g" -e "s|{{BRANCH}}|$BRANCH|g" \
    "$PROMPT_TEMPLATE" > "$target"
}

run_one() {
  local name=$1 serial=$2
  local dir="$OUT/$name/run$serial"
  local worktree="$OUT/$name/worktree"
  local log="$dir/log.txt"
  local meta="$dir/meta.env"
  local prompt_file="$dir/prompt.md"
  local start end rc dirty cmd reason
  mkdir -p "$dir"
  git -C "$REPO" worktree add --detach --force "$worktree" "$HEADSHA" >/dev/null 2>&1 || {
    echo "worktree add failed for $name" >&2
    return 3
  }
  prepare_prompt "$prompt_file"
  cmd=$(harness_cmd "$name" "$worktree" "$prompt_file" "$dir/log") || return 2
  start=$(date +%s)
  (
    cd "$worktree" || exit 9
    eval "timeout --signal=TERM --kill-after=30 $LIMIT $cmd"
  ) > "$log" 2>&1
  rc=$?
  end=$(date +%s)
  case $rc in
    0) reason=finished ;;
    124) reason=timeout ;;
    137) reason=killed ;;
    9) reason=no_worktree ;;
    *) reason=error ;;
  esac
  dirty=$(git -C "$worktree" status --porcelain | wc -l)
  git -C "$worktree" status --porcelain > "$dir/gitstatus.txt"
  {
    echo "name=$name"
    echo "serial=$serial"
    echo "rc=$rc"
    echo "secs=$((end - start))"
    echo "bytes=$(wc -c < "$log")"
    echo "dirty=$dirty"
    echo "exit_reason=$reason"
    echo "start=$(date -u -d @"$start" +%FT%TZ)"
    echo "end=$(date -u -d @"$end" +%FT%TZ)"
  } > "$meta"
  git -C "$REPO" worktree remove --force "$worktree" >/dev/null 2>&1
  echo "DONE $name run$serial rc=$rc secs=$((end - start)) dirty=$dirty"
}

names=(opencode codex copilot hermes aider)
if [[ -n $ONLY ]]; then
  IFS=, read -r -a names <<< "$ONLY"
fi

for name in "${names[@]}"; do
  for serial in $(seq 1 "$REPEATS"); do
    if (( PARALLEL )); then
      run_one "$name" "$serial" &
    else
      run_one "$name" "$serial"
    fi
  done
done
(( PARALLEL )) && wait

printf 'finished=%s\n' "$(date -u +%FT%TZ)" >> "$OUT/run-set.env"
echo "RUN_SET_DONE out=$OUT"
