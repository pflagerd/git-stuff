.PHONY: all clean test

all:\
	add-nested


add-nested: add_nested.d
	dmd -wi -g -unittest -debug add_nested.d -of=add-nested

clean:
	rm -f add-nested add-nested.o
