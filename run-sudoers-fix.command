#!/bin/zsh
/usr/bin/osascript -e 'do shell script "/bin/zsh /Users/alexis/src/macfan/fix-sudoers-root.zsh" with administrator privileges'
echo "Done. You can close this window."
read -k 1
