#!/usr/bin/env python3
"""从 page.tpl.html + 三套 macOS 版 SVG 生成图标方案对比页。

SVG 以 base64 data URI 内联，因为 Artifact 的 CSP 不允许外部资源；
每个 data URI 在 CSS 里只出现一次，由 class 复用，避免长串重复。
"""
import base64, pathlib

HERE = pathlib.Path(__file__).resolve().parent
ICON = HERE.parent
VARIANTS = [("__ICO_A__", "a-classic"), ("__ICO_B__", "b-staggered"), ("__ICO_C__", "c-dark")]

tpl = (HERE / "page.tpl.html").read_text()
for token, name in VARIANTS:
    svg = (ICON / f"mnemo-{name}-macos.svg").read_bytes()
    tpl = tpl.replace(token, f"data:image/svg+xml;base64,{base64.b64encode(svg).decode()}")

out = ICON / "mnemo-icon-review.html"
out.write_text(tpl)
print(f"{out.name}  {out.stat().st_size / 1024:.0f} KB")
