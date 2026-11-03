"""Machine-aware parallelism shared by the app and build engine."""
from __future__ import annotations
import os
import subprocess


def automatic_jobs(cores: int | None = None, memory_bytes: int | None = None) -> int:
    cores = cores or os.cpu_count() or 2
    if memory_bytes is None:
        try:
            value = subprocess.run(['sysctl','-n','hw.memsize'],capture_output=True,text=True,timeout=2)
            memory_bytes = int(value.stdout.strip()) if value.returncode == 0 else 0
        except (OSError,ValueError,subprocess.TimeoutExpired): memory_bytes = 0
    # Reserve roughly four GiB per concurrent compiler, capped at eight.
    memory_jobs = max(1,memory_bytes // (4*1024**3)) if memory_bytes else 2
    return max(1,min(cores,memory_jobs,8))
