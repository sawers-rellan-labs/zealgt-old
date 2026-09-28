# Collapse arrays of scalars in nextflow_schema.json back onto one line (prettier style of the template).
import re, sys
p = sys.argv[1]
s = open(p).read()
def repl(m):
    items = [x.strip() for x in m.group(2).split(",")]
    return m.group(1) + "[" + ", ".join(items) + "]"
s = re.sub(r'(: )\[\s*\n((?:\s*(?:"[^"\n]*"|-?\d+(?:\.\d+)?|true|false|null),?\s*\n)+?)\s*\]', repl, s)
open(p, "w").write(s)
