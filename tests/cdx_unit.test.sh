#!/usr/bin/env bash
# Runner so 'make test' (which globs tests/*.test.sh) picks up the Python unit
# tests. The tests themselves live in cdx_unit.py, where they are editable as
# Python rather than as a string inside a shell script.
exec python3 "$(dirname "${BASH_SOURCE[0]}")/cdx_unit.py"
