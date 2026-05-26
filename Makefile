.DEFAULT_GOAL := help

ZIG ?= zig
OPTIMIZE ?= ReleaseSafe
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
INSTALL ?= install
BIN ?= zig-out/bin/cr

.PHONY: help build test run tui fmt check release install uninstall

help:
	@printf '%s\n' \
		'Targets:' \
		'  make build      Build debug binary via zig build' \
		'  make test       Run zig build test' \
		'  make run        Run default zig build run target' \
		'  make tui        Run the TUI via zig build run -- tui' \
		'  make fmt        Check formatting via zig build fmt' \
		'  make check      Run fmt and test' \
		'  make release    Build optimized binary (OPTIMIZE=$(OPTIMIZE))' \
		'  make install    Install binary to $(BINDIR)/cr' \
		'  make uninstall  Remove $(BINDIR)/cr' \
		'' \
		'Variables:' \
		'  ZIG=<path>              Override zig executable' \
		'  OPTIMIZE=ReleaseFast    Change optimized build mode' \
		'  PREFIX=/usr/local       Install into a different prefix'

build:
	$(ZIG) build

test:
	$(ZIG) build test

run:
	$(ZIG) build run

tui:
	$(ZIG) build run -- tui

fmt:
	$(ZIG) build fmt

check: fmt test

release:
	$(ZIG) build -Doptimize=$(OPTIMIZE)

install: release
	mkdir -p $(BINDIR)
	$(INSTALL) -m 0755 $(BIN) $(BINDIR)/cr

uninstall:
	rm -f $(BINDIR)/cr
