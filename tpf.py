#!/usr/bin/env python3
"""Launcher: ./tpf.py build | check | list | new | clean  (see ./tpf.py --help)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "tools"))

from tpfbuild.cli import main  # noqa: E402

sys.exit(main())
