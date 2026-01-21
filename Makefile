# Blitz - High-Performance Parallel Runtime for Zig
# Makefile for common development tasks

.PHONY: all build test bench examples clean fmt check help

# Default target
all: test

# ============================================================================
# Building
# ============================================================================

## Build the library (release mode)
build:
	zig build -Doptimize=ReleaseFast

## Build with debug info
build-debug:
	zig build

# ============================================================================
# Testing
# ============================================================================

## Run all unit tests
test:
	zig test mod.zig -lc

## Run tests with verbose output (shows all test names)
test-verbose:
	zig test mod.zig -lc 2>&1 | cat

## Run tests in release mode
test-release:
	zig test mod.zig -lc -OReleaseFast

## Run tests quietly (via build system, only show failures)
test-quiet:
	zig build test

# ============================================================================
# Benchmarks
# ============================================================================

## Run Blitz benchmarks
bench:
	zig build bench

## Run benchmarks with specific test (e.g., make bench-filter FILTER=sort)
bench-filter:
	zig build bench -- $(FILTER)

## Run Rayon comparison (requires Rust)
bench-rayon:
	@echo "Building Rayon benchmark..."
	cd benchmarks/rayon && cargo build --release
	@echo ""
	@echo "=== Rayon Results ==="
	cd benchmarks/rayon && cargo run --release
	@echo ""
	@echo "=== Blitz Results ==="
	zig build bench

## Run quick comparison (fewer iterations)
bench-quick:
	@echo "=== Quick Blitz Benchmark ==="
	zig build bench -- --quick

# ============================================================================
# Examples
# ============================================================================

## Build all examples
examples:
	zig build examples

## Run parallel sum example
example-sum: examples
	zig build parallel-sum && ./zig-out/bin/parallel-sum

## Run parallel sort example
example-sort: examples
	zig build parallel-sort && ./zig-out/bin/parallel-sort

## Run fork-join example
example-fork-join: examples
	zig build fork-join && ./zig-out/bin/fork-join

## Run all examples
run-examples: example-sum example-sort example-fork-join

# ============================================================================
# Code Quality
# ============================================================================

## Format all Zig files
fmt:
	zig fmt *.zig
	zig fmt sort/*.zig
	zig fmt iter/*.zig
	zig fmt internal/*.zig
	zig fmt examples/*.zig
	zig fmt benchmarks/*.zig

## Check formatting without modifying
fmt-check:
	zig fmt --check *.zig
	zig fmt --check sort/*.zig
	zig fmt --check iter/*.zig
	zig fmt --check internal/*.zig
	zig fmt --check examples/*.zig
	zig fmt --check benchmarks/*.zig

## Run all checks (format + test)
check: fmt-check test

# ============================================================================
# Cleaning
# ============================================================================

## Clean build artifacts
clean:
	rm -rf zig-out .zig-cache

## Deep clean (including benchmark artifacts)
clean-all: clean
	rm -rf benchmarks/rayon/target

# ============================================================================
# Documentation
# ============================================================================

## Generate documentation (when zig supports it)
docs:
	@echo "Documentation generation not yet supported by Zig"
	@echo "See README.md and BENCHMARKS.md for documentation"

# ============================================================================
# Installation
# ============================================================================

## Show installation instructions
install-info:
	@echo "Blitz is a Zig package. Add to your build.zig.zon:"
	@echo ""
	@echo '.dependencies = .{'
	@echo '    .blitz = .{'
	@echo '        .url = "https://github.com/<user>/blitz/archive/<tag>.tar.gz",'
	@echo '        .hash = "<hash>",'
	@echo '    },'
	@echo '},'
	@echo ""
	@echo "Then in build.zig:"
	@echo ""
	@echo 'const blitz = b.dependency("blitz", .{});'
	@echo 'exe.root_module.addImport("blitz", blitz.module("blitz"));'

# ============================================================================
# Development Helpers
# ============================================================================

## Watch for changes and run tests (requires watchexec)
watch:
	watchexec -e zig "make test"

## Watch and run benchmarks
watch-bench:
	watchexec -e zig "make bench"

## Show lines of code
loc:
	@echo "Lines of code (excluding tests and benchmarks):"
	@wc -l *.zig sort/*.zig iter/*.zig internal/*.zig 2>/dev/null | tail -1
	@echo ""
	@echo "Total including tests and benchmarks:"
	@find . -name "*.zig" | xargs wc -l | tail -1

## Show TODO/FIXME comments
todo:
	@grep -rn "TODO\|FIXME\|XXX\|HACK" --include="*.zig" . || echo "No TODOs found"

## Show test coverage analysis (test count per module)
test-coverage:
	@total_lines=0; \
	tested_lines=0; \
	total_modules=0; \
	tested_modules=0; \
	untested=""; \
	for f in $$(find . -name "*.zig" -not -path "./.zig-cache/*" -not -path "./benchmarks/*" -not -path "./examples/*" | sort); do \
		tests=$$(grep -c "^test " "$$f" 2>/dev/null); \
		tests=$${tests:-0}; \
		lines=$$(wc -l < "$$f" | tr -d ' '); \
		total_lines=$$((total_lines + lines)); \
		total_modules=$$((total_modules + 1)); \
		if [ "$$tests" -gt 0 ]; then \
			tested_lines=$$((tested_lines + lines)); \
			tested_modules=$$((tested_modules + 1)); \
		elif [ "$$lines" -gt 50 ]; then \
			untested="$$untested$$f:$$lines "; \
		fi; \
	done; \
	pct=$$((tested_lines * 100 / total_lines)); \
	mod_pct=$$((tested_modules * 100 / total_modules)); \
	total_tests=$$(grep -rh "^test " --include="*.zig" . 2>/dev/null | grep -v ".zig-cache" | wc -l | tr -d ' '); \
	echo "=== Test Coverage Analysis ==="; \
	echo ""; \
	echo "Summary:"; \
	echo "  Total tests:       $$total_tests"; \
	echo "  Module coverage:   $$tested_modules/$$total_modules modules ($$mod_pct%)"; \
	echo "  Code coverage:     $$tested_lines/$$total_lines lines ($$pct%)"; \
	echo ""; \
	echo "Modules with tests:"; \
	for f in $$(find . -name "*.zig" -not -path "./.zig-cache/*" -not -path "./benchmarks/*" -not -path "./examples/*" | sort); do \
		tests=$$(grep -c "^test " "$$f" 2>/dev/null); \
		tests=$${tests:-0}; \
		lines=$$(wc -l < "$$f" | tr -d ' '); \
		if [ "$$tests" -gt 0 ]; then \
			printf "  %-40s %3d tests, %5d lines\n" "$$f" "$$tests" "$$lines"; \
		fi; \
	done; \
	echo ""; \
	echo "Modules without tests (>50 lines):"; \
	for item in $$untested; do \
		f=$${item%%:*}; \
		l=$${item##*:}; \
		printf "  %-40s %5d lines\n" "$$f" "$$l"; \
	done; \
	echo ""; \
	echo "Note: This shows modules with test blocks. Many modules are tested"; \
	echo "      via centralized tests.zig files (e.g., iter/tests.zig)."; \
	echo ""; \
	echo "True line coverage runs automatically in CI (GitHub Actions + kcov)"

# ============================================================================
# CI Helpers
# ============================================================================

## Run CI checks (what CI should run)
ci: fmt-check test-release bench
	@echo "CI checks passed!"

## Quick CI (faster, for PRs)
ci-quick: fmt-check test
	@echo "Quick CI checks passed!"

# ============================================================================
# Help
# ============================================================================

## Show this help message
help:
	@echo "Blitz - High-Performance Parallel Runtime for Zig"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Building:"
	@echo "  build              Build library (release mode)"
	@echo "  build-debug        Build with debug info"
	@echo ""
	@echo "Testing:"
	@echo "  test               Run all unit tests"
	@echo "  test-verbose       Show all test names as they run"
	@echo "  test-release       Run tests in release mode"
	@echo "  test-quiet         Only show failures (via build system)"
	@echo ""
	@echo "Benchmarks:"
	@echo "  bench              Run Blitz benchmarks"
	@echo "  bench-rayon        Compare Blitz vs Rayon (requires Rust)"
	@echo "  bench-quick        Quick benchmark run"
	@echo ""
	@echo "Examples:"
	@echo "  examples           Build all examples"
	@echo "  example-sum        Run parallel sum example"
	@echo "  example-sort       Run parallel sort example"
	@echo "  example-fork-join  Run fork-join example"
	@echo "  run-examples       Run all examples"
	@echo ""
	@echo "Code Quality:"
	@echo "  fmt                Format all Zig files"
	@echo "  fmt-check          Check formatting"
	@echo "  check              Format check + tests"
	@echo ""
	@echo "Maintenance:"
	@echo "  clean              Clean build artifacts"
	@echo "  clean-all          Deep clean (including Rayon)"
	@echo "  loc                Show lines of code"
	@echo "  todo               Show TODO/FIXME comments"
	@echo "  test-coverage      Module-level coverage analysis"
	@echo ""
	@echo "CI:"
	@echo "  ci                 Full CI pipeline"
	@echo "  ci-quick           Quick CI checks"
