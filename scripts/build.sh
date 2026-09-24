#!/bin/zsh
set -euo pipefail

readonly repo_root="${0:A:h:h}"
readonly build_root="${MACFAN_BUILD_DIR:-${repo_root}/build}"
readonly app="${build_root}/Fan.app"
readonly contents="${app}/Contents"
readonly executable_dir="${contents}/MacOS"
readonly resources_dir="${contents}/Resources"
readonly version="$(sed -n 's/^version = "\([^"]*\)"/\1/p' "${repo_root}/Cargo.toml" | head -1)"

[[ -n "$version" ]] || { print -u2 "Could not read package version"; exit 65; }

cd "$repo_root"
cargo build --release --locked

/bin/rm -rf "$app"
/bin/mkdir -p "$executable_dir" "$resources_dir"
swiftc -O MenuBar/MacFanMenu.swift -o "${executable_dir}/MacFanMenu"
/bin/cp MenuBar/Info.plist "${contents}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version}" "${contents}/Info.plist"
/bin/cp target/release/macfan "${resources_dir}/macfan"
/bin/cp authorize-macfan.zsh macfan-privileged-helper.zsh "$resources_dir/"
/bin/chmod 755 "${executable_dir}/MacFanMenu" "${resources_dir}/macfan" \
    "${resources_dir}/authorize-macfan.zsh" "${resources_dir}/macfan-privileged-helper.zsh"
/usr/bin/printf 'APPL????' > "${contents}/PkgInfo"

/usr/bin/plutil -lint "${contents}/Info.plist"
[[ -x "${executable_dir}/MacFanMenu" ]]
[[ -x "${resources_dir}/macfan" ]]

print "Built ${app}"
