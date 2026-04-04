.PHONY: all clean test

all:\
	pull-nested


pull-nested: pull_nested.d
	dmd -wi -g -unittest -debug pull_nested.d -of=pull-nested

clean:
	rm -f pull-nested pull-nested.o
