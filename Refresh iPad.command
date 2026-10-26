#!/bin/bash
# Double-click: renew the iPad app for another 7 days (plug the iPad in first).
"$(dirname "$0")/scripts/portraitpad.sh" ipad
echo; read -n 1 -s -r -p "Press any key to close."
