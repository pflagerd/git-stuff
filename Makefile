.PHONY: all clean setup test

# D compiler. ldmd2 is LDC's wrapper that accepts dmd's flags; override with
# e.g. `make DC=dmd`.
DC ?= ldmd2

# Where the compiler lives: found on PATH, or, when it isn't installed yet,
# where apt's ldc package puts it. The targets that compile list it as an
# order-only prerequisite (after |), so a missing compiler makes the rule
# below run setup.sh, while a newer compiler doesn't force a rebuild.
DC_PATH := $(or $(shell command -v $(DC) 2>/dev/null),/usr/bin/$(DC))

all:\
	bin/add-nested\
	bin/pull-nested

setup:
	./setup.sh

# setup.sh installs ldc (ldmd2). If DC names some other compiler, such as
# dmd, it is still missing afterwards, so stop with a clear message.
$(DC_PATH):
	./setup.sh
	@command -v $(DC) >/dev/null || { echo "Makefile: $(DC) is still not installed. setup.sh installs ldc (ldmd2); install $(DC) yourself, or build with the default DC." >&2; exit 1; }

clean:
	rm -rf bin/add-nested bin/pull-nested


bin/add-nested: add_nested.d debugio.d | $(DC_PATH)
	$(DC) -wi -gf -debug add_nested.d debugio.d -of=bin/add-nested

bin/pull-nested: pull_nested.d debugio.d gitCloneDirectoryName.d | $(DC_PATH)
	$(DC) -wi -gf -debug pull_nested.d debugio.d gitCloneDirectoryName.d -of=bin/pull-nested

test: | $(DC_PATH)
	$(DC) -wi -unittest -main finding.d textFile.d gitRepos.d parentDirectory.d gitCloneDirectoryName.d nestedCommand.d -run gitIgnore.d
