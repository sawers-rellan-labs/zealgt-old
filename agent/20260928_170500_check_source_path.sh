#!/usr/bin/env bash
# Check that bash `source <name>` finds a NON-executable file through PATH (M7: source export_slurm_resources.sh from bin/).
d="$(mktemp -d)"
printf 'ZG_TEST_SOURCED=yes\n' > "$d/zg_probe_helper.sh"
chmod 644 "$d/zg_probe_helper.sh"
ls -l "$d/zg_probe_helper.sh"
PATH="$d:$PATH" bash -euo pipefail -c 'source zg_probe_helper.sh; echo "sourced: $ZG_TEST_SOURCED ($BASH_VERSION)"'
/opt/homebrew/bin/bash --version 2>/dev/null | head -1 && PATH="$d:$PATH" /opt/homebrew/bin/bash -euo pipefail -c 'source zg_probe_helper.sh; echo "sourced: $ZG_TEST_SOURCED ($BASH_VERSION)"'
