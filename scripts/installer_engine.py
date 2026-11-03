#!/usr/bin/env python3
"""Compatibility entrypoint for the organized workflow engine."""
from pathlib import Path
from runpy import run_path

run_path(Path(__file__).parent / "workflow" / "installer_engine.py", run_name="__main__")
