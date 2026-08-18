#!/usr/bin/env bash
# Focused quota/cache tests for cdc's network boundary.
exec python3 "$(dirname "${BASH_SOURCE[0]}")/cdc_unit.py"
