.PHONY: build install

build:
	zig build -Doptimize=ReleaseFast

install: build
	ln -s ./zig-out/bin/hexe ~/.local/bin/hexe
