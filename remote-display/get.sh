#!/usr/bin/env bash
# Install Frametop with Remote PC (the dkiiv/frametop fork) on the Steam Frame. In a terminal on
# the headset (Launch a program -> Desktop -> Konsole):
#
#   curl -fsSL https://raw.githubusercontent.com/dkiiv/frametop/remote-display-poc-handoff/remote-display/get.sh | bash
#
# Clones the branch into ~/frametop (or switches an existing ~/frametop checkout to it) and runs
# its install.sh, which installs Frametop and builds Remote PC. Re-running it updates.
set -euo pipefail
repo=https://github.com/dkiiv/frametop.git
branch=remote-display-poc-handoff
dir=$HOME/frametop

if [ -d "$dir/.git" ]; then
  echo "== updating $dir to $branch"
  git -C "$dir" remote get-url dkiiv >/dev/null 2>&1 || git -C "$dir" remote add dkiiv "$repo"
  git -C "$dir" fetch -q dkiiv "$branch"
  if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no)" ]; then
    echo "$dir has local changes; commit or stash them, then run this again." >&2
    exit 1
  fi
  git -C "$dir" checkout -q -B remote-display "dkiiv/$branch"
elif [ -e "$dir" ]; then
  echo "$dir exists but isn't a git checkout; move it away, then run this again." >&2
  exit 1
else
  echo "== downloading Frametop with Remote PC into $dir"
  git clone -q -b "$branch" "$repo" "$dir"
fi
cd "$dir"
# The installer asks a few questions: read them from the terminal, not from this pipe.
exec ./install.sh </dev/tty
