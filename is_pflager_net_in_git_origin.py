#!/usr/bin/env python3
import argparse
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

verbose = False


def is_it(paths) -> list:
    """The subset of paths that are git working directories whose 'origin' remote host ends with '.pflager.net'."""
    matches = []
    for path in paths:
        is_work_tree = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "--is-inside-work-tree"],
            capture_output=True,
            text=True,
        )
        if is_work_tree.returncode != 0 or is_work_tree.stdout.strip() != "true":
            continue

        origin = subprocess.run(
            ["git", "-C", str(path), "remote", "get-url", "origin"],
            capture_output=True,
            text=True,
        )
        if origin.returncode != 0:
            continue
        url = origin.stdout.strip()

        if "://" in url:
            host = urlparse(url).hostname
        else:
            # scp-like syntax, e.g. "git@zax.pflager.net:repo.git" or "zax:repo.git"
            host = url.split("@")[-1].split(":")[0]

        if verbose:
            print(f"{path}: origin host == {host}")

        if host and host.endswith(".pflager.net"):
            matches.append(path)

    return matches


def main(argv):
    global verbose
    parser = argparse.ArgumentParser()
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args(argv[1:])
    verbose = args.verbose
    paths = args.paths or ["."]

    matches = is_it(paths)
    for path in matches:
        print(Path(path).name)

    return 0 if matches else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
