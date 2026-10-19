.PHONY: all clean test

all:\
	bin/add-nested\
	bin/pull-nested

clean:
	rm -rf bin/add-nested bin/pull-nested


bin/add-nested: add_nested.d debugio.d
	dmd -wi -gf -unittest -debug add_nested.d debugio.d -of=bin/add-nested

bin/pull-nested: pull_nested.d debugio.d gitCloneDirectoryName.d
	dmd -wi -gf -unittest -debug pull_nested.d debugio.d gitCloneDirectoryName.d -of=bin/pull-nested

test:
