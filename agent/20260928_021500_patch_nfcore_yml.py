# .nf-core.yml: justify the .gitattributes lint failure (dropped with the skipped 'github' feature); make the recorded
# template outdir relative and drop 'force' (both were artefacts of scaffolding into agent/).
p = "/Users/fvrodriguez/repos/zealgt/.nf-core.yml"
s = open(p).read()
s = s.replace("""  files_exist:
    - .github/workflows/branch.yml""", """  files_exist:
    # zealgt: .gitattributes belongs to the skipped 'github' template feature (GitHub linguist hints only; no GitHub CI here)
    - .gitattributes
    - .github/workflows/branch.yml""", 1)
s = s.replace("  force: true\n", "")
s = s.replace("  outdir: /Users/fvrodriguez/repos/zealgt/agent/20260928_011000_scaffold/zealgt\n", "  outdir: .\n")
open(p, "w").write(s)
