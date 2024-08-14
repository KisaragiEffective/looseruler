#!/bin/bash
# set -x
die() {
  echo "$1" >&2
  exit 1
}

if [ -z "$GIT_DIRECTORY" ]; then
  die "Please set \$GIT_DIRECTORY to begin"
fi

if [ -z "$THEIRS" ]; then
  die "Please set \$THEIRS to begin"
fi

if [ -z "$YOURS" ]; then
  die "Please set \$YOURS to begin"
fi

if [ ! -d "$GIT_DIRECTORY" ]; then
  die "$GIT_DIRECTORY is not a directory"
fi

if [ ! -d "$NEGLIDIA_SRC_DIR" ]; then
  echo "WARN: \$BEGLIDIA_SRC_DIR is not set"
fi

{
  # shellcheck disable=SC2164
  cd "$GIT_DIRECTORY"
  if [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" != "true" ]]; then
    die "$GIT_DIRECTORY is not a git directory"
  fi
}

# we've ensured that "$GIT_DIRECTORY" points a git repository!
# here we go.

{
  cd "$GIT_DIRECTORY" || false
  matched_lines="$(git branch --list "$THEIRS" | wc -l)"

  if [ "$matched_lines" -ne 1 ]; then
    die "$THEIRS does not exist or is not literal patten"
  fi

  matched_lines="$(git branch --list "$YOURS" | wc -l)"

  if [ "$matched_lines" -ne 1 ]; then
    die "$THEIRS does not exist or is not literal patten"
  fi
}

{
  cd "$GIT_DIRECTORY" || false
  git switch "$YOURS"
  echo "=================================== TRYING auto-merge ==================================="
  if git merge --no-commit --no-ff "$THEIRS" ; then
    echo "git satisfied :)"
    echo "*** Please audit change, because there may be change(s) that you do not want to merge ***"
    git merge --no-ff "$THEIRS"
    echo "===================================  DONE auto-merge  ==================================="
    exit 0
  else
    git merge --abort
    echo "===================================  FAIL auto-merge  ==================================="
  fi
}

common_ancestor="$(git merge-base "$THEIRS" "$YOURS")"
echo "Most recent common ancestor found: ${common_ancestor}"
git switch "$YOURS"

to_merge="to-merge-$(date --utc +%Y%m%dT%H%M%S.%N)"
git branch "$to_merge" "$YOURS"
previous_commit="$common_ancestor"
for their_commit_hash in $(git log "${common_ancestor}...${THEIRS}" --pretty=format:"%H" --reverse); do
  range="${previous_commit}...${their_commit_hash}"
  # git switch "$YOURS"
  specially_handled_path_list_file="$(mktemp)"
  echo "merging $range"
  echo "- iterating"
  modified_files="$(GIT_TRACE=1 git diff "$range" --name-only)"
  for modified_file in $modified_files; do
    echo "-- checking ${modified_file}"
    if [[ "$modified_file" == "packages/frontend/src/pages/about-misskey.vue" ]] ; then
      diff_old="$(mktemp)"
      diff_new="$(mktemp)"
      judge="$(mktemp)"
      echo "---- getting old file"
      git show "$previous_commit:$modified_file" > "$diff_old"
      echo "---- getting new file"
      git show "$their_commit_hash:$modified_file" > "$diff_new"
      {
        # !!!
        if cd "$NEGLIDIA_SRC_DIR"; then
          npm run launch -- --old "$diff_old" --new "$diff_new" --out "$judge"
        else
          die "neglidia not found"
        fi

        revert="$(jq '[to_entries | .[] | .value | .diffAction] | any(. == "drop")' < "$judge")"

        if [[ "$revert" == "true" ]]; then
          # back to our home
          cd "$GIT_DIRECTORY"
          echo "---- generating revert patch"
          patch_temp="$(mktemp)"
          GIT_TRACE=1 git diff "$previous_commit:$modified_file" "$their_commit_hash:$modified_file" -R > "$patch_temp"
          git checkout "$to_merge"
          if [ -n "$latest_auto_mergeable" ]; then
            echo "auto-merge of $latest_auto_mergeable"
            git merge --no-ff --no-squash "$latest_auto_mergeable" -m "automerge latest goods"
            latest_auto_mergeable=""
          fi
          git branch "temp_revert" "$their_commit_hash"
          git switch "temp_revert"
          echo "------------------------- PATCH -------------------------"
          cat "$patch_temp"
          echo "---------------------------------------------------------"
          GIT_TRACE=1 git apply "$patch_temp" || die "failed to apply patch"
          git commit -m "revert $their_commit_hash partially" -m "neglidia decides to revert based on its policy" -o "$modified_file"
          git checkout "$to_merge"
          git merge "temp_revert" -m "merge RVP-$their_commit_hash"
          git branch -d "temp_revert"
          printf '%s\n' "$modified_file" > "$specially_handled_path_list_file"
        fi
      }
    fi

    if [[ "$modified_file" == "packages/backend/src/server/api/stream/channels/reversi-game.ts" ]]; then
      # back to our home
      cd "$GIT_DIRECTORY"
      echo "---- generating revert patch"
      patch_temp="$(mktemp)"
      GIT_TRACE=1 git diff "$previous_commit:$modified_file" "$their_commit_hash:$modified_file" -R > "$patch_temp"
      git checkout "$to_merge"
      if [ -n "$latest_auto_mergeable" ]; then
        echo "auto-merge of $latest_auto_mergeable"
        git merge --no-ff --no-squash "$latest_auto_mergeable" -m "automerge latest goods"
        latest_auto_mergeable=""
      fi
      git branch "temp_revert" "$their_commit_hash"
      git switch "temp_revert"
      echo "------------------------- PATCH -------------------------"
      cat "$patch_temp"
      echo "---------------------------------------------------------"
      GIT_TRACE=1 git apply "$patch_temp" || die "failed to apply patch"
      git commit -m "revert $their_commit_hash partially" -m "Misskey Games related updates" -o "$modified_file"
      git checkout "$to_merge"
      git merge --no-ff --no-squash "temp_revert" -m "merge RVP-$their_commit_hash"
      git branch -d "temp_revert"
    fi
  done

  git checkout "$to_merge"
  another_temp="$(mktemp)"
  comm -23 <(git diff "$range" --name-only | sort) <(sort "$specially_handled_path_list_file") > "$another_temp"
  to_be_picked_file_number="$(wc -l < "$another_temp")"
  if [ "$to_be_picked_file_number" -ge "1" ]; then
    reverted_number="$(cat "$specially_handled_path_list_file" | wc -l)"
    echo "rn: $reverted_number, tbp: $to_be_picked_file_number"
    if [ "0" -eq "$reverted_number" ]; then
      latest_auto_mergeable="$their_commit_hash"
      echo "auto-mergeable: deferred"
    else
      echo "-------------------------------------------------------------------"
      cat "$another_temp"
      echo "-------------------------------------------------------------------"
      set -eo pipefail
      cat "$another_temp" | GIT_TRACE=1 xargs --replace git diff "$previous_commit:{}" "$their_commit_hash:{}" | \
        (GIT_TRACE=1 git apply - || die "patch does not apply!")
      set +eo pipefail
      GIT_TRACE=1 git commit -m "merge rest of $their_commit_hash" --pathspec-from-file="$another_temp" --only
    fi
  fi

  previous_commit="$their_commit_hash"
done

if [ -n "$latest_auto_mergeable" ]; then
  git merge --no-ff --no-squash "$latest_auto_mergeable" -m "automerge latest goods"
  latest_auto_mergeable=""
fi
