import os
import subprocess

with open('../.gitrepos', 'r') as f:
    for line in f:
        line = line.rstrip('\n')
        # print(f"line = line.rstrip('\\n') => {line}")
        # print(f"line.split() => {line.split()}")
        # print(f"/usr/bin/git -C ../{line.split()[0]} ls-remote".split())
        result = subprocess.run(
            f"/usr/bin/git -C ../{line.split()[0]} ls-remote".split(),
            capture_output=True,
            text=True  # decode output as string instead of bytes
        )
        # print('result.stdout =>',result.stdout)
        # print('result.stderr =>', result.stderr)
        # print('result.returncode =>', result.returncode)
        if result.returncode != 0:
            print(line.split()[0].replace("/", ""))

