#!/usr/bin/env python3
"""Mnemo 图标的 SVG 版本 —— 开口朝上的磁石，吸住的那一件东西悬在开口里。

真正打包进 .app 的位图由 `swift run MnemoIconGen` 渲染，几何来自
`Sources/MnemoCore/MnemoMark.swift`；这份脚本只产出同一套几何的 SVG，
供文档与图标对比页使用。改几何时两边要一起改，下面的常量必须和 MnemoMark 对齐。
"""

S = 1024  # 画布
FACE_R = 224
MACOS_INSET = 100

# --- 与 MnemoMark 对齐的几何 -------------------------------------------
CX, CY = 512, 530          # 底部圆弧的圆心
ARM_R = 262                # 磁石臂中线半径
ARM_W = 148                # 臂宽（描边宽度）
TIP_Y = 195                # 两个磁极端面的 y
TIP_BAND = 148             # 端面换色的长度
ITEM_CX, ITEM_CY = 512, 267
ITEM_R = 108

LEG_L, LEG_R = CX - ARM_R, CX + ARM_R
HALF = ARM_W / 2

VARIANTS = {
    # 暖象牙底 + 深靛磁石 + 琥珀磁极
    "a-classic": dict(
        face=("#FCF8F1", "#EDE4D5"),
        arm=("#27346F", "#141B3C"),
        tip="#F2A33C", item="#1F2A5C",
        rim="#FFFFFF", rim_op=0.72, sheen=0.55,
    ),
    # 深空底 + 青蓝渐变磁石 + 暖色磁极
    "b-staggered": dict(
        face=("#171A22", "#05060A"),
        arm=("#3BE3C6", "#3A72F5"),
        tip="#FFC15E", item="#F4F1EA",
        rim="#FFFFFF", rim_op=0.16, sheen=0.10,
    ),
    # 纯黑底 + 象牙单色磁石
    "c-dark": dict(
        face=("#0C0D10", "#060709"),
        arm=("#F4F1EA", "#D5D0C4"),
        tip="#8F8A7C", item="#F4F1EA",
        rim="#FFFFFF", rim_op=0.14, sheen=0.08,
    ),
}


def body_path():
    """左腿向下 → 底部半圆 → 右腿向上。sweep-flag=0：y 向下时这才是走底边。"""
    return (f"M{LEG_L},{TIP_Y} V{CY} "
            f"A{ARM_R},{ARM_R} 0 0 0 {LEG_R},{CY} V{TIP_Y}")


def build(v, inset=0):
    """inset>0 输出 macOS 版式：内容缩进安全区，四周留给系统投影。"""
    scale = (S - 2 * inset) / S
    # 腿是直的，端面换色直接用矩形，不必为了裁剪再描一遍轮廓。
    tips = "\n".join(
        f'      <rect x="{x - HALF}" y="{TIP_Y}" width="{ARM_W}" height="{TIP_BAND}" fill="{v["tip"]}"/>'
        for x in (LEG_L, LEG_R))

    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {S} {S}" width="{S}" height="{S}">
  <defs>
    <linearGradient id="face" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{v['face'][0]}"/><stop offset="1" stop-color="{v['face'][1]}"/>
    </linearGradient>
    <linearGradient id="arm" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{v['arm'][0]}"/><stop offset="1" stop-color="{v['arm'][1]}"/>
    </linearGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fff" stop-opacity="{v['sheen']}"/>
      <stop offset="1" stop-color="#fff" stop-opacity="0"/>
    </linearGradient>
    <filter id="castShadow" x="-25%" y="-15%" width="150%" height="150%">
      <feDropShadow dx="0" dy="24" stdDeviation="15" flood-color="#0A1226" flood-opacity=".32"/>
    </filter>
    <clipPath id="faceClip">
      <rect x="0" y="0" width="{S}" height="{S}" rx="{FACE_R}" ry="{FACE_R}"/>
    </clipPath>
  </defs>

  <g transform="translate({inset},{inset}) scale({scale:.6f})" {'filter="url(#castShadow)"' if inset else ''}>
    <rect x="0" y="0" width="{S}" height="{S}" rx="{FACE_R}" ry="{FACE_R}" fill="url(#face)"/>
    <g clip-path="url(#faceClip)">
      <rect x="0" y="0" width="{S}" height="{S * 0.52}" fill="url(#sheen)"/>
      <path d="{body_path()}" fill="none" stroke="url(#arm)" stroke-width="{ARM_W}"
            stroke-linecap="butt" stroke-linejoin="round"/>
{tips}
      <circle cx="{ITEM_CX}" cy="{ITEM_CY}" r="{ITEM_R}" fill="{v['item']}"/>
    </g>
    <rect x="3" y="3" width="{S-6}" height="{S-6}" rx="{FACE_R-3}" ry="{FACE_R-3}"
          fill="none" stroke="{v['rim']}" stroke-opacity="{v['rim_op']}" stroke-width="6"/>
  </g>
</svg>
'''


import pathlib
out = pathlib.Path(__file__).resolve().parent.parent
for name, v in VARIANTS.items():
    (out / f"mnemo-{name}.svg").write_text(build(v))
    (out / f"mnemo-{name}-macos.svg").write_text(build(v, inset=MACOS_INSET))
print("\n".join(sorted(p.name for p in out.glob("*.svg"))))
