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
    --no-debug \
    --mcpu native
  strip ssm-scp
  rm -f *.dwarf

# Install to /usr/local/bin
install: build
  sudo install -m 755 ssm-scp /usr/local/bin/ssm-scp

# Development build (fast compile, no optimisations)
dev: deps
  crystal build ssm-scp.cr -o ssm-scp

# Smoke test
test: dev
  ./ssm-scp --help

# Remove build artefacts
clean:
  rm -f ssm-scp
