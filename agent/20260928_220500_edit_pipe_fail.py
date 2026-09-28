#!/usr/bin/env python3
"""CodeRabbit gate1 run1 finding (major): zg_pipe_fail must prefer 137 (OOM kill) over an earlier SIGPIPE 141."""
import re
from pathlib import Path

R = Path("/Users/fvrodriguez/repos/zealgt")
for mod in ("align_markdup", "markdup_import"):
    p = R / f"modules/local/{mod}/main.nf"
    s = p.read_text()
    old = re.compile(r"    zg_pipe_fail\(\) \{\n.*?\n    \}\n", re.S)
    new = (
        "    zg_pipe_fail() {\n"
        "        local s sig=0 first=0\n"
        "        for s in \"\\$@\"; do\n"
        "            if [ \"\\$s\" -eq 137 ]; then\n"
        "                sig=137\n"
        "            elif [ \"\\$s\" -gt 128 ] && [ \"\\$sig\" -eq 0 ]; then\n"
        "                sig=\\$s\n"
        "            fi\n"
        "            [ \"\\$first\" -ne 0 ] || first=\\$s\n"
        "        done\n"
        f"        echo \"{mod}: pipe statuses \\$*\" >&2\n"
        "        [ \"\\$sig\" -eq 0 ] || exit \"\\$sig\"\n"
        "        exit \\$(( first ? first : 1 ))\n"
        "    }\n"
    )
    s2, n = old.subn(lambda m: new, s)
    assert n == 1, (mod, n)
    s2 = s2.replace(
        "    # exit with the pipe's first signal status (> 128: 137 = OOM kill, so errorStrategy retries with more memory), else\n",
        "    # exit with the pipe's signal status (137 = OOM kill preferred over the SIGPIPE 141 it causes upstream; errorStrategy\n"
        "    # retries 130-145 with more memory), else\n",
    )
    p.write_text(s2)
    print(mod, "ok")
