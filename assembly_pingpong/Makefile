AS      := clang
ASFLAGS := -arch arm64 -c -Isrc
LDFLAGS := -arch arm64

SRCS    := $(wildcard src/*.s)
OBJS    := $(patsubst src/%.s,build/%.o,$(SRCS))
BIN     := pong

.PHONY: all run clean

all: $(BIN)

$(BIN): $(OBJS)
	$(AS) $(LDFLAGS) -o $@ $^

build/%.o: src/%.s src/defs.inc | build
	$(AS) $(ASFLAGS) -o $@ $<

build:
	mkdir -p $@

run: $(BIN)
	./$(BIN)

clean:
	rm -rf build $(BIN)
