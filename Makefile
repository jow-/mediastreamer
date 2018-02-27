RES_SRC := $(sort $(wildcard resources/*))
RES_BIN := $(patsubst resources/%,build/%,$(RES_SRC))

MIMETYPE.css := text/css
MIMETYPE.js  := text/javascript

ARGS ?= 8080 /media

define get_mimetype
$(if $(MIMETYPE$(suffix $(1))),$(MIMETYPE$(suffix $(1))),$(shell file --brief --mime-type $(1)))
endef

build/%: resources/%
	mkdir -p $(dir $@)
	( \
		echo "name=$(notdir $^)"; \
		echo "type=$(call get_mimetype,$^)"; \
		echo ""; \
		hexdump -v -e '36/1 "%02X" "\n"' $^; \
		echo ""; \
		echo ""; \
	) > $@

streamer.pl: streamer.skel $(RES_BIN)
	cat $^ > $@
	chmod 0755 $@

clean:
	rm -f streamer.pl
	rm -rf build

run: streamer.pl
	./streamer.pl $(ARGS)

build: streamer.pl
