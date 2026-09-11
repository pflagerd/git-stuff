#!/usr/bin/env python3
import os
import subprocess
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

gitignore_dirs = []
with open('../.gitignore', 'r') as f:
    for line in f:
        line = line.rstrip('\n')
        gitignore_dirs.append(line.split()[0].replace("/", ""))

print(f"gitignore_dirs == {gitignore_dirs}")

p = Path("../")
dirs = [str(d).replace("../", "") for d in p.iterdir() if d.is_dir()]

print(f"dirs == {dirs}")

for dir in gitignore_dirs:
    # print(f"dir == {dir}")
    if dir not in dirs:
        print(dir)
