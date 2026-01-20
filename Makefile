.PHONY: build install

build:
	zig build -Doptimize=ReleaseFast

install: build
	cp ./zig-out/bin/hexa ~/.local/bin/
