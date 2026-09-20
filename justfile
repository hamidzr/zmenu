# zmenu justfile

build:
	zig build

run:
	zig build run

dev:
	printf "alpha\nbeta\ngamma\ndelta\nepsilon\n" | zig build run

test:
	zig build test

# run all formatters
fmt:
	zig fmt src/

# alias for fmt
format: fmt
fix: fmt

# run all static analysis without changing filesystem
check:
	zig fmt --check src/
	zig build test

# alias for check
lint: check

clean:
	rm -rf zig-out .zig-cache bin

visual:
	scripts/visual_test.sh

# measure cold spawn-to-accept cost (requires hyperfine)
bench:
	scripts/bench_spawn.sh

# measure table reload + paint cost (COUNT=2000)
render-bench:
	scripts/render_bench.sh

install: build
	mkdir -p ~/.local/bin
	rm -f ~/.local/bin/zmenu ~/.local/bin/zmenuctl
	cp zig-out/bin/zmenu zig-out/bin/zmenuctl ~/.local/bin/
	chmod +x ~/.local/bin/zmenu ~/.local/bin/zmenuctl

