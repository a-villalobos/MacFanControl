#!/bin/zsh
set -euo pipefail

[[ "$EUID" == 0 ]] || exit 77
readonly MACFAN="/Library/PrivilegedHelperTools/macfan"

case "${1:-}" in
    set)
        [[ $# -eq 3 && "$2" =~ '^[01]$' && "$3" =~ '^[0-9]+$' ]] || exit 64
        exec "$MACFAN" --set "$2" "$3"
        ;;
    auto)
        [[ $# -eq 1 ]] || exit 64
        exec "$MACFAN" --auto
        ;;
    *)
        exit 64
        ;;
esac
