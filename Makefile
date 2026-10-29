.PHONY: all clean setup test

# D compiler. ldmd2 is LDC's wrapper that accepts dmd's flags; override with
# e.g. `make DC=dmd`.
DC ?= ldmd2

all:\
	bin/add-nested\
	bin/pull-nested

setup:
	./setup.sh

clean:
	rm -rf bin/add-nested bin/pull-nested


bin/add-nested: add_nested.d debugio.d
	$(DC) -wi -gf -unittest -debug add_nested.d debugio.d -of=bin/add-nested

bin/pull-nested: pull_nested.d debugio.d gitCloneDirectoryName.d
	$(DC) -wi -gf -unittest -debug pull_nested.d debugio.d gitCloneDirectoryName.d -of=bin/pull-nested

test:
	$(DC) -wi -unittest -main finding.d textFile.d -run gitIgnore.d
