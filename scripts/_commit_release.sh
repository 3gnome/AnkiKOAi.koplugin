#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
git add .cursor/rules/ankikooai-dev.mdc .gitignore LOCAL_DEV.md.sample README.md _check.sh \
  card_reconcile.lua card_storage.lua docs/ highlight_inbox.lua main.lua plugin_constants.lua \
  plugin_menu.lua readme_viewer.lua start.sh dev-lib.sh dev-start.sh highlight_cleanup.lua scripts/ spec/
git commit -m "$(cat <<'EOF'
Add View All Highlights, highlight cleanup, and dev tooling for v1.0.9.

Expose the highlight inbox from the highlight menu and hub, remove orphan orange highlights after background send, add dev-start/dev-lib and Alice reset script, and refresh docs for the new workflows.
EOF
)"
