#!/bin/zsh
set -e
/usr/bin/osascript -e 'do shell script "/bin/grep -q \"com.alexis.macfan.helper\" /etc/sudoers || /bin/printf \"\\nalexis ALL=(root) NOPASSWD: /Library/PrivilegedHelperTools/com.alexis.macfan.helper\\n\" >> /etc/sudoers; /usr/sbin/visudo -cf /etc/sudoers" with administrator privileges'
echo "Mac Fan authorization enabled. You can close this window."
read -k 1
