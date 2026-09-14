from __future__ import annotations

from pathlib import Path
from shutil import rmtree
import subprocess

# add-nested directoryName | URI
#
# a. add-nested directoryName
# b. add-nested URI
#
# i. directoryName/ exists
# ii. directoryName/ not exists
#
# A. directoryName/ is directory
# B. directoryName is not directory
#
# 1. directoryName/.git/ exists
# 2. directoryName/.git/ not exists
#
# x. remote origin exists
# y. remote origin not exists
#
# I default branch is master
# II default branch is not master
#
# X default branch is same as rightmost part of directoryName/
# Y default branch is same as rightmost part of URI (of which rightmost part is directory name)
# Z default branch is not same as either rightmost part of directoryName/ or rightmost part of URI (of which rightmost part is directory name)
#
# f. .gitrepos exists
# g. .gitrepos not exists
#
# k. .gitignore exists
# l. .gitignore not exists
#
# p. .gitignore contains rightmost part of directoryName
# q. .gitignore contains rightmost part of URI (of which rightmost part is directory name)
# r. .gitignore not contains rightmost part of directoryName
# s. .gitignore not contains rightmost part of URI (of which rightmost part is directory name)
#
# u. .gitrepos contains rightmost part of directoryName
# v. .gitrepos contains rightmost part of URI (of which rightmost part is directory name)
# w. .gitrepos not contains rightmost part of directoryName
# x. .gitrepos not contains rightmost part of URI (of which rightmost part is directory name)
#
# F. .gitrepos sorted
# G. .gitrepos not sorted
#
# K. .gitignore sorted
# L. .gitignore not sorted
#
# P. .gitrepos contains repo URI
# Q. .gitrepos not contains repo URI
#

def cleanup():
    a = Path("a")
    if a.is_dir():
        rmtree(str(a))


def test_aiA1xIZ():
    a = Path("a")
    if a.is_dir():
        print("\"a/\" already exists. removing it.")
        rmtree(str(a))

    result = subprocess.run(
        ["git", "clone", "git@github.com:pflagerd/a.git"],
        capture_output=True,
        text=True
    )

    if result.returncode != 0:
        print(f"Unable to clone git@github.com:pflagerd/a.git to a/: %d (%s)", result.returncode, result.stderr)

    print("return code:", result.returncode)


if __name__ == "__main__":
    test_aiA1xIZ()
