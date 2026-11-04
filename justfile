# zmenu justfile

# list recipes
default:
	@just --list

# fetch zig package dependencies
deps:
	zig build --fetch
alias get-deps := deps

# build zmenu and zmenuctl
build:
	zig build

# build and launch the gui
run:
	zig build run

# launch with sample stdin items
dev:
	printf "alpha\nbeta\ngamma\ndelta\nepsilon\n" | zig build run

# run zig tests
test:
	zig build test

# run all formatters
fmt:
	zig fmt src/

alias format := fmt
alias fix := fmt

# run all static analysis without changing filesystem
check:
	zig fmt --check src/
	zig build test

alias lint := check

# remove build artifacts
clean:
	rm -rf zig-out .zig-cache bin

# capture and compare a ui snapshot
visual:
	scripts/visual_test.sh

# measure cold spawn-to-accept cost (requires hyperfine)
bench:
	scripts/bench_spawn.sh

# measure table reload + paint cost (COUNT=2000)
render-bench:
	scripts/render_bench.sh

# measure external launch timing and real early keyboard delivery
startup-bench:
	scripts/startup_bench.sh

# build and copy binaries to ~/.local/bin
install: build
	mkdir -p ~/.local/bin
	rm -f ~/.local/bin/zmenu ~/.local/bin/zmenuctl
	cp zig-out/bin/zmenu zig-out/bin/zmenuctl ~/.local/bin/
	chmod +x ~/.local/bin/zmenu ~/.local/bin/zmenuctl

