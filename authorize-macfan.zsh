#!/bin/zsh
set -euo pipefail

readonly helper_dir="/Library/PrivilegedHelperTools"
readonly helper="${helper_dir}/com.alexis.macfan.helper"
readonly binary="${helper_dir}/macfan"
readonly rule_dir="/etc/sudoers.d"
readonly rule="${rule_dir}/com.alexis.macfan"
readonly sudoers="/etc/sudoers"

[[ "$EUID" == 0 ]] || exit 77

/usr/bin/install -d -o root -g wheel -m 755 "$helper_dir"
/usr/bin/install -o root -g wheel -m 755 /Users/alexis/bin/macfan "$binary"
/usr/bin/install -o root -g wheel -m 755 /Users/alexis/src/macfan/macfan-privileged-helper.zsh "$helper"
/usr/bin/install -d -o root -g wheel -m 755 "$rule_dir"
/usr/bin/install -o root -g wheel -m 440 /Users/alexis/src/macfan/com.alexis.macfan.sudoers "$rule"

if ! /usr/bin/grep -Eq '^[[:space:]]*@includedir[[:space:]]+/etc/sudoers\.d[[:space:]]*$' "$sudoers"; then
    readonly temporary="$(/usr/bin/mktemp /tmp/macfan-sudoers.XXXXXX)"
    /bin/cp "$sudoers" "$temporary"
    /bin/printf '\n@includedir /etc/sudoers.d\n' >> "$temporary"
    /usr/sbin/visudo -cf "$temporary"
    /usr/bin/install -o root -g wheel -m 440 "$temporary" "$sudoers"
    /bin/rm -f "$temporary"
fi

/usr/sbin/visudo -cf "$sudoers"
exec "$helper" check
