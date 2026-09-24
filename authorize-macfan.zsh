#!/bin/zsh
set -euo pipefail

readonly helper_dir="/Library/PrivilegedHelperTools"
readonly helper="${helper_dir}/macfan-helper"
readonly binary="${helper_dir}/macfan"
readonly rule_dir="/etc/sudoers.d"
readonly rule="${rule_dir}/macfan-authorized"
readonly sudoers="/etc/sudoers"
readonly source_binary="${1:-}"
readonly requesting_user="${2:-}"
readonly source_dir="${0:A:h}"

[[ "$EUID" == 0 ]] || exit 77
[[ -n "$source_binary" && -x "$source_binary" ]] || exit 66
[[ "$requesting_user" =~ '^[A-Za-z_][A-Za-z0-9._-]*$' ]] || exit 64
[[ -x "${source_dir}/macfan-privileged-helper.zsh" ]] || exit 66

/usr/bin/install -d -o root -g wheel -m 755 "$helper_dir"
/usr/bin/install -o root -g wheel -m 755 "$source_binary" "$binary"
/usr/bin/install -o root -g wheel -m 755 "${source_dir}/macfan-privileged-helper.zsh" "$helper"
/usr/bin/install -d -o root -g wheel -m 755 "$rule_dir"
readonly temporary_rule="$(/usr/bin/mktemp /tmp/macfan-rule.XXXXXX)"
/bin/printf '%s ALL=(root) NOPASSWD: %s\n' "$requesting_user" "$helper" > "$temporary_rule"
/usr/sbin/visudo -cf "$temporary_rule"
/usr/bin/install -o root -g wheel -m 440 "$temporary_rule" "$rule"
/bin/rm -f "$temporary_rule"

if ! /usr/bin/grep -Eq '^[[:space:]]*@includedir[[:space:]]+(/private)?/etc/sudoers\.d[[:space:]]*$' "$sudoers"; then
    readonly temporary="$(/usr/bin/mktemp /tmp/macfan-sudoers.XXXXXX)"
    /bin/cp "$sudoers" "$temporary"
    /bin/printf '\n@includedir /etc/sudoers.d\n' >> "$temporary"
    /usr/sbin/visudo -cf "$temporary"
    /usr/bin/install -o root -g wheel -m 440 "$temporary" "$sudoers"
    /bin/rm -f "$temporary"
fi

/usr/sbin/visudo -cf "$sudoers"
exec "$helper" check
