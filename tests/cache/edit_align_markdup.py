#!/usr/bin/env python3
"""scripts/test_cache.sh R3: a harmless command change inside ALIGN_MARKDUP's script: block (in the scratch clone only).

`rmdir "\\$tmp" 2>/dev/null || true` -> `... || :` (same effect). Refuses unless the line occurs exactly once and lies
between `script:` and `stub:`, so a changed module fails loudly instead of editing something else.
"""
import sys

OLD = 'rmdir "\\$tmp" 2>/dev/null || true'
NEW = 'rmdir "\\$tmp" 2>/dev/null || :'

path = sys.argv[1]
text = open(path).read()
if text.count(OLD) != 1:
    sys.exit(f"edit_align_markdup: expected exactly one '{OLD}' in {path}, found {text.count(OLD)}")
pos, script, stub = text.index(OLD), text.find('    script:'), text.find('    stub:')
if not (0 <= script < pos < stub):
    sys.exit(f"edit_align_markdup: '{OLD}' is not inside the script: block of {path}")
open(path, 'w').write(text.replace(OLD, NEW))
print(f"edit_align_markdup: {path}: '{OLD}' -> '{NEW}'")
