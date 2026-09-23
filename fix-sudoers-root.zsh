#!/bin/zsh
set -euo pipefail
tmp="$(/usr/bin/mktemp /tmp/macfan-sudoers.XXXXXX)"
/bin/cp /etc/sudoers "$tmp"
if ! /usr/bin/grep -Eq '^[#@]include(dir)?[[:space:]]+/etc/sudoers.d' "$tmp"; then
    /bin/printf '\n@includedir /etc/sudoers.d\n' >> "$tmp"
fi
/usr/sbin/visudo -cf "$tmp"
/usr/bin/install -o root -g wheel -m 440 "$tmp" /etc/sudoers
/bin/rm -f "$tmp"
