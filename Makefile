.PHONY: all clean test

all:\
	bin/add-nested\
	bin/pull-nested


bin/add-nested: add-nested/add-nested
	cp add-nested/add-nested bin/

bin/pull-nested: pull-nested/pull-nested
	cp pull-nested/pull-nested bin/


add-nested/add-nested:
	$(MAKE) -C add-nested

pull-nested/pull-nested:
	$(MAKE) -C pull-nested
