# Development tasks. Docker must be running.

default:
    @just --list

# Type-check every package without running tests.
check:
    moon check --target native

# Format all MoonBit sources.
fmt:
    moon fmt

# Run the full integration suite (starts real containers).
test:
    moon test --target native --no-parallelize

# Run one package, e.g. `just test-package postgres`.
test-package package:
    moon test --target native -p xziheng/testcontainers/{{package}}

# Regenerate .mbti interfaces and format.
info:
    moon info
    moon fmt

# Remove containers leaked by a killed test process.
clean:
    #!/bin/sh
    ids="$(docker ps -aq --filter label=org.testcontainers.mbt=true)"
    [ -z "$ids" ] || docker rm -f $ids
