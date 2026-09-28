#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
为 阅读M（MReader）的 M2b-T09 收官验收生成 FMT-01/02 的**代表性真实结构样本**。

产物目录：`tmp_book/`（仓库已 gitignore：`/tmp_book/` —— 「开发期真实书籍样本，
多格式测试用，不入库」）。因此本脚本产出的是**本地样本**，不随仓库分发。

与 `test/fixtures/make_fixtures.py` 同一纪律：**只依赖 Python 标准库、不联网**。
这里额外自造真结构 PDF（FlateDecode 内嵌位图 + Helvetica 文字层）与真结构 PNG，
不引 Pillow / reportlab —— 保证任何装 Python 的机器都能一键复现同样字节。

## 为什么叫「代表性样本」而非「真实出版物」

M2b-T09 的验收口径要求 FMT-01/02「各 3 个真实样本」。真实出版物受版权限制、
且本机全盘无 `.cbz`/`.cbr`（已扫 D 盘 / 下载目录 / 567Reader 参考工程）。经负责人拍板：
**由本脚本生成「代表性真实结构样本」**——文件本身是**合法可解析的真 PDF / 真 CBZ**，
覆盖现实世界里会遇到的格式特征（多页、混合页尺寸、图片页、文字层、自然序文件名、
混合大小写扩展名、`ComicInfo.xml` 元数据、`__MACOSX/` 垃圾项、大图页），
**但不是具体某本已出版书籍**。真实出版物样本仍以 `tmp_book/` 里已有的
（`小狗钱钱.pdf` / `王晋康作品选.epub` / TXT 等）为准，后续可持续补入。

## 产物清单（写死、确定性、可重复）

    fmt01_gen_scanned_pages.pdf   12 页 A4 竖版「扫描书」：整页位图 + 页脚文字层 → 伪分章 12/10 = 2 章
    fmt01_gen_mixed_layout.pdf     7 页混合版式：横竖版并存、页尺寸不一 → 校验渲染宽高比
    fmt02_gen_png_pages.cbz       12 页纯 PNG，page1..page12 → 校验自然序（page10 在 page2 之后）
    fmt02_gen_messy_meta.cbz       6 页混合大小写扩展名 + ComicInfo.xml + __MACOSX/ + Thumbs.db + 子目录
    fmt02_gen_large_pages.cbz      4 页大图（1000×1500）→ 校验大图页管线与内存
    fmt_gen_cjk_nav.epub           EPUB3 多章中文 + nav 目录 + 封面图
    fmt_gen_legacy_ncx.epub        EPUB2 多章中文 + toc.ncx 目录
    fmt_gen_flat_titles.epub       无 nav（仅 spine 顺序）→ 校验 flatTitles 兜底取标题
    fmt_gen_utf8_volumes.txt       UTF-8「第一卷 / 第N章」多章
    fmt_gen_gbk_chapters.txt       GBK 编码「第N章」多章（编码探测链）
    fmt_gen_big_chapter.txt        单章超长正文（触发超长章节自动拆分）

> 说明：FMT-01/02 是 T09 的**新格式**要求（各 3 个）；EPUB/TXT 的 3 个代表性样本是
> 为让 §17 M2 判定第 1 条「四类格式各 ≥3 个样本」整齐成立而**补充**的（真实出版物
> 样本仍以 tmp_book/ 里已有的为准）。不需要时可整组删除，不影响任何既有测试。

运行：
    python tool/gen_real_samples.py            # 生成到 tmp_book/
    python tool/gen_real_samples.py --list     # 只列清单，不写文件
"""

import argparse
import os
import struct
import zlib
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT_DIR = os.path.join(ROOT, "tmp_book")


# ───────────────────────────── 位图（纯 stdlib RGB） ─────────────────────────────

def rgb_rows(width, height, top, bottom):
    """竖向渐变的一整幅 RGB 位图（每行同色 → 构造快、压缩率高）。"""
    buf = bytearray()
    span = max(1, height - 1)
    for y in range(height):
        t = y / span
        r = int(top[0] + (bottom[0] - top[0]) * t)
        g = int(top[1] + (bottom[1] - top[1]) * t)
        b = int(top[2] + (bottom[2] - top[2]) * t)
        buf += bytes((r, g, b)) * width
    return buf


def fill_rect(buf, width, height, x, y, w, h, color):
    """在 RGB 缓冲区上填一个矩形（越界自动裁剪）。"""
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(width, x + w), min(height, y + h)
    if x1 <= x0 or y1 <= y0:
        return
    row = bytes(color) * (x1 - x0)
    for yy in range(y0, y1):
        off = (yy * width + x0) * 3
        buf[off:off + len(row)] = row


def make_page_rgb(width, height, index, tint):
    """生成一页确定性位图：渐变底 + 若干「文字行」条带 + 页序号色块。"""
    top = (tint[0], tint[1], tint[2])
    bottom = (min(255, tint[0] + 40), min(255, tint[1] + 40), min(255, tint[2] + 40))
    buf = rgb_rows(width, height, top, bottom)
    # 模拟排版：左侧留白 + 若干横向「文字行」
    margin = max(8, width // 12)
    line_h = max(3, height // 60)
    gap = line_h * 2
    y = max(6, height // 12)
    line_i = 0
    while y + line_h < height - height // 8:
        # 每页行宽按 index 变化，让不同页不完全相同（避免压缩退化到同一串）
        line_w = width - 2 * margin - ((index * 7 + line_i * 13) % (width // 4))
        fill_rect(buf, width, height, margin, y, line_w, line_h, (32, 32, 40))
        y += line_h + gap
        line_i += 1
    # 底部一个「页序号」色块（不同页不同颜色，肉眼可辨）
    blk = max(10, width // 8)
    fill_rect(buf, width, height, margin, height - blk - 6, blk, blk,
              (60 + (index * 37) % 180, 60 + (index * 91) % 180, 60 + (index * 53) % 180))
    return bytes(buf)


def png_bytes(width, height, rgb):
    """把 RGB 字节编成合法 PNG（8-bit truecolor，逐行 filter=None）。"""
    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data
                + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF))

    stride = width * 3
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type 0 (None)
        raw += rgb[y * stride:(y + 1) * stride]
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
            + chunk(b"IEND", b""))


# ───────────────────────────── 真结构 PDF（纯 stdlib） ─────────────────────────────

def _pdf_escape(text):
    return text.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")


def build_pdf(path, pages):
    """
    pages: list[dict(w, h, iw, ih, rgb, text, font)]
    写出一份规范 PDF（Catalog / Pages / Page × N / 内嵌 DeviceRGB 图 + Helvetica 文字层）。
    对象编号：1 Catalog · 2 Pages · 3 Font · 4+ 每页 3 个（Page / Contents / Image）。
    """
    out = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offsets = {}

    def add(num, body):
        offsets[num] = len(out)
        out.extend(("%d 0 obj\n" % num).encode("latin-1"))
        out.extend(body)
        out.extend(b"\nendobj\n")

    n = len(pages)
    page_nums = [4 + i * 3 for i in range(n)]
    cont_nums = [5 + i * 3 for i in range(n)]
    img_nums = [6 + i * 3 for i in range(n)]

    add(1, b"<< /Type /Catalog /Pages 2 0 R >>")
    kids = " ".join("%d 0 R" % pn for pn in page_nums)
    add(2, ("<< /Type /Pages /Kids [ %s ] /Count %d >>" % (kids, n)).encode("latin-1"))
    add(3, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")

    for i, pg in enumerate(pages):
        pn, cn, imn = page_nums[i], cont_nums[i], img_nums[i]
        w, h = pg["w"], pg["h"]
        fs = pg.get("font", 14)
        text = _pdf_escape(pg["text"])
        ops = (
            "q %d 0 0 %d 0 0 cm /Im0 Do Q\n" % (w, h)
            + "BT /F1 %d Tf 24 %d Td (%s) Tj ET\n" % (fs, max(8, h - fs - 8), text)
        ).encode("latin-1")
        add(cn, b"<< /Length %d >>\nstream\n" % len(ops) + ops + b"\nendstream")

        comp = zlib.compress(pg["rgb"], 6)
        add(imn, ("<< /Type /XObject /Subtype /Image /Width %d /Height %d "
                  "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode "
                  "/Length %d >>\nstream\n" % (pg["iw"], pg["ih"], len(comp))).encode("latin-1")
            + comp + b"\nendstream")

        add(pn, ("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d] "
                 "/Resources << /XObject << /Im0 %d 0 R >> /Font << /F1 3 0 R >> >> "
                 "/Contents %d 0 R >>" % (w, h, imn, cn)).encode("latin-1"))

    maxnum = 3 + n * 3
    xref_pos = len(out)
    out.extend(("xref\n0 %d\n" % (maxnum + 1)).encode("latin-1"))
    out.extend(b"0000000000 65535 f \n")
    for num in range(1, maxnum + 1):
        out.extend(("%010d 00000 n \n" % offsets[num]).encode("latin-1"))
    out.extend(("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n"
                % (maxnum + 1, xref_pos)).encode("latin-1"))

    with open(path, "wb") as f:
        f.write(out)


def gen_pdf_scanned(path):
    """12 页 A4 竖版「扫描书」：整页位图 + 页脚文字层（供 CNT-06 搜索取文本）。"""
    pages = []
    for i in range(12):
        iw, ih = 300, 424  # ≈ A4 比例
        rgb = make_page_rgb(iw, ih, i, (24 + i * 6, 30 + i * 4, 44 + i * 3))
        pages.append({
            "w": 595, "h": 842, "iw": iw, "ih": ih, "rgb": rgb,
            "text": "MReader FMT-01 generated sample - page %d of 12" % (i + 1),
        })
    build_pdf(path, pages)
    return 12


def gen_pdf_mixed(path):
    """7 页混合版式：横竖版并存、页尺寸不一，校验渲染按页宽高比。"""
    specs = [
        (595, 842, 300, 424),   # A4 竖版
        (842, 595, 420, 297),   # A4 横版
        (612, 792, 306, 396),   # Letter 竖版
        (792, 612, 396, 306),   # Letter 横版
        (400, 600, 200, 300),   # 小开本
        (1000, 500, 500, 250),  # 超宽
        (500, 1000, 250, 500),  # 超高
    ]
    pages = []
    for i, (w, h, iw, ih) in enumerate(specs):
        rgb = make_page_rgb(iw, ih, i + 21, (200 - i * 12, 60 + i * 9, 90 + i * 6))
        pages.append({
            "w": w, "h": h, "iw": iw, "ih": ih, "rgb": rgb, "font": 12,
            "text": "mixed-layout page %d (%dx%d)" % (i + 1, w, h),
        })
    build_pdf(path, pages)
    return len(specs)


# ───────────────────────────── 真结构 CBZ（纯 stdlib zip + PNG） ─────────────────────────────

def gen_cbz_plain(path):
    """12 页纯 PNG，文件名 page1..page12（自然序：page10 必须排在 page2 之后）。"""
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        for i in range(12):
            rgb = make_page_rgb(320, 460, i, (40, 70 + i * 8, 140))
            zf.writestr("page%d.png" % (i + 1), png_bytes(320, 460, rgb))
    return 12


def gen_cbz_messy(path):
    """6 页混合大小写扩展名 + ComicInfo.xml + __MACOSX/ + Thumbs.db + 子目录。"""
    entries = []
    for i in range(6):
        name = ["P1.PNG", "p2.png", "page-3.PNG", "P_04.png", "p5.PNG", "p6.png"][i]
        rgb = make_page_rgb(300, 440, i + 50, (120, 40 + i * 10, 60 + i * 12))
        entries.append((name, png_bytes(300, 440, rgb)))
    # 元数据与垃圾项：必须被页表排除
    entries.append(("ComicInfo.xml",
                    b"<?xml version=\"1.0\"?>\n<ComicInfo><Title>MReader messy sample</Title>"
                    b"<PageCount>6</PageCount></ComicInfo>\n"))
    entries.append(("__MACOSX/._P1.PNG", b"\x00\x05\x16\x07not-a-real-resource-fork"))
    entries.append(("Thumbs.db", b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1fake-ole-thumbnail"))
    entries.append(("extras/notes.txt", b"this dir/file is not an image page\n"))
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, data in entries:
            zf.writestr(name, data)
    return 6


def gen_cbz_large(path):
    """4 页大图（1000×1500）→ 校验大图页管线与内存（PERF-02 非驻留）。"""
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        for i in range(4):
            rgb = make_page_rgb(1000, 1500, i + 90, (30, 110, 200 - i * 30))
            zf.writestr("large-%02d.png" % (i + 1), png_bytes(1000, 1500, rgb))
    return 4


# ───────────────────────────── 真结构 EPUB / TXT（纯 stdlib） ─────────────────────────────

EPUB_MIMETYPE = b"application/epub+zip"

CONTAINER_XML = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""


def _xhtml(title, body_paragraphs):
    body = "\n".join("    <p>%s</p>" % p for p in body_paragraphs)
    return ("""<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="zh">
  <head><meta charset="utf-8"/><title>%s</title></head>
  <body>
    <h1>%s</h1>
%s
  </body>
</html>
""" % (title, title, body)).encode("utf-8")


def build_epub(path, book_title, author, chapters, *, legacy_ncx=False, with_nav=True,
               cover_png=None):
    """写一份合法 EPUB。chapters: list[(title, [para, ...])]。"""
    entries = [("mimetype", EPUB_MIMETYPE), ("META-INF/container.xml",
                                             CONTAINER_XML.encode("utf-8"))]
    manifest = []
    spine = []
    nav_items = []
    for i, (ct, paras) in enumerate(chapters):
        cid = "ch%d" % (i + 1)
        entries.append(("OEBPS/ch%d.xhtml" % (i + 1), _xhtml(ct, paras)))
        manifest.append('<item id="%s" href="ch%d.xhtml" media-type="application/xhtml+xml"/>' % (cid, i + 1))
        spine.append('<itemref idref="%s"/>' % cid)
        nav_items.append('        <li><a href="ch%d.xhtml">%s</a></li>' % (i + 1, ct))

    if with_nav:
        manifest.append('<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>')
        nav_xhtml = ("""<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="zh">
  <head><meta charset="utf-8"/><title>目录</title></head>
  <body>
    <nav epub:type="toc" id="toc">
      <ol>
%s
      </ol>
    </nav>
  </body>
</html>
""" % "\n".join(nav_items)).encode("utf-8")
        entries.append(("OEBPS/nav.xhtml", nav_xhtml))

    if cover_png is not None:
        entries.append(("OEBPS/images/cover.png", cover_png))
        manifest.append('<item id="cover-img" href="images/cover.png" media-type="image/png"/>')

    if legacy_ncx:
        ncx_points = "\n".join(
            '    <navPoint id="np%d" playOrder="%d"><navLabel><text>%s</text></navLabel>'
            '<content src="ch%d.xhtml"/></navPoint>' % (i + 1, i + 1, ct, i + 1)
            for i, (ct, _) in enumerate(chapters))
        ncx = ('<?xml version="1.0" encoding="utf-8"?>\n'
               '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n'
               '  <head/><docTitle><text>%s</text></docTitle>\n  <navMap>\n%s\n  </navMap>\n</ncx>\n'
               % (book_title, ncx_points)).encode("utf-8")
        entries.append(("OEBPS/toc.ncx", ncx))
        manifest.append('<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>')

    opf_spine = ('<spine toc="ncx">' if legacy_ncx else "<spine>") + "\n    " + "\n    ".join(spine) + "\n  </spine>"
    opf = ("""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="zh">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">urn:uuid:mreader-gen-%s</dc:identifier>
    <dc:title>%s</dc:title>
    <dc:creator>%s</dc:creator>
    <dc:language>zh</dc:language>
  </metadata>
  <manifest>
    %s
  </manifest>
  %s
</package>
""" % (abs(hash(book_title)) % 10**8, book_title, author,
       "\n    ".join(manifest), opf_spine)).encode("utf-8")
    entries.append(("OEBPS/content.opf", opf))

    with zipfile.ZipFile(path, "w") as zf:
        for name, data in entries:
            # mimetype 必须第一个且 STORED（OCF 规范）
            if name == "mimetype":
                zf.writestr(zipfile.ZipInfo("mimetype"), data, zipfile.ZIP_STORED)
            else:
                zf.writestr(name, data, zipfile.ZIP_DEFLATED)
    return len(chapters)


def _cjk_paras(n, seed):
    words = ["夜色", "沉入", "山谷", "远处", "灯火", "明灭", "一如", "既往",
             "他", "握紧了", "拳头", "却又", "慢慢", "松开", "风", "穿过", "指缝"]
    out = []
    for i in range(n):
        parts = [words[(i * 3 + j + seed) % len(words)] for j in range(14)]
        out.append("".join(parts) + "。")
    return out


def gen_epub_cjk_nav(path):
    cover = png_bytes(240, 320, make_page_rgb(240, 320, 3, (60, 90, 150)))
    chs = [("第一章 夜行", _cjk_paras(6, 1)),
           ("第二章 旧灯", _cjk_paras(7, 2)),
           ("第三章 归途", _cjk_paras(5, 3))]
    return build_epub(path, "生成样本·夜行纪实", "MReader 样本生成器", chs, cover_png=cover)


def gen_epub_legacy_ncx(path):
    chs = [("卷一·起", _cjk_paras(5, 11)), ("卷一·承", _cjk_paras(6, 12)),
           ("卷二·转", _cjk_paras(5, 13)), ("卷二·合", _cjk_paras(6, 14))]
    return build_epub(path, "生成样本·旧制目录", "MReader 样本生成器", chs, legacy_ncx=True)


def gen_epub_flat_titles(path):
    chs = [("无目录页 A", _cjk_paras(4, 21)), ("无目录页 B", _cjk_paras(4, 22)),
           ("无目录页 C", _cjk_paras(4, 23))]
    return build_epub(path, "生成样本·无目录", "MReader 样本生成器", chs, with_nav=False)


def gen_txt_utf8_volumes(path):
    lines = ["生成样本·卷章体", ""]
    for v in (1, 2):
        lines.append("第%d卷 风起" % v)
        for c in range(1, 5):
            lines.append("第%d章 第%d节标题" % (v, c))
            # 每章正文 > 1000 字符：TXT 分章器把「与上一标题间隔 > 1000 字」才算正式章
            # （`_longGapChars`），间隔 < 100 字反被记为「疑似卷」而否决整条规则。
            lines.extend(_cjk_paras(40, v * 10 + c))
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    return 8


def gen_txt_gbk_chapters(path):
    lines = []
    for c in range(1, 7):
        lines.append("第%d章 GBK编码测试" % c)
        lines.extend(_cjk_paras(40, c))
    with open(path, "wb") as f:
        f.write(("\n".join(lines) + "\n").encode("gbk"))
    return 6


def gen_txt_big_chapter(path):
    paras = _cjk_paras(400, 77)  # 单章超长，触发超长章节自动拆分
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("生成样本·超长单章\n\n" + "\n".join(paras) + "\n")
    return 1


# ───────────────────────────────────── 主流程 ─────────────────────────────────────

PLAN = [
    ("fmt01_gen_scanned_pages.pdf", "FMT-01 PDF（12 页扫描书 · 整页图 + 文字层）", gen_pdf_scanned),
    ("fmt01_gen_mixed_layout.pdf", "FMT-01 PDF（7 页混合版式 · 页尺寸不一）", gen_pdf_mixed),
    ("fmt02_gen_png_pages.cbz", "FMT-02 CBZ（12 页纯 PNG · 自然序命名）", gen_cbz_plain),
    ("fmt02_gen_messy_meta.cbz", "FMT-02 CBZ（6 页 · 混大小写扩展名 + 元数据/垃圾项）", gen_cbz_messy),
    ("fmt02_gen_large_pages.cbz", "FMT-02 CBZ（4 页大图 1000×1500）", gen_cbz_large),
    ("fmt_gen_cjk_nav.epub", "EPUB3（3 章中文 + nav 目录 + 封面图）", gen_epub_cjk_nav),
    ("fmt_gen_legacy_ncx.epub", "EPUB2（4 章中文 + toc.ncx 目录）", gen_epub_legacy_ncx),
    ("fmt_gen_flat_titles.epub", "EPUB（3 章 · 无 nav，仅 spine 顺序）", gen_epub_flat_titles),
    ("fmt_gen_utf8_volumes.txt", "TXT（UTF-8 · 卷章体，2 卷 8 章）", gen_txt_utf8_volumes),
    ("fmt_gen_gbk_chapters.txt", "TXT（GBK 编码 · 6 章）", gen_txt_gbk_chapters),
    ("fmt_gen_big_chapter.txt", "TXT（单章超长，触发自动拆分）", gen_txt_big_chapter),
]


def main():
    ap = argparse.ArgumentParser(description="生成 M2b-T09 的 FMT-01/02 代表性真实结构样本")
    ap.add_argument("--list", action="store_true", help="只列清单，不写文件")
    args = ap.parse_args()

    print("输出目录：%s" % OUT_DIR)
    print("（注意：该目录已 gitignore，样本不入库）\n")
    if args.list:
        for name, desc, _ in PLAN:
            print("  %-32s %s" % (name, desc))
        return

    os.makedirs(OUT_DIR, exist_ok=True)
    for name, desc, fn in PLAN:
        path = os.path.join(OUT_DIR, name)
        pages = fn(path)
        size = os.path.getsize(path)
        print("  已生成 %-32s %-52s 页数=%-3d 字节=%d" % (name, desc, pages, size))
    print("\n完成。真实出版物样本请另行放入 tmp_book/（如已有的 小狗钱钱.pdf）。")


if __name__ == "__main__":
    main()
