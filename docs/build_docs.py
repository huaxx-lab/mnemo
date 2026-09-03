#!/usr/bin/env python3
"""从 *.md 生成可发布的 HTML。单一内容源，改 markdown 重跑即可，两边不会发散。"""
import html, pathlib, re, sys

HERE = pathlib.Path(__file__).resolve().parent
DOCS = {"prd": "Mnemo 新版本 PRD", "design": "Mnemo 技术设计",
        "test-strategy": "Mnemo 测试策略",
        "tasks": "Mnemo 开发计划",
        "dev": "Mnemo 开发文档", "test-record": "Mnemo 测试记录"}
PILL = re.compile(r"\[(P[012])\]")


def pill(m):
    p = m.group(1)
    return f'<span class="pri {p.lower()}">{p}</span>'


def inline(s):
    s = html.escape(s)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    return s


def convert(md):
    out, toc, lines, i, seen = [], [], md.split("\n"), 0, {}
    while i < len(lines):
        ln = lines[i]

        # 代码围栏：mermaid 走原生渲染，其余按代码块
        if ln.startswith("```"):
            lang = ln[3:].strip()
            i += 1
            buf = []
            while i < len(lines) and not lines[i].startswith("```"):
                buf.append(lines[i]); i += 1
            i += 1
            cls = "mermaid" if lang == "mermaid" else "code"
            out.append(f'<pre class="{cls}">{html.escape(chr(10).join(buf))}</pre>')
            continue

        # 表格
        if ln.startswith("|") and i + 1 < len(lines) and set(lines[i + 1]) <= set("|- :"):
            head = [c.strip() for c in ln.strip("|").split("|")]
            i += 2
            body = []
            while i < len(lines) and lines[i].startswith("|"):
                body.append([c.strip() for c in lines[i].strip("|").split("|")])
                i += 1
            th = "".join(f"<th>{inline(c)}</th>" for c in head)
            tr = "".join("<tr>" + "".join(f"<td>{PILL.sub(pill, inline(c))}</td>" for c in r) + "</tr>"
                        for r in body)
            cls = "tw ids" if head and head[0] in ("编号", "#", "ID") else "tw"
            out.append(f'<div class="{cls}"><table><thead><tr>{th}</tr></thead><tbody>{tr}</tbody></table></div>')
            continue

        # 列表
        if re.match(r"^\s*[-*] ", ln) or re.match(r"^\s*\d+\. ", ln):
            tag = "ul" if re.match(r"^\s*[-*] ", ln) else "ol"
            items = []
            while i < len(lines) and (re.match(r"^\s*[-*] ", lines[i]) or re.match(r"^\s*\d+\. ", lines[i])):
                items.append(PILL.sub(pill, inline(re.sub(r"^\s*(?:[-*]|\d+\.) ", "", lines[i]))))
                i += 1
            out.append(f"<{tag}>" + "".join(f"<li>{t}</li>" for t in items) + f"</{tag}>")
            continue

        # 标题
        m = re.match(r"^(#{1,4}) (.+)$", ln)
        if m:
            lvl, text = len(m.group(1)), m.group(2)
            if lvl == 1:
                out.append(f"<h1>{inline(text)}</h1>")
            else:
                base = re.sub(r"[^\w一-鿿]+", "-", PILL.sub("", text)).strip("-").lower() or "s"
                seen[base] = seen.get(base, 0) + 1
                sid = base if seen[base] == 1 else f"{base}-{seen[base]}"
                out.append(f'<h{lvl} id="{sid}">{PILL.sub(pill, inline(text))}</h{lvl}>')
                if lvl in (2, 3):
                    toc.append((lvl, sid, PILL.sub("", text).strip()))
            i += 1
            continue

        if ln.strip() == "---":
            out.append("<hr>"); i += 1; continue

        if ln.strip():
            m = re.match(r"^\*\*(目标|非目标)\*\*：(.+)$", ln)
            if m:
                kind = "goal" if m.group(1) == "目标" else "nongoal"
                out.append(f'<p class="callout {kind}"><span class="ck">{m.group(1)}</span>{inline(m.group(2))}</p>')
            else:
                out.append(f"<p>{inline(ln)}</p>")
        i += 1
    return "\n".join(out), toc


tpl = (HERE / "doc.tpl.html").read_text()
for stem in (sys.argv[1:] or DOCS):
    src = HERE / f"{stem}.md"
    if not src.exists():
        print(f"跳过 {stem}.md（不存在）"); continue
    body, toc = convert(src.read_text())
    nav = "\n".join(f'<a class="l{l}" href="#{s}">{html.escape(t)}</a>' for l, s, t in toc)
    dst = HERE / f"{stem}.html"
    dst.write_text(tpl.replace("__TITLE__", DOCS[stem]).replace("__NAV__", nav).replace("__BODY__", body))
    print(f"{dst.name}  {dst.stat().st_size/1024:.0f} KB  ·  {len(toc)} 个目录项")
