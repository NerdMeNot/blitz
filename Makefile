# Blitz Makefile
# High-performance work-stealing parallel runtime for Zig

.PHONY: all build test bench clean fmt help
.PHONY: docs docs-dev docs-build docs-preview docs-install docs-clean docs-autodoc docs-build-all docs-release

# Default target
all: build

#
# Zig targets
#

build:
	zig build

test:
	zig build test

bench:
	zig build bench

clean:
	rm -rf .zig-cache zig-out

fmt:
	zig fmt .

#
# Documentation targets
#

# Install docs dependencies (run once)
docs-install:
	cd docs && bun install

# Start development server with hot reload
docs-dev:
	cd docs && bun run dev

# Build static documentation site
docs-build:
	cd docs && bun run build

# Preview built documentation
docs-preview:
	cd docs && bun run preview

# Clean docs build artifacts
docs-clean:
	rm -rf docs/dist docs/node_modules/.cache docs/.astro

# Generate Zig autodocs
docs-autodoc:
	zig build docs

# Full docs build: autodocs + Starlight site
docs-build-all: docs-autodoc docs-build
	cp -r zig-out/docs/api-reference docs/dist/api-reference

# Alias for docs-dev
docs: docs-dev

# Build docs from a git tag.
# Usage: make docs-release TAG=v1.0.0-zig0.15.2
# Checks out the tag, builds the site + autodocs, returns to current branch.
# Built output lands in docs/dist/.
docs-release:
ifndef TAG
	$(error TAG is required. Usage: make docs-release TAG=v1.0.0-zig0.15.2)
endif
	./docs/scripts/release.sh $(TAG)

#
# Combined targets
#

# Clean everything
clean-all: clean docs-clean

# Full rebuild
rebuild: clean build

#
# Help
#

help:
	@echo "Blitz Makefile targets:"
	@echo ""
	@echo "  Zig targets:"
	@echo "    make build      - Build the library"
	@echo "    make test       - Run all tests"
	@echo "    make bench      - Run benchmarks"
	@echo "    make clean      - Clean Zig build artifacts"
	@echo "    make fmt        - Format Zig code"
	@echo ""
	@echo "  Documentation targets:"
	@echo "    make docs-install  - Install docs dependencies (bun)"
	@echo "    make docs-dev      - Start dev server with hot reload"
	@echo "    make docs-build    - Build static documentation"
	@echo "    make docs-preview  - Preview built documentation"
	@echo "    make docs-clean    - Clean docs build artifacts"
	@echo "    make docs-autodoc  - Generate Zig autodocs"
	@echo "    make docs-build-all - Build autodocs + Starlight site"
	@echo "    make docs-release TAG=v1.0.0 - Build docs from a git tag"
	@echo "    make docs          - Alias for docs-dev"
	@echo ""
	@echo "  Combined targets:"
	@echo "    make clean-all  - Clean all build artifacts"
	@echo "    make rebuild    - Clean and rebuild"
	@echo ""
