.PHONY: all clean test

all:\
	add-repo-to-desktop


add-repo-to-desktop: add_repo_to_desktop.d
	dmd -wi -g -unittest -debug add_repo_to_desktop.d -of=add-repo-to-desktop

