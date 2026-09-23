#!/bin/zsh
set -e
/usr/bin/osascript -e 'do shell script "/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools && /usr/bin/install -o root -g wheel -m 755 /Users/alexis/bin/macfan /Library/PrivilegedHelperTools/macfan && /usr/bin/install -o root -g wheel -m 755 /Users/alexis/src/macfan/macfan-privileged-helper.zsh /Library/PrivilegedHelperTools/com.alexis.macfan.helper && /usr/bin/install -o root -g wheel -m 440 /Users/alexis/src/macfan/com.alexis.macfan.sudoers /etc/sudoers.d/com.alexis.macfan && /usr/sbin/visudo -cf /etc/sudoers" with administrator privileges'
/usr/bin/osascript -e 'do shell script "/bin/grep -Eq \"^[#@]include(dir)?[[:space:]]+/etc/sudoers.d\" /etc/sudoers || /bin/printf \"\\n@includedir /etc/sudoers.d\\n\" >> /etc/sudoers && /usr/sbin/visudo -cf /etc/sudoers" with administrator privileges'
echo "Mac Fan privileged helper installed. You can close this window."
read -k 1
