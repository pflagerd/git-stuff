.PHONY: all clean test

all:\
	pull-desktop-repos


pull-desktop-repos: pull_desktop_repos.d
	dmd -wi -g -unittest -debug pull_desktop_repos.d -of=pull-desktop-repos

