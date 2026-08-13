#!/usr/bin/env python3
import argparse
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

verbose = False


def is_it(paths) -> list:
    """The subset of paths where a remote named after the origin's host did not already exist and was added."""
    added = []
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

        if not host:
            continue

        remotes = subprocess.run(
            ["git", "-C", str(path), "remote"],
            capture_output=True,
            text=True,
        )
        if remotes.returncode != 0 or host in remotes.stdout.split():
            continue

        remote_add = subprocess.run(
            ["git", "-C", str(path), "remote", "add", host, url],
            capture_output=True,
            text=True,
        )
        if remote_add.returncode != 0:
            if verbose:
                print(f"{path}: failed to add remote '{host}': {remote_add.stderr.strip()}")
            continue

        if verbose:
            print(f"{path}: added remote '{host}' -> {url}")

        added.append(path)

    return added


def main(argv):
    global verbose
    parser = argparse.ArgumentParser()
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args(argv[1:])
    verbose = args.verbose
    paths = args.paths or ["."]

    added = is_it(paths)
    for path in added:
        print(Path(path).name)

    return 0 if added else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
