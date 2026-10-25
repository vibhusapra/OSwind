#!/usr/bin/env python3
"""Run generated-data stdlib SDK contracts without a compiled CLI or network."""
from pathlib import Path
import sys
import unittest
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'sdk/python'))
suite=unittest.defaultTestLoader.discover(str(root/'sdk/python/tests'))
result=unittest.TextTestRunner(verbosity=2).run(suite)
raise SystemExit(0 if result.wasSuccessful() else 1)
