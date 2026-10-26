#!/bin/bash
# Double-click: update PortraitPad and install both apps (plug the iPad in first).
"$(dirname "$0")/scripts/portraitpad.sh" install
echo; read -n 1 -s -r -p "Press any key to close."
