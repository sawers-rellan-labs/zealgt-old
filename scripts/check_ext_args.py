#!/usr/bin/env python3
"""scripts/check_ext_args.py — fail if a `task.*` reference appears inside an `ext.args*` closure of a Nextflow config.

Why: the evaluated value of task.ext.args enters the task hash, so `ext.args = { "-t ${task.cpus}" }` reruns the task on
every resource change (nextflow-cache skill, Trap 1). Resources belong in the script (`${task.cpus}`, not hashed on
Nextflow >= 26.04.6) or in directives.

    python3 scripts/check_ext_args.py [config ...]      default: conf/*.config of this checkout

Scans every `ext.args`, `ext.args2`, ... assignment whose value is a closure `{ ... }` (multi-line closures included: the
body runs to the matching brace, braces inside quoted strings are skipped), ignores `//` and `/* */` comments, and prints
<file>:<line>: <text> for each `task.` found. Exit 1 on any finding, 0 otherwise. Run by scripts/run_checks.sh (also --quick).
"""
import pathlib
import re
import sys

ASSIGN = re.compile(r'\bext\.args\d*\s*=\s*\{')


def strip_comments(text):
    """Blank out // and /* */ comments outside quotes, keeping offsets and newlines (so line numbers stay right)."""
    out = list(text)
    i, n, quote = 0, len(text), None
    while i < n:
        c = text[i]
        if quote:
            if c == '\\':
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in ('"', "'"):
            quote = c
        elif text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
            continue
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != '\n':
                    out[k] = ' '
            i = j
            continue
        i += 1
    return ''.join(out)


def closure_end(text, start):
    """Index just past the brace matching text[start] == '{'; braces inside '...' strings are skipped, those in "..."
    strings are counted (GString ${...} is balanced)."""
    depth, i, n, quote = 0, start, len(text), None
    while i < n:
        c = text[i]
        if quote:
            if c == '\\':
                i += 2
                continue
            if c == quote:
                quote = None
        elif c == "'":
            quote = c
        elif c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def scan(path):
    text = strip_comments(path.read_text())
    findings = []
    for m in ASSIGN.finditer(text):
        body_start = m.end() - 1
        body_end = closure_end(text, body_start)
        for t in re.finditer(r'\btask\.', text[body_start:body_end]):
            pos = body_start + t.start()
            line = text.count('\n', 0, pos) + 1
            findings.append((line, path.read_text().splitlines()[line - 1].strip()))
    return findings


def main(argv):
    repo = pathlib.Path(__file__).resolve().parent.parent
    paths = [pathlib.Path(a) for a in argv] or sorted((repo / 'conf').glob('*.config'))
    bad = 0
    for p in paths:
        for line, src in scan(p):
            print(f'{p}:{line}: task.* inside an ext.args closure (hashed; pass resources in the script): {src}')
            bad += 1
    if bad:
        print(f'check_ext_args: {bad} finding(s)', file=sys.stderr)
        return 1
    print(f'check_ext_args: no task.* in ext.args closures ({len(paths)} config files)')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
