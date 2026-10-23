#!/usr/bin/env python3
"""Reject screen-local SwiftUI timing; native/gesture owners are explicit exceptions."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
# Gesture geometry and saved Tune-driven Core Animation remain with their owners.
exceptions = {"GlassMotion.swift", "TorrentFolderMotion.swift", "TorrentListElevation.swift"}
pattern = re.compile(r"\.(?:smooth|snappy|bouncy|spring|easeInOut|easeIn|easeOut|linear|timingCurve)\s*(?:\(|(?=\s*[,)]))")
violations = []
for path in (root / "Sources/GlassRemoteUI").rglob("*.swift"):
    if path.name in exceptions:
        continue
    for line, source in enumerate(path.read_text().splitlines(), 1):
        if pattern.search(source) and not source.lstrip().startswith("//"):
            violations.append(f"{path.relative_to(root)}:{line}: use the shared GlassMotion policy")
print("\n".join(violations) if violations else "Motion ownership passed")
sys.exit(bool(violations))
