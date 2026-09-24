#!/bin/zsh
set -euo pipefail

readonly repo_root="${0:A:h:h}"
cd "$repo_root"

cargo fmt --check
cargo test --locked
cargo clippy --locked -- -D warnings
swiftc -typecheck MenuBar/MacFanMenu.swift
swiftc -typecheck MenuBar/MacFanMenuLegacy.swift
zsh -n authorize-macfan.zsh macfan-privileged-helper.zsh scripts/build.sh scripts/check.sh
plutil -lint MenuBar/Info.plist
git diff --check
