"""Discover this user's Studio servers; never terminate an arbitrary PID."""
from __future__ import annotations
import contextlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.request
import fcntl


def discover(root: Path, current_pid: int) -> list[dict]:
    candidates = {current_pid: root}
    result = subprocess.run(['ps','-U',str(os.getuid()),'-o','pid=,command='],text=True,capture_output=True,timeout=3)
    for line in result.stdout.splitlines():
        match = re.match(r'\s*(\d+)\s+(.+)',line)
        if not match: continue
        script = re.search(r'\s(/.+?/installer_app\.py)(?=\s|$)',match[2])
        if script: candidates[int(match[1])] = Path(script[1]).parent
    instances = []
    for pid, directory in candidates.items():
        try:
            info=json.loads((directory/'.installer_app.json').read_text())
            port=int(info['port'])
            if int(info['pid'])!=pid or not 0<port<65536: continue
            record={'pid':pid,'port':port,'workspace':str(directory),'current':pid==current_pid,'responding':False,'managed':False,'busy':False}
            try:
                with urllib.request.urlopen(f'http://127.0.0.1:{port}/api/health',timeout=.5) as response: health=json.load(response)
                if int(health.get('pid',0))==pid:
                    record.update(responding=True,managed=health.get('instanceControl')==1,busy=bool(health.get('busy')))
            except (OSError,ValueError): pass
            instances.append(record)
        except (OSError,ValueError,KeyError,TypeError): continue
    healthy=sum(item['responding'] for item in instances)
    for item in instances:
        item['canStop']=healthy>1 and item['responding'] and item['managed'] and not item['busy']
        item['terminalCommand']=f"kill {item['pid']}"
    return instances


@contextlib.contextmanager
def shutdown_lock():
    # Shared by clones of this app, so two stop requests cannot remove the last server.
    path=Path(tempfile.gettempdir())/f'manivault-studio-instances-{os.getuid()}.lock'
    descriptor=os.open(path,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    with os.fdopen(descriptor,'a+') as stream:
        fcntl.flock(stream.fileno(),fcntl.LOCK_EX)
        try: yield
        finally: fcntl.flock(stream.fileno(),fcntl.LOCK_UN)


def validate_shutdown(instances: list[dict], expected_pid: int, current_pid: int, busy: bool):
    if expected_pid!=current_pid: raise ValueError('The selected process changed. Refresh the instance list.')
    if sum(item['responding'] for item in instances)<2:
        raise ValueError('The last app instance can only be stopped from Terminal.')
    if busy: raise ValueError('This instance has a running build. Finish or stop the build first.')
