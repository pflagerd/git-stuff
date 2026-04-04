.PHONY: all clean test

all:\
	bin/add-repo-to-desktop\
	bin/pull-desktop-repos


bin/add-repo-to-desktop: add-repo-to-desktop/add-repo-to-desktop
	cp add-repo-to-desktop/add-repo-to-desktop bin/

bin/pull-desktop-repos: pull-desktop-repos/pull-desktop-repos
	cp pull-desktop-repos/pull-desktop-repos bin/


add-repo-to-desktop/add-repo-to-desktop:
	$(MAKE) -C add-repo-to-desktop

pull-desktop-repos/pull-desktop-repos:
	$(MAKE) -C pull-desktop-repos
