#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
独立复算 lib/epub 里那几个“关键算法”，用真实 fixture 字节核对解析结果。

⚠️ 这是 *模型*，不是 Dart 运行时。它只复算下面这些“纯字符串/纯字节”的确定性逻辑，
   这些逻辑的输入输出可以用 Python 逐字节精确重现：
     - epub_parser._normalizeZipPath
     - epub_parser._decodePercent   (≈ Uri.decodeComponent，按 UTF-8 解码，'+' 不当空格)
     - epub_parser._resolveHref     (≈ p.posix.join + normalize)
     - epub_parser._lookup          (原路径 / 解码后路径 / 大小写回退)
     - epub_parser._looksTextual
     - text_codec.decodeText        (BOM → 声明 → 严格UTF-8 → GBK → latin1)
   段落切分（section_extractor）依赖 html5 解析器建 DOM，Python 无同款解析器，
   因此本脚本不对其建模，改为人工推演（见报告）。
"""

import os
import posixpath
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))

# --------------------------------------------------------------------------- #
# 1) 复算 epub_parser.dart 的路径工具
# --------------------------------------------------------------------------- #
def normalize_zip_path(raw):                      # epub_parser.dart:174
    s = raw.replace("\\", "/")
    while s.startswith("./"):
        s = s[2:]
    while s.startswith("/"):
        s = s[1:]
    s = re.sub(r"/+", "/", s)
    if s.endswith("/"):
        s = s[:-1]
    return s


def decode_percent(value):                        # epub_parser.dart:191
    if "%" not in value:
        return value
    try:
        return urllib_unquote(value)
    except Exception:
        return value


def urllib_unquote(v):
    import urllib.parse
    # errors='strict' 时非法 UTF-8 会抛异常 —— 对齐 Uri.decodeComponent 的“畸形转义抛错过”
    return urllib.parse.unquote(v, encoding="utf-8", errors="strict")


def resolve_href(base_dir, href):                 # epub_parser.dart:201
    h = href.strip()
    if "#" in h:
        h = h[: h.index("#")]
    if "?" in h:
        h = h[: h.index("?")]
    h = decode_percent(h).replace("\\", "/")
    if h == "":
        return ""
    joined = h if (base_dir == "" or base_dir == ".") else posixpath.join(base_dir, h)
    return posixpath.normpath(joined)


def lookup(files, lower_index, path):             # epub_parser.dart:220
    cands = []
    for c in (normalize_zip_path(path), normalize_zip_path(decode_percent(path))):
        if c and c not in cands:
            cands.append(c)
    hit = None
    for c in cands:
        if c == "":
            continue
        if c in files:
            return c, "exact"
        li = lower_index.get(c.lower())
        if li is not None:
            return li, "casefold"
    return None, None


def looks_textual(mt):                            # epub_parser.dart:271
    if mt is None or mt == "":
        return True
    m = mt.lower()
    if m.startswith("image/") or m.startswith("audio/") or m.startswith("video/"):
        return False
    for k in ("css", "font", "javascript"):
        if k in m:
            return False
    return True


# --------------------------------------------------------------------------- #
# 2) 复算 text_codec.dart 的兜底分支（返回命中的分支名）
# --------------------------------------------------------------------------- #
def has_utf8_bom(b):
    return len(b) >= 3 and b[0] == 0xEF and b[1] == 0xBB and b[2] == 0xBF


def has_utf16_bom(b):
    return len(b) >= 2 and (
        (b[0] == 0xFF and b[1] == 0xFE) or (b[0] == 0xFE and b[1] == 0xFF)
    )


DECL_RE = re.compile(r"(?:encoding|charset)\s*=\s*[\"']?\s*([A-Za-z0-9_\-]+)", re.I)


def detect_declared(b):
    head = b[:1024] if len(b) > 1024 else b
    text = head.decode("latin-1", "replace")
    m = DECL_RE.search(text)
    return m.group(1).lower() if m else None


def gbk_decodable(b):
    try:
        b.decode("gbk")
        return True
    except Exception:
        return False


def decode_text_branch(b):
    """返回 (分支名, 结果形态)。分支名对应 text_codec.dart 的判定顺序。"""
    if len(b) == 0:
        return "empty", ""
    if has_utf8_bom(b):                            # :20
        return "utf8-bom", _safe(b[3:].decode("utf-8", "replace"))
    if has_utf16_bom(b):                           # :23
        return "utf16-bom", "utf16 解码"
    declared = detect_declared(b)                  # :27
    if declared is not None:
        if declared in ("utf-8", "utf8"):
            return "declared=utf-8(allowMalformed)", _safe(b.decode("utf-8", "replace"))
        if declared in ("gbk", "gb2312", "gb-2312", "gb18030", "x-gbk"):
            if gbk_decodable(b):
                return "declared=gbk", _safe(b.decode("gbk"))
            return "declared=gbk->抛FormatException(!)", ""
        if declared in ("utf-16", "utf16", "utf-16le", "utf-16be"):
            return "declared=utf-16", "utf16 解码"
        if declared in ("latin1", "latin-1", "iso-8859-1", "ascii", "us-ascii"):
            return "declared=latin1", _safe(b.decode("latin-1"))
        # 不认识的编码 -> 返回 null，继续往下兜底
    try:
        b.decode("utf-8")                          # :33 严格 UTF-8
        return "strict-utf8", _safe(b.decode("utf-8"))
    except UnicodeDecodeError:
        pass
    if gbk_decodable(b):                           # :37
        return "gbk", _safe(b.decode("gbk"))
    return "latin1", _safe(b.decode("latin-1"))    # :39


def _safe(s):
    return s


# --------------------------------------------------------------------------- #
# 3) 解析 OPF（按 localName 匹配，忽略命名空间，对齐 _findAll）
# --------------------------------------------------------------------------- #
def strip_ns(tag):
    return tag.split("}")[-1].lower()


def find_all_by_local(root, local):
    out = []
    for el in root.iter():
        if strip_ns(el.tag) == local:
            out.append(el)
    return out


def first_text_by_local(root, local):
    for el in find_all_by_local(root, local):
        txt = "".join(el.itertext())
        txt = re.sub(r"\s+", " ", txt).strip()
        if txt:
            return txt
    return ""


def analyze(path):
    with zipfile.ZipFile(path) as zf:
        entries = zf.namelist()
        raw = {n: zf.read(n) for n in entries}

    # 对齐 epub_parser 的 files / lowerIndex 构建（epub_parser.dart:43-51）
    files, lower_index = {}, {}
    for n in entries:
        nm = normalize_zip_path(n)
        if nm == "":
            continue
        files[nm] = raw[n]
        lower_index[nm.lower()] = nm

    report = {"zip_entries": entries}

    # container（epub_parser.dart:54）
    cpath, how = lookup(files, lower_index, "META-INF/container.xml")
    if cpath is None:
        report["result"] = "抛错：缺少 META-INF/container.xml"
        return report
    report["container_lookup"] = (cpath, how)

    cdoc = ET.fromstring(raw[cpath].decode("utf-8", "replace"))
    opf_path = None
    for el in find_all_by_local(cdoc, "rootfile"):
        fp = el.get("full-path")
        if fp and fp.strip():
            opf_path = normalize_zip_path(fp)
            break
    if not opf_path:
        report["result"] = "抛错：container.xml 中没有 rootfile"
        return report
    report["opf_path_declared"] = opf_path

    opath, ohow = lookup(files, lower_index, opf_path)
    if opath is None:
        report["result"] = "抛错：OPF 不存在于包内: %s" % opf_path
        return report
    report["opf_lookup"] = (opath, ohow)

    opf_dir = posixpath.dirname(opf_path)          # epub_parser.dart:88（注意：用声明的 opfPath）
    report["opf_dir_for_href"] = opf_dir

    odoc = ET.fromstring(raw[opath].decode("utf-8", "replace"))
    report["title"] = first_text_by_local(odoc, "title")
    report["author"] = first_text_by_local(odoc, "creator")
    report["language"] = first_text_by_local(odoc, "language")

    id_href, id_mt = {}, {}
    for it in find_all_by_local(odoc, "item"):
        i = it.get("id")
        h = it.get("href")
        if not i or not h or not h.strip():
            continue
        id_href[i] = resolve_href(opf_dir, h)
        mt = it.get("media-type")
        if mt is not None:
            id_mt[i] = mt
    report["manifest"] = {k: {"resolved": v, "media_type": id_mt.get(k)} for k, v in id_href.items()}

    sections = []
    for ir in find_all_by_local(odoc, "itemref"):
        linear = ir.get("linear")
        if linear is not None and linear.lower() == "no":
            continue
        idref = ir.get("idref")
        if idref is None:
            continue
        href = id_href.get(idref)
        if href is None:
            continue
        if not looks_textual(id_mt.get(idref)):
            continue
        hit, how2 = lookup(files, lower_index, href)
        entry = {
            "idref": idref,
            "resolved_href": href,
            "lookup": (hit, how2),
            "included": hit is not None,
        }
        if hit is not None:
            entry["decode_branch"], entry["decoded_preview"] = decode_text_branch(raw[hit])
        sections.append(entry)

    report["sections"] = sections
    effective = [s for s in sections if s["included"]]
    report["section_count"] = len(sections)                 # spine 里通过的条目数（含未命中资源的）
    report["effective_sections"] = len(effective)           # 实际会被 add 进 sections 的数量
    report["effective_hrefs"] = [s["lookup"][0] for s in effective]
    if not effective:
        report["result"] = "抛错：spine 为空（找不到任何可阅读的章节）"
    else:
        report["result"] = "OK"
    return report


def main():
    files = sorted(f for f in os.listdir(HERE) if f.endswith(".epub"))
    for f in files:
        print("=" * 78)
        print(f)
        rep = analyze(os.path.join(HERE, f))
        for k in ("zip_entries", "container_lookup", "opf_path_declared", "opf_lookup",
                  "opf_dir_for_href", "title", "author", "language", "manifest",
                  "section_count", "effective_sections", "effective_hrefs", "result"):
            if k in rep:
                print("  %-18s %s" % (k + ":", rep[k]))
        for s in rep.get("sections", []):
            print("  section %-6s href=%-28s lookup=%-30s branch=%s" % (
                s["idref"], s["resolved_href"], str(s["lookup"]),
                s.get("decode_branch", "-")))
            if s.get("decoded_preview"):
                prev = s["decoded_preview"].replace("\n", " ")
                print("        preview: %s" % prev[:120])


if __name__ == "__main__":
    main()
