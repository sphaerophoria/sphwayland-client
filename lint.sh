#!/usr/bin/env bash

set -ex

zig fmt --check src build.zig
zig build
black --check $(git ls-files | grep ".py$")
