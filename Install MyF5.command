#!/bin/zsh
cd "$(dirname "$0")"
./install.sh
result=$?
echo "Press Return to close this installer."
read
exit $result
