#!/usr/bin/env just --justfile

default:
    @just --list

# Install dependencies
deps:
  shards install

# Build the release binary
build: deps
  crystal build ssm-scp.cr -o ssm-scp \
    --release \
    --no-debug
  strip ssm-scp
  rm -f *.dwarf

# Install to /usr/local/bin
install: build
  sudo install -m 755 ssm-scp /usr/local/bin/ssm-scp

# Development build (fast compile, no optimisations)
dev: deps
  crystal build ssm-scp.cr -o ssm-scp

# Check formatting (no changes written)
fmt-check:
  crystal tool format --check ssm-scp.cr src spec

# Build Ameba (pinned in shard.lock) into the gitignored bin/
ameba-build: deps
  mkdir -p bin
  crystal build lib/ameba/bin/ameba.cr -o bin/ameba

# Lint with Ameba
lint: ameba-build
  bin/ameba ssm-scp.cr src spec

# Offline unit specs (no AWS, network or SSM)
spec:
  crystal spec

# Default test flow: format check, lint, specs
test: fmt-check lint spec

# Smoke test the built binary (--help)
smoke: dev
  ./ssm-scp --help

# Remove build artefacts
clean:
  rm -f ssm-scp
