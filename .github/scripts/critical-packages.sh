#!/usr/bin/env bash
#
# Single maintained list of system-critical packages.
#
# Sourced by the matrix steps in build-release.yml and build-staging.yml
# (and by the regression tests). Keep this list in sync with the critical
# packages in packages.txt; it is the ONLY source of truth for what is
# considered system-critical.
#
# System-critical packages:
#   - are NEVER built by default (production matrix excludes them),
#   - are rejected by staging without exception,
#   - can be built in production only via an explicit manual
#     `allow-critical` approval listing the exact package name.

CRITICAL_PACKAGES=(
  pacman
  nvidia-utils
  lib32-nvidia-utils
  xlibre-xserver
  xlibre-xserver-src
  xlibre-input-libinput
  linux-nanoka
  networkmanager-iwd
)
