#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
为 阅读M（MReader）的 EPUB 解析层（lib/epub/*.dart）生成一批“现实脏 EPUB”测试样本。

设计原则
--------
* 每个 fixture 只聚焦一类脏特征，便于把解析层的失败精确定位到某一步。
* 每个 fixture 都附一份“规范上正确的预期输出”（baseline），作为人工推演的对照基线。
* 只依赖 Python 标准库（zipfile），不联网。

运行：
    python make_fixtures.py
产物：
    ./fx_*.epub      （测试样本）
    ./baseline.json  （每个样本的预期结构与逐字节判定）
"""

import io
import json
import os
import zipfile
from collections import OrderedDict

HERE = os.path.dirname(os.path.abspath(__file__))

EPUB_MIMETYPE = b"application/epub+zip"


def write_epub(path, entries):
    """entries: list[(name, bytes)]，按给定顺序写入；mimetype 自动置顶且 STORED。"""
    # mimetype 必须是第一个条目且不压缩（EPUB OCF 规范）。这里显式保证。
    ordered = []
    if not any(n == "mimetype" for n, _ in entries):
        ordered.append(("mimetype", EPUB_MIMETYPE))
    ordered.extend(entries)

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, data in ordered:
            if name == "mimetype":
                zi = zipfile.ZipInfo("mimetype")
                zi.compress_type = zipfile.ZIP_STORED
                zf.writestr(zi, data)
            else:
                zf.writestr(name, data)
    with open(path, "wb") as f:
        f.write(buf.getvalue())
    return path


def container(opf_full_path, encoding="UTF-8"):
    return (
        '<?xml version="1.0" encoding="%s"?>'
        '<container version="1.0" '
        'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        "<rootfiles>"
        '<rootfile full-path="%s" media-type="application/oebps-package+xml"/>'
        "</rootfiles></container>" % (encoding, opf_full_path)
    ).encode("utf-8")


def opf(title, author, lang, manifest, spine, encoding="UTF-8"):
    return (
        '<?xml version="1.0" encoding="%s"?>'
        '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" '
        'unique-identifier="uid">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        "<dc:title>%s</dc:title>"
        "<dc:creator>%s</dc:creator>"
        "<dc:language>%s</dc:language>"
        "</metadata>"
        "<manifest>%s</manifest>"
        "<spine>%s</spine>"
        "</package>" % (encoding, title, author, lang, manifest, spine)
    ).encode("utf-8")


def item(id_, href, media_type):
    return '<item id="%s" href="%s" media-type="%s"/>' % (id_, href, media_type)


def itemref(idref, linear=None):
    if linear is None:
        return '<itemref idref="%s"/>' % idref
    return '<itemref idref="%s" linear="%s"/>' % (idref, linear)


def xhtml(title, h1, paras, enc="UTF-8"):
    body = "".join("<p>%s</p>" % p for p in paras)
    return (
        '<html xmlns="http://www.w3.org/1999/xhtml">'
        "<head><title>%s</title></head>"
        "<body><h1>%s</h1>%s</body></html>" % (title, h1, body)
    ).encode(enc)


BASE = OrderedDict()   # 文件名 -> 预期 baseline

# ---------------------------------------------------------------------------
# f01：OPF 不在标准位置（放在 item/standard.opf，而非 OEBPS/content.opf）
# ---------------------------------------------------------------------------
def fx01():
    name = "fx01_opf_in_item_dir.epub"
    m = item("c1", "text/ch1.xhtml", "application/xhtml+xml")
    s = itemref("c1")
    entries = [
        ("META-INF/container.xml", container("item/standard.opf")),
        ("item/standard.opf", opf("标准外置OPF", "作者甲", "zh", m, s)),
        ("item/text/ch1.xhtml",
         xhtml("第一章 起", "第一章", ["OPF 放在 item 目录。", "第二段。"])),
    ]
    write_epub(os.path.join(HERE, name), entries)
    BASE[name] = {
        "脏特征": "OPF 位于非标准的 item/standard.opf",
        "预期书名": "标准外置OPF",
        "预期作者": "作者甲",
        "预期章节(href)": ["item/text/ch1.xhtml"],
        "预期每章文本": {"item/text/ch1.xhtml": ["第一章", "OPF 放在 item 目录。", "第二段。"]},
        "预期章标题": {"item/text/ch1.xhtml": "第一章"},
        "预期结果": "正常打开",
    }


# ---------------------------------------------------------------------------
# f02a：文件名为真实中文，OPF href 为百分号编码（最常见且“合规”的写法）
# ---------------------------------------------------------------------------
def fx02a():
    name = "fx02a_percent_href_real_cjk_name.epub"
    m = item("c1", "%E7%AC%AC%E4%B8%80%E7%AB%A0.xhtml", "application/xhtml+xml")
    s = itemref("c1")
    entries = [
        ("META-INF/container.xml", container("OEBPS/content.opf")),
        ("OEBPS/content.opf", opf("百分号href_真实中文名", "作者乙", "zh", m, s)),
        ("OEBPS/第一章.xhtml",
         xhtml("第一章 起", "第一章", ["href 是 %E7%AC%AC…，文件名是中文。"])),
    ]
    write_epub(os.path.join(HERE, name), entries)
    BASE[name] = {
        "脏特征": "OPF 的 href 百分号编码，但 zip 内文件名是真实中文",
        "预期书名": "百分号href_真实中文名",
        "预期章节(href)": ["OEBPS/第一章.xhtml"],
        "预期每章文本": {"OEBPS/第一章.xhtml": ["第一章", "href 是 %E7%AC%AC…，文件名是中文。"]},
        "预期结果": "正常打开",
    }


# ---------------------------------------------------------------------------
# f02b：zip 内部文件名本身就是百分号编码（少见但存在）
# ---------------------------------------------------------------------------
def fx02b():
    name = "fx02b_percent_zip_entry_name.epub"
    m = item("c1", "%E7%AC%AC%E4%B8%80%E7%AB%A0.xhtml", "application/xhtml+xml")
    s = itemref("c1")
    entries = [
        ("META-INF/container.xml", container("OEBPS/content.opf")),
        ("OEBPS/content.opf", opf("百分号zip内文件名", "作者丙", "zh", m, s)),
        ("OEBPS/%E7%AC%AC%E4%B8%80%E7%AB%A0.xhtml",
         xhtml("第一章 起", "第一章", ["zip 内的文件名本身就是 %E7%AC%AC…。"])),
    ]
    write_epub(os.path.join(HERE, name), entries)
    BASE[name] = {
        "脏特征": "zip 条目名本身就是百分号编码（href 也是）",
        "预期书名": "百分号zip内文件名",
        "预期章节(href)": ["OEBPS/第一章.xhtml"],
        "预期每章文本": {"OEBPS/第一章.xhtml": ["第一章", "zip 内的文件名本身就是 %E7%AC%AC…。"]},
        "预期结果": "按规范应能打开（href 与条目名解码后一致）",
    }


# ---------------------------------------------------------------------------
# f03：container 声明 oebps/（小写），实际目录是 OEBPS/；且 manifest href 大小写也不一致
# ---------------------------------------------------------------------------
def fx03():
    name = "fx03_case_mismatch.epub"
    m = item("c1", "TEXT/CH1.XHTML", "application/xhtml+xml")
    s = itemref("c1")
    entries = [
        ("META-INF/container.xml", container("oebps/content.opf")),
        ("OEBPS/content.opf", opf("大小写不一致", "作者丁", "zh", m, s)),
        ("OEBPS/text/ch1.xhtml",
         xhtml("第一章 起", "第一章", ["container 写小写，实际大写目录。"])),
    ]
    write_epub(os.path.join(HERE, name), entries)
    BASE[name] = {
        "脏特征": "container/OPF/href 与真实路径大小写均不一致",
        "预期书名": "大小写不一致",
        "预期章节(href)": ["OEBPS/text/ch1.xhtml"],
        "预期每章文本": {"OEBPS/text/ch1.xhtml": ["第一章", "container 写小写，实际大写目录。"]},
        "预期结果": "正常打开（应做大小写不敏感匹配）",
    }


# ---------------------------------------------------------------------------
# f04：GBK 编码、且没有任何 encoding 声明
# ---------------------------------------------------------------------------
def fx04():
    name = "fx04_gbk_no_decl.epub"
    m = item("c1", "text/ch1.xhtml", "application/xhtml+xml")
    s = itemref("c1")
    raw = (
        '<html xmlns="http://www.w3.org/1999/xhtml">'
        "<head><title>第四章 起</title></head>"
        "<body><h1>第四章</h1>"
        "<p>这是 GBK 编码的中文正文，没有声明。</p>"
        "<p>第二段：中文标点，。！？</p>"
        "</body></html>"
    ).encode("gbk")
    entries = [
        ("META-INF/container.xml", container("OEBPS/content.opf")),
        ("OEBPS/content.opf", opf("GBK无声明", "作者戊", "zh", m, s)),
        ("OEBPS/text/ch1.xhtml", raw),
    ]
    write_epub(os.path.join(HERE, name), entries)
    BASE[name] = {
        "脏特征": "章节为 GBK 字节且无 encoding 声明",
        "预期书名": "GBK无声明",
        "预期章节(href)": ["OEBPS/text/ch1.xhtml"],
        "预期每章文本": {
            "OEBPS/text/ch1.xhtml": ["第四章", "这是 GBK 编码的中文正文，没有声明。", "第二段：中文标点，。！？"]
        },
        "预期结果": "正常打开且中文可读（应走 GBK 兜底）",
        "bytes_is_valid_utf8": raw.decode("utf-8", "replace"),  # 后面用脚本判定
    }


# ---------------------------------------------------------------------------
# f05：非法 XHTML（未闭合标签 + 裸 & + 未定义实体）
# ---------------------------------------------------------------------------
def fx05():
    name = "fx05_malformed_xhtml.epub"
    m = item("c1", "text/ch1.xhtml", "application/xhtml+xml")
    s = itemref("c1")
    raw = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
        "<h1>第五章 & 测试</h1>"
        "<p>Tom & Jerry & 未定义实体 &foo;</p>"
        "<p>未闭合的段落<div>第二段开始"
        "<p>第三段<br>换行"
        "</body></html>"
    ).encode("utf-8")
    entries = [
        ("META-INF/container.xml", container("OEBPS/content.opf")),
        ("OEBPS/content.opf", opf("非法XHTML", "作者己", "zh", m, s)),
        ("OEBPS/text/ch1.xhtml", raw),
    ]
    write_epub(os.path.join(HERE, name), entries)
    BASE[name] = {
        "脏特征": "未闭合标签 + 裸 & + 未定义实体 &foo;",
        "预期书名": "非法XHTML",
        "预期章节(href)": ["OEBPS/text/ch1.xhtml"],
        "预期每章文本": {
            "OEBPS/text/ch1.xhtml": ["第五章 & 测试", "Tom & Jerry & 未定义实体 &foo;", "未闭合的段落", "第二段开始", "第三段\n换行"]
        },
        "预期结果": "正常打开，不应抛异常（html 宽松解析或退化去标签）",
    }


# ---------------------------------------------------------------------------
# f06：linear="no" 的章节保留并标记（CNT-05；spine 顺序 c1, c2(no), c3）
# ---------------------------------------------------------------------------
def fx06():
    name = "fx06_linear_no.epub"
    m = (
        item("c1", "text/ch1.xhtml", "application/xhtml+xml")
        + item("c2", "text/ch2.xhtml", "application/xhtml+xml")
        + item("c3", "text/ch3.xhtml", "application/xhtml+xml")
    )
    s = itemref("c1") + itemref("c2", "no") + itemref("c3")
    entries = [
        ("META-INF/container.xml", container("OEBPS/content.opf")),
        ("OEBPS/content.opf", opf("linear_no跳过", "作者庚", "zh", m, s)),
        ("OEBPS/text/ch1.xhtml", xhtml("第一章 起", "第一章", ["第一段。"])),
        ("OEBPS/text/ch2.xhtml", xhtml("第二章 注释", "第二章", ["不应出现。"])),
        ("OEBPS/text/ch3.xhtml", xhtml("第三章 起", "第三章", ["第三段。"])),
    ]
    write_epub(os.path.join(HERE, name), entries)
    BASE[name] = {
        "脏特征": "第二章 linear=\"no\"",
        "预期书名": "linear_no跳过",
        "预期章节(href)": ["OEBPS/text/ch1.xhtml", "OEBPS/text/ch2.xhtml", "OEBPS/text/ch3.xhtml"],
        "预期每章文本": {
            "OEBPS/text/ch1.xhtml": ["第一章", "第一段。"],
            "OEBPS/text/ch3.xhtml": ["第三章", "第三段。"],
        },
        "预期结果": "正常打开，sections 数为 3；ch2 保留并标 linear=false，章节表标注（非主线）（CNT-05）",
    }


# ---------------------------------------------------------------------------
# f07a：封面图（media-type=image/png）出现在 spine 里，应被排除
# ---------------------------------------------------------------------------
PNG = bytes.fromhex(
    "89504E470D0A1A0A0000000D49484452000000010000000108060000001F15C489"
    "0000000A49444154789C6360000002000100FFFF03000006000557BFABD40000000049454E44AE426082"
)


def fx07a():
    name = "fx07a_cover_in_spine_with_media_type.epub"
    m = (
        item("c1", "text/ch1.xhtml", "application/xhtml+xml")
        + item("cover", "images/cover.png", "image/png")
        + item("c2", "text/ch2.xhtml", "application/xhtml+xml")
    )
    s = itemref("c1") + itemref("cover") + itemref("c2")
    entries = [
        ("META-INF/container.xml", container("OEBPS/content.opf")),
        ("OEBPS/content.opf", opf("封面在spine", "作者辛", "zh", m, s)),
        ("OEBPS/text/ch1.xhtml", xhtml("第一章 起", "第一章", ["正文一。"])),
        ("OEBPS/text/ch2.xhtml", xhtml("第二章 起", "第二章", ["正文二。"])),
        ("OEBPS/images/cover.png", PNG),
    ]
    write_epub(os.path.join(HERE, name), entries)
    BASE[name] = {
        "脏特征": "封面 png（media-type=image/png）位于 spine 中间",
        "预期书名": "封面在spine",
        "预期章节(href)": ["OEBPS/text/ch1.xhtml", "OEBPS/text/ch2.xhtml"],
        "预期每章文本": {
            "OEBPS/text/ch1.xhtml": ["第一章", "正文一。"],
            "OEBPS/text/ch2.xhtml": ["第二章", "正文二。"],
        },
        "预期结果": "封面被排除，sections 数为 2",
    }


# ---------------------------------------------------------------------------
# f07b：封面图在 spine 里，但 manifest 漏写 media-type（易被误当章节）
# ---------------------------------------------------------------------------
def fx07b():
    name = "fx07b_cover_in_spine_no_media_type.epub"
    m = (
        item("c1", "text/ch1.xhtml", "application/xhtml+xml")
        + '<item id="cover" href="images/cover.png"/>'          # 故意没有 media-type
        + item("c2", "text/ch2.xhtml", "application/xhtml+xml")
    )
    s = itemref("c1") + itemref("cover") + itemref("c2")
    entries = [
        ("META-INF/container.xml", container("OEBPS/content.opf")),
        ("OEBPS/content.opf", opf("封面无media-type", "作者壬", "zh", m, s)),
        ("OEBPS/text/ch1.xhtml", xhtml("第一章 起", "第一章", ["正文一。"])),
        ("OEBPS/text/ch2.xhtml", xhtml("第二章 起", "第二章", ["正文二。"])),
        ("OEBPS/images/cover.png", PNG),
    ]
    write_epub(os.path.join(HERE, name), entries)
    BASE[name] = {
        "脏特征": "封面 png 在 spine 里，但 manifest 漏写 media-type",
        "预期书名": "封面无media-type",
        "预期章节(href)": ["OEBPS/text/ch1.xhtml", "OEBPS/text/ch2.xhtml"],
        "预期每章文本": {
            "OEBPS/text/ch1.xhtml": ["第一章", "正文一。"],
            "OEBPS/text/ch2.xhtml": ["第二章", "正文二。"],
        },
        "预期结果": "理想情况：按扩展名/嗅探排除图片；至少不应把 PNG 当正文段落输出",
    }


# ---------------------------------------------------------------------------
# f08：空 spine（应给出可读错误，而不是崩溃/白屏）
# ---------------------------------------------------------------------------
def fx08():
    name = "fx08_empty_spine.epub"
    m = item("c1", "text/ch1.xhtml", "application/xhtml+xml")
    entries = [
        ("META-INF/container.xml", container("OEBPS/content.opf")),
        ("OEBPS/content.opf", opf("空spine", "作者癸", "zh", m, "")),
        ("OEBPS/text/ch1.xhtml", xhtml("第一章 起", "第一章", ["正文。"])),
    ]
    write_epub(os.path.join(HERE, name), entries)
    BASE[name] = {
        "脏特征": "spine 为空",
        "预期结果": "抛出可读的 EpubParseException（spine 为空…），不崩溃",
    }


# ---------------------------------------------------------------------------
# f08b：缺 container.xml
# ---------------------------------------------------------------------------
def fx08b():
    name = "fx08b_missing_container.epub"
    entries = [
        ("OEBPS/content.opf", opf("无container", "作者子", "zh", item("c1", "c1.xhtml", "application/xhtml+xml"), itemref("c1"))),
        ("OEBPS/c1.xhtml", xhtml("第一章 起", "第一章", ["正文。"])),
    ]
    write_epub(os.path.join(HERE, name), entries)
    BASE[name] = {
        "脏特征": "缺少 META-INF/container.xml",
        "预期结果": "抛出可读的 EpubParseException（缺少 container.xml…），不崩溃",
    }


# ---------------------------------------------------------------------------
# f09：声明 utf-8、实际 GBK（“声明与实际不符”探针）
# ---------------------------------------------------------------------------
def fx09():
    name = "fx09_declared_utf8_actual_gbk.epub"
    m = item("c1", "text/ch1.xhtml", "application/xhtml+xml")
    s = itemref("c1")
    raw = (
        '<html xmlns="http://www.w3.org/1999/xhtml">'
        '<head><meta charset="utf-8"/><title>第九章 起</title></head>'
        "<body><h1>第九章</h1>"
        "<p>声明是 utf-8，实际是 GBK，应当乱码。</p>"
        "</body></html>"
    ).encode("gbk")
    entries = [
        ("META-INF/container.xml", container("OEBPS/content.opf")),
        ("OEBPS/content.opf", opf("声明不符", "作者丑", "zh", m, s)),
        ("OEBPS/text/ch1.xhtml", raw),
    ]
    write_epub(os.path.join(HERE, name), entries)
    BASE[name] = {
        "脏特征": "章节声明 charset=utf-8，字节实为 GBK",
        "预期结果": "理想：识别为 GBK 正确解码；最低要求：不崩溃（可能乱码）",
    }


# ---------------------------------------------------------------------------
# f10：Big5 且无声明（文档声称会乱码的边界）
# ---------------------------------------------------------------------------
def fx10():
    name = "fx10_big5_no_decl.epub"
    m = item("c1", "text/ch1.xhtml", "application/xhtml+xml")
    s = itemref("c1")
    try:
        raw = (
            '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第十章</title></head>'
            "<body><h1>第十章</h1><p>這是 Big5 編碼的繁體中文。</p></body></html>"
        ).encode("big5")
    except Exception:
        raw = "big5 unavailable".encode("utf-8")
    entries = [
        ("META-INF/container.xml", container("OEBPS/content.opf")),
        ("OEBPS/content.opf", opf("Big5无声明", "作者寅", "zh", m, s)),
        ("OEBPS/text/ch1.xhtml", raw),
    ]
    write_epub(os.path.join(HERE, name), entries)
    BASE[name] = {
        "脏特征": "章节为 Big5 字节且无声明",
        "预期结果": "文档已声明会乱码（退化为 GBK 猜测）；不应崩溃",
    }


# ---------------------------------------------------------------------------
# f11：声明 charset=gbk，但字节里有非法 GBK（0xFF）——探针：decodeText 会不会抛
# ---------------------------------------------------------------------------
def fx11():
    name = "fx11_declared_gbk_invalid_bytes.epub"
    m = item("c1", "text/ch1.xhtml", "application/xhtml+xml")
    s = itemref("c1")
    raw = (
        b'<html xmlns="http://www.w3.org/1999/xhtml">'
        b'<head><meta charset="gbk"/><title>c11</title></head>'
        b"<body><h1>c11</h1><p>abc" + bytes([0xFF]) + b"def</p></body></html>"
    )
    entries = [
        ("META-INF/container.xml", container("OEBPS/content.opf")),
        ("OEBPS/content.opf", opf("声明GBK但字节非法", "作者卯", "zh", m, s)),
        ("OEBPS/text/ch1.xhtml", raw),
    ]
    write_epub(os.path.join(HERE, name), entries)
    BASE[name] = {
        "脏特征": "章节声明 charset=gbk，但字节含非法 GBK（0xFF）",
        "预期结果": "理想：不应抛异常（decodeText 承诺绝不抛）；最低：不崩溃",
    }


def main():
    for fn in (fx01, fx02a, fx02b, fx03, fx04, fx05, fx06, fx07a, fx07b,
               fx08, fx08b, fx09, fx10, fx11):
        fn()

    # 逐字节探针：判定 GBK 字节是否会被“严格 UTF-8”误判
    probes = {}
    for fn in sorted(os.listdir(HERE)):
        if not fn.endswith(".epub"):
            continue
        with zipfile.ZipFile(os.path.join(HERE, fn)) as zf:
            names = zf.namelist()
            data = {n: zf.read(n) for n in names}
        probes[fn] = {
            "zip_entries": names,
            "zip_declares_utf8_manifest": "META-INF/container.xml" in names,
        }
        # 对每个 xhtml 条目做 UTF-8 合法性判定
        for n, b in data.items():
            if n.lower().endswith((".xhtml", ".html", ".htm")):
                try:
                    b.decode("utf-8")
                    valid = True
                except UnicodeDecodeError:
                    valid = False
                probes[fn].setdefault("xhtml_utf8_valid", {})[n] = valid

    with open(os.path.join(HERE, "baseline.json"), "w", encoding="utf-8") as f:
        json.dump({"baseline": BASE, "probes": probes}, f,
                  ensure_ascii=False, indent=2)
    print("生成完毕：%d 个 fixture" % len(BASE))
    for k in BASE:
        print("  -", k)


if __name__ == "__main__":
    main()
