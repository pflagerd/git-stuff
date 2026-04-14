.PHONY: all clean test

all:\
	bin/add-nested\
	bin/pull-nested

clean:
	rm -rf bin/add-nested bin/pull-nested


bin/add-nested: add_nested.d
	dmd -wi -g -unittest -debug add_nested.d -of=bin/add-nested

bin/pull-nested: pull_nested.d
	dmd -wi -g -unittest -debug pull_nested.d -of=bin/pull-nested
