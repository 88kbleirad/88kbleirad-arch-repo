#!/usr/bin/env python3
"""Validate that every GitHub Actions workflow is parseable YAML with jobs.

The `on:` key is reserved in some YAML 1.1 parsers; rename it before
parsing (same trick as the repository's run-tests.sh).
"""
import glob
import sys
import yaml

root = sys.argv[1] if len(sys.argv) > 1 else "."
files = sorted(glob.glob(root.rstrip("/") + "/.github/workflows/*.yml"))
if not files:
    raise SystemExit("no workflow files found")

failed = False
for f in files:
    raw = open(f, encoding="utf-8").read().splitlines()
    for i, ln in enumerate(raw):
        if ln == "on:":
            raw[i] = "on_github:"
            break
    try:
        data = yaml.safe_load("\n".join(raw))
    except yaml.YAMLError as exc:
        print(f"YAML ERROR {f}: {exc}")
        failed = True
        continue
    if not isinstance(data, dict) or "jobs" not in data:
        print(f"INVALID {f}: missing top-level jobs")
        failed = True
        continue
    print("OK:", f.split("/")[-1])

if failed:
    raise SystemExit(1)
