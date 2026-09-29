# Env round task 5: tests/fixtures/raw/LIBB1_BAD/R1.tar = LIBB1's R1.tar with its lane L001 member cut to half its size
# (a truncated gzip, as a copy cut short would leave it). Deterministic (ustar, mtime 0, uid/gid 0), like the LIBB1 fixture
# (agent/20260928_163000_make_batch1_fixture.py). DEMUX's --subsample test on it must fail the task.
import io
import tarfile
from pathlib import Path

R = Path("/Users/fvrodriguez/repos/zealgt-simplify/tests/fixtures/raw")
src = R / "LIBB1" / "R1.tar"
out = R / "LIBB1_BAD" / "R1.tar"
out.parent.mkdir(exist_ok=True)

with tarfile.open(src) as tin, tarfile.open(out, "w", format=tarfile.USTAR_FORMAT) as tout:
    for m in tin.getmembers():
        info = tarfile.TarInfo(m.name)
        info.mtime, info.uid, info.gid, info.uname, info.gname = 0, 0, 0, "", ""
        if m.isdir():
            info.type, info.mode = tarfile.DIRTYPE, 0o755
            tout.addfile(info)
            continue
        data = tin.extractfile(m).read()
        if "_L001_" in m.name:
            data = data[: len(data) // 2]
        info.size, info.mode = len(data), 0o644
        tout.addfile(info, io.BytesIO(data))
        print(m.name, len(data))
