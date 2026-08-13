#!/usr/bin/env python3
import argparse
import os
import subprocess
import sys
from pathlib import Path
import shutil

def confirm(prompt: str, default: bool = False) -> bool:
    """Prompt for a yes/no answer. `default` is returned if user just hits Enter."""
    suffix = " [Y/n] " if default else " [y/N] "
    while True:
        reply = input(prompt + suffix).strip().lower()
        if reply == "":
            return default
        if reply in ("y", "yes"):
            return True
        if reply in ("n", "no"):
            return False
        print("Please answer 'y' or 'n'.")

def git_ignored(dir_path) -> bool:
    """True if dir_path is a git working directory and is not ignored by .gitignore in the current directory."""
    is_work_tree = subprocess.run(
        ["git", "-C", str(dir_path), "rev-parse", "--is-inside-work-tree"],
        capture_output=True,
        text=True,
    )
    if is_work_tree.returncode != 0 or is_work_tree.stdout.strip() != "true":
        return False

    check_ignore = subprocess.run(
        ["git", "check-ignore", "-q", str(dir_path)],
        capture_output=True,
    )
    # check-ignore exits 0 if the path IS ignored, 1 if it is not.
    return check_ignore.returncode != 0


parser = argparse.ArgumentParser()
parser.add_argument('-v', '--verbose', action='store_true')
args = parser.parse_args()
verbose = args.verbose

gitrepos_dirs = []
with open('../.gitrepos', 'r') as f:
    for line in f:
        line = line.rstrip('\n')
        gitrepos_dirs.append(line[0])

p = Path("../")
dirs = [d for d in p.iterdir() if d.is_dir() and d.name != ".git"]

deleted_something = False
for d in dirs:
    if verbose:
        print(f"dir == {d}")
    if d not in gitrepos_dirs and not git_ignored(d):
        if confirm(f"Do you really want to delete directory {d} recursively?"):
            print("Deleting...")
            shutil.rmtree(d, ignore_errors=True)
            print(f"Deleted {d}")
            deleted_something = True

sys.exit(0 if deleted_something else 1)
