#!/bin/zsh
set -e
/usr/bin/osascript -e 'do shell script "/bin/printf \"\\n@includedir /etc/sudoers.d\\n\" >> /etc/sudoers && /usr/sbin/visudo -cf /etc/sudoers" with administrator privileges'
echo "Authorization rule installed. You can close this window."
read -k 1
