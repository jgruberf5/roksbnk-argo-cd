#!/usr/bin/env python3
"""Embed bootstrap/health/bnk-status.lua into the two Argo CD wiring files so the
health check has a single source of truth."""
import pathlib, re, textwrap

root = pathlib.Path(__file__).resolve().parents[1]
lua = (root / "bootstrap/health/bnk-status.lua").read_text().rstrip("\n")

targets = {
    root / "bootstrap/upstream/argocd-cm-health.yaml": ("  resource.customizations.health.ConfigMap: |\n", 4),
    root / "bootstrap/openshift/argocd-cr.yaml": ("      check: |\n", 8),
}
for path, (marker, indent) in targets.items():
    text = path.read_text()
    head, sep, tail = text.partition(marker)
    if not sep:
        raise SystemExit(f"{path}: marker {marker!r} not found")
    # the block ends at the first line indented less than `indent` (or EOF)
    lines = tail.splitlines(keepends=True)
    end = len(lines)
    for i, line in enumerate(lines):
        if line.strip() and (len(line) - len(line.lstrip(" "))) < indent:
            end = i
            break
    block = textwrap.indent(lua, " " * indent) + "\n"
    path.write_text(head + sep + block + "".join(lines[end:]))
    print(f"embedded into {path.relative_to(root)}")
