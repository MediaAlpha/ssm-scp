#!/usr/bin/env just --justfile

default:
    @just --list

# Install dependencies (no network when lib/ already matches shard.lock)
deps:
  shards check || shards install

# Build the release binary
build: deps
  crystal build ssm-scp.cr -o ssm-scp \
    --release \
    --no-debug
  strip ssm-scp
  rm -f *.dwarf

# Build a static linux/arm64 binary (musl) in the official arm64 Alpine container
build-static: deps
  podman run --rm --platform linux/arm64 -v "$PWD":/w -w /w docker.io/crystallang/crystal:latest-alpine \
    crystal build ssm-scp.cr -o ssm-scp-linux-arm64 --release --no-debug --static
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

# Build Ameba (pinned in shard.lock) into the gitignored bin/, only when it is
# missing or older than shard.lock
ameba-build: deps
  mkdir -p bin
  [ bin/ameba -nt shard.lock ] || crystal build lib/ameba/bin/ameba.cr -o bin/ameba

# Lint with Ameba
lint: ameba-build
  bin/ameba ssm-scp.cr src spec

# Offline specs (no AWS, network or SSM): unit specs plus end-to-end specs of
# ssm-scp.cr against a fake aws
spec:
  crystal spec

# Default test flow: format check, lint, specs
test: fmt-check lint spec

# Smoke test the built binary (--help)
smoke: dev
  ./ssm-scp --help

# Remove build artefacts
clean:
  rm -f ssm-scp *.dwarf
