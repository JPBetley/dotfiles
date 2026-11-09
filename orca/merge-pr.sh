#!/usr/bin/env bash
#
# merge-pr.sh — merge the current branch's PR into its base, respecting branch
# protection rules.
#
# Loop:
#   1. Wait for the running checks to finish (protection: checks must pass).
#   2. If the base branch moved ahead, merge it into the PR branch
#      (protection: branch must be up to date). This kicks off a new check run,
#      so we loop back to step 1.
#   3. When the branch is up to date AND green, merge the PR.
#
# Exits non-zero (with a reason) if checks fail or a base merge conflicts.
#
# This is the manual equivalent of `gh pr merge --auto --squash`. GitHub's
# native auto-merge only re-runs the "keep branch up to date" step if the repo
# has *both* auto-merge and "automatically update branch" enabled. When that
# auto-update setting is off (our case), this script drives the update loop.
#
# Requires: gh >= 2.40 (for `gh pr update-branch`).
#
# Usage: ./merge-pr.sh [PR number]   (defaults to the current branch's PR)

set -euo pipefail

PR="${1:-}"

die()  { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '\033[36m→ %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }

command -v gh >/dev/null || die "gh CLI is not installed."

# `gh pr update-branch` landed in gh 2.40. Bail early with a clear message
# rather than failing cryptically mid-loop on older versions.
GH_VERSION=$(gh --version | awk 'NR==1 {print $3}')
if [[ -n "$GH_VERSION" ]]; then
  IFS=. read -r gh_major gh_minor _ <<<"$GH_VERSION"
  if (( gh_major < 2 || (gh_major == 2 && gh_minor < 40) )); then
    die "gh $GH_VERSION is too old — 'gh pr update-branch' needs gh >= 2.40."
  fi
fi

# Per-run temp files for capturing gh stderr, cleaned up on exit. Using mktemp
# (rather than fixed /tmp paths) avoids collisions between concurrent runs and
# predictable-filename issues.
ERR=$(mktemp -t merge-pr.XXXXXX)
trap 'rm -f "$ERR"' EXIT

# Resolve the PR for the current branch if one wasn't passed.
if [[ -z "$PR" ]]; then
  PR=$(gh pr view --json number --jq .number 2>/dev/null) \
    || die "No PR found for the current branch. Pass a PR number explicitly."
fi

read_pr() { gh pr view "$PR" --json "$1" --jq ".$1"; }

TITLE=$(read_pr title)
STATE=$(read_pr state)
[[ "$STATE" == "OPEN" ]] || die "PR #$PR is $STATE, not OPEN."

info "Merging PR #$PR: $TITLE"

# Re-read mergeStateStatus, polling past the states GitHub reports *transiently*
# while it recomputes mergeability after checks settle: UNKNOWN (not yet
# computed) and a brief UNSTABLE/BLOCKED flicker. Prints the settled state on
# stdout. Gives up (returns the last value seen) after SETTLE_TRIES attempts so
# a genuinely-stuck state still surfaces to the caller's case statement.
settle_merge_state() {
  local tries=6 delay=5 state
  for ((i = 1; i <= tries; i++)); do
    state=$(read_pr mergeStateStatus)
    case "$state" in
      UNKNOWN | UNSTABLE | BLOCKED)
        # Transient while GitHub recomputes — wait and re-read. A real BLOCKED
        # (missing approval / required check) or UNSTABLE simply persists and is
        # returned once we exhaust the tries.
        [[ $i -lt $tries ]] && sleep "$delay"
        ;;
      *)
        printf '%s' "$state"
        return 0
        ;;
    esac
  done
  printf '%s' "$state"
}

MAX_ROUNDS=10
for ((round = 1; round <= MAX_ROUNDS; round++)); do
  info "Round $round: waiting for checks to finish…"

  # The head SHA we're about to watch checks for. If it changes out from under
  # us during the watch (e.g. someone pushed), we re-loop rather than merge a
  # commit we never saw go green.
  WATCHED_SHA=$(read_pr headRefOid)

  # --watch blocks until every check completes; it exits non-zero if any fail.
  # "no checks reported" also exits non-zero, which we treat as success below.
  if gh pr checks "$PR" --watch --interval 15 2>"$ERR"; then
    ok "All checks passed."
  else
    if grep -qi "no checks reported" "$ERR"; then
      ok "No checks configured on this PR."
    else
      cat "$ERR" >&2
      die "Checks failed on PR #$PR. Fix them and re-run."
    fi
  fi

  # If the head moved while we were watching, the checks we just saw are stale.
  CURRENT_SHA=$(read_pr headRefOid)
  if [[ "$CURRENT_SHA" != "$WATCHED_SHA" ]]; then
    info "Head branch moved during the watch — re-checking the new commit…"
    continue
  fi

  # Re-read merge state, waiting out GitHub's async mergeability recomputation.
  MERGE_STATE=$(settle_merge_state)

  case "$MERGE_STATE" in
    BEHIND)
      info "Base branch moved ahead — updating the PR branch…"
      if gh pr update-branch "$PR" 2>"$ERR"; then
        ok "Merged base into the PR branch. New checks will run."
        # The update created a new head commit; give GitHub a moment to register
        # the fresh check runs against it before we watch, so --watch doesn't
        # return immediately against the now-stale (green) prior run.
        sleep 15
        continue
      else
        cat "$ERR" >&2
        die "Could not update PR #$PR from its base — likely a merge conflict. Resolve it manually."
      fi
      ;;
    DIRTY)
      die "PR #$PR has merge conflicts with its base. Resolve them manually."
      ;;
    BLOCKED)
      die "PR #$PR is blocked (missing approval or a required check). Resolve it, then re-run."
      ;;
    UNKNOWN)
      die "PR #$PR mergeability is still UNKNOWN after retrying. Check it on GitHub."
      ;;
    CLEAN | HAS_HOOKS | UNSTABLE)
      info "Branch is up to date and green — merging…"
      if gh pr merge "$PR" --squash 2>"$ERR"; then
        ok "PR #$PR merged into its base. 🎉"
        exit 0
      else
        cat "$ERR" >&2
        die "Merge command failed for PR #$PR."
      fi
      ;;
    *)
      die "Unexpected merge state '$MERGE_STATE' for PR #$PR. Check it on GitHub."
      ;;
  esac
done

die "Gave up after $MAX_ROUNDS rounds — the branch kept needing updates. Check PR #$PR."
