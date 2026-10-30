.PHONY: all clean setup test

# D compiler. ldmd2 is LDC's wrapper that accepts dmd's flags; override with
# e.g. `make DC=dmd`.
DC ?= ldmd2

# Where the compiler lives: found on PATH, or, when it isn't installed yet,
# where apt's ldc package puts it. The targets that compile list it as an
# order-only prerequisite (after |), so a missing compiler makes the rule
# below run setup.sh, while a newer compiler doesn't force a rebuild.
DC_PATH := $(or $(shell command -v $(DC) 2>/dev/null),/usr/bin/$(DC))

# The new nested-repo commands, checked by `make test` once built.
COMMANDS = bin/add-nested bin/check-nested bin/pull-nested bin/push-nested bin/remove-nested

all: $(COMMANDS)

setup:
	./setup.sh

# setup.sh installs ldc (ldmd2). If DC names some other compiler, such as
# dmd, it is still missing afterwards, so stop with a clear message.
$(DC_PATH):
	./setup.sh
	@command -v $(DC) >/dev/null || { echo "Makefile: $(DC) is still not installed. setup.sh installs ldc (ldmd2); install $(DC) yourself, or build with the default DC." >&2; exit 1; }

clean:
	rm -rf $(COMMANDS)


# Linked into every executable: in -debug builds it makes stdout unbuffered,
# so output appears line by line when stepping through a program in Kate's
# debugger. It has no effect on other builds.
DEBUG_SUPPORT = debugio.d

# Sources every command is built from, besides its own file.
LIBRARY = nestedCommand.d parentDirectory.d gitIgnore.d gitRepos.d finding.d textFile.d gitCloneDirectoryName.d

bin/add-nested: addNested.d $(LIBRARY) $(DEBUG_SUPPORT) | $(DC_PATH)
	$(DC) -wi -gf -debug addNested.d $(LIBRARY) $(DEBUG_SUPPORT) -of=bin/add-nested

bin/check-nested: checkNested.d $(LIBRARY) $(DEBUG_SUPPORT) | $(DC_PATH)
	$(DC) -wi -gf -debug checkNested.d $(LIBRARY) $(DEBUG_SUPPORT) -of=bin/check-nested

bin/pull-nested: pullNested.d $(LIBRARY) $(DEBUG_SUPPORT) | $(DC_PATH)
	$(DC) -wi -gf -debug pullNested.d $(LIBRARY) $(DEBUG_SUPPORT) -of=bin/pull-nested

bin/push-nested: pushNested.d $(LIBRARY) $(DEBUG_SUPPORT) | $(DC_PATH)
	$(DC) -wi -gf -debug pushNested.d $(LIBRARY) $(DEBUG_SUPPORT) -of=bin/push-nested

bin/remove-nested: removeNested.d $(LIBRARY) $(DEBUG_SUPPORT) | $(DC_PATH)
	$(DC) -wi -gf -debug removeNested.d $(LIBRARY) $(DEBUG_SUPPORT) -of=bin/remove-nested

# The unit tests, then a quick check of each built command: --help exits 0
# and an unknown option exits 2 (main() and the argument plumbing, which the
# in-process tests don't exercise).
test: $(COMMANDS) | $(DC_PATH)
	$(DC) -wi -unittest -main $(LIBRARY) addNested.d pullNested.d pushNested.d removeNested.d -run checkNested.d
	@for c in $(COMMANDS); do \
	    $$c --help >/dev/null || { echo "$$c --help: expected exit 0" >&2; exit 1; }; \
	    $$c --no-such-option 2>/dev/null; s=$$?; \
	    [ $$s -eq 2 ] || { echo "$$c --no-such-option: expected exit 2, got $$s" >&2; exit 1; }; \
	    echo "$$c: --help exits 0, an unknown option exits 2"; \
	done
