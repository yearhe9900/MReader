# MOBI/AZW3 原型基线（M2b-T05，PRD §15.6.3 阈值 1 + Q25）

> 本文件记录 `tool/mobi_probe.dart`（`9661ba9`）在**真实样本**上的原型探测结果：
> 回答四件事——PDB 容器头可读性、EXTH 关键 record、Huff/CDIC 最小解压可行性、**KF8 入口结论（Q25）**；
> 并给出 PRD §15.6.3 阈值 1 的对照口径耗时（下界）。
> 复现：`dart run tool/mobi_probe.dart`（自动扫 `tmp_book/` 下 `*.mobi *.azw3 *.azw`）或带文件参数。

## 1. 结论（TL;DR）

### 1.1 Q25 —— KF8 入口与结构（两真实样本实证）

| 争点 | 实测结论 |
|---|---|
| **KF8 结构在哪** | **同文件尾部**（PDB records）里的 **FDST / SKEL / FRAG / GUIDE（INDX 系）**结构——两样本 FDST 魔数 `"FDST"`、SKEL/FRAG/GUIDE 魔数 `"INDX"` + TAGX/IDXT 全部实测命中 |
| **入口怎么走** | **双分支都成立**：`version>=8` 直入 record 0（azw3 样本 HIT）；否则查 **EXTH 121 boundary** 跳转到边界 record 重读 MOBI 头（combo 样本 HIT，boundary=5281 处重读到 version=8 头）。判定顺序 = **先 version>=8 直入，miss 再走 EXTH 121** |
| **EXTH 129/131 偏移入口说** | **NOT SUPPORTED**——129 两样本都是 `kindle:embed:NNNN` 封面 URI 字符串（非偏移）；131 一个 = 1（可当 record 索引但无 FDST/SKEL/FRAG 魔数佐证）、一个缺失。**KF8 实现不采信此说** |
| **combo 文件** | 真实存在：KF6 头 @record 0 + KF8 头 @EXTH 121 boundary（`最强反派系统.mobi` 即是：active entry 切到 5281 后 version=8、fdst/frag/skel 字段才可读） |

### 1.2 耗时量级（阈值 1 对照，开发机 Windows x64 下界口径）

| 样本 | open（parse+build+首记录） | open(w/ read) | full（全书文本记录解压） | full(w/ read) |
|---|---|---|---|---|
| `最强反派系统.mobi`（24.4MB，PalmDOC-LZ77，active 4596 记录→18.8MB） | 0.1 / 0.2 / 0.4 ms | 12.1 ms | **161.7 / 164.6 / 177.3 ms** | **176.5 ms** |
| `牧神记.azw3`（24.1MB，无压缩，5783 记录→23.7MB） | 0.0 / 0.0 / 0.1 ms | 12.7 ms | 9.1 / 11.1 / 21.2 ms | 23.7 ms |

（min / median / max，timing x3；w/ read = 含 `file -> memory` 读入 12ms 级）

对照 PRD §15.6.3 阈值 1：

- **「打开 20MB AZW3 > 3s」** → 下界实测 `open(w/ read)` **12.7ms 量级**（不含 HTML 解析/排版），距 3s 阈值余量极大；
- **「单本解压 + 解析 > 2s」** → 下界实测 `full(w/ read)` **23.7ms（无压缩）/ 176.5ms（LZ77 最重）**（不含 HTML 清洗/切段），距 2s 阈值余量极大。

**一句话**：纯 Dart 自研解析链在 24MB 真实样本上，解压侧比阈值低 1~2 个数量级——阈值 1 的风险集中在**HTML 清洗/切段/排版**（未测），不在容器解析与解压。

### 1.3 四问四答

| 问 | 答 |
|---|---|
| PDB 容器头可读性 | ✅ 两样本 name/type/creator（`BOOK`/`MOBI`）/record 数/偏移表全读通（9901 / 5802 records） |
| EXTH 关键 record | ✅ 标题/作者/语言/封面/ASIN 等全出（见 §3 原始输出；`utf8Preview` 控制台下中文显 `.`，hex 侧可证 UTF-8） |
| Huff/CDIC 最小解压 | ⚠️ **代码路径就位但本批样本未覆盖**——两样本 compression = 2（PalmDOC-LZ77）/ 1（none），`huff build: skipped`。**须补 compression=17480 样本再验**（如实记录，不宣称已验证） |
| KF8 能力（Q25） | ✅ 见 §1.1：结构=同文件尾部 FDST/SKEL/FRAG(INDX)，入口=version≥8 直入 / EXTH 121 boundary 双分支，129/131 偏移说不成立 |

## 2. 方法（可复现）

### 2.1 测量口径（对齐 PRD §15.6.3 阈值 1 口径）

```
open = 解析 PDB/entry headers/EXTH + 构建 Huff（如适用）+ 首个文本记录试解
full = 上述 + 全部文本记录解压（active entry 的 numTextRecords 条）
w/ read = 上述 + file -> memory 读入（对照「打开」含 IO 的口径）
```

均为**下界口径**：`open` 不含 HTML 解析/排版；`full` 不含 HTML 清洗/切段。timing x3 取 min / median / max。

- 计量对象是 **active entry**（combo 文件 = KF8 头，`最强反派系统` 计 4596 条文本记录；单头文件 = record 0 头，`牧神记` 计 5783 条）；
- 文本记录解压前经 `stripTrailing` 按 trailingFlags 剥尾部附加字节（MOBI 规范尾部 flag 区）。

### 2.2 复现步骤

```bash
dart run tool/mobi_probe.dart            # 自动扫 tmp_book/ 下 *.mobi *.azw3 *.azw
dart run tool/mobi_probe.dart <文件>     # 或指定单文件
```

探针结构（`tool/mobi_probe.dart`，纯 Dart 直译 567Reader Kotlin 自研链）：
`PdbContainer`（PDB 偏移表/record 切片）→ `EntryHeaders`（PalmDOC 0..15 + MOBI + KF8 扩展字段）→
EXTH 明细 → **KF8 入口探测**（entry A version≥8 直入 / entry B EXTH 121 boundary 跳转）→
FDST/SKEL/FRAG/GUIDE 魔数实测 → EXTH 129/131 实测 → VERDICT 行 → `HuffCdic`/`lz77Decompress` 试解 → timing。
无样本时优雅降级 exit 0。

### 2.3 样本

| 样本 | 大小 | PDB records | 压缩 | 文本记录（active） | 解压后文本 | 形态 |
|---|---|---|---|---|---|---|
| `tmp_book/《最强反派系统》….mobi` | 24,404,252 B | 9901 | 2 PalmDOC-LZ77 | 4596（KF8 @5281；KF6 头自述 5271） | 18,822,382 B | **combo**（KF6 @0 + KF8 @EXTH 121 boundary=5281） |
| `tmp_book/《牧神记》….azw3` | 24,077,744 B | 5802 | 1 none | 5783 | 23,681,289 B | 纯 KF8（version=8 直入，无 EXTH 121） |

样本不入库（`tmp_book/` 本地真实书），数字随机器与负载波动，**看数量级**。

## 3. 原始输出（粘贴，勿手改）

```
======== tmp_book\-《最强反派系统》（校对版全本）作者：封七月.mobi (24404252 bytes) ========
[read] file -> memory: 11.9 ms
-- PDB container --
name      : "-AEQDQPFBCHPGOWDKNUXDM"
type      : "BOOK"  creator: "MOBI"
records   : 9901
record[0]  : off=79288 len=684
record[1]  : off=79972 len=1629
record[2]  : off=81601 len=1632
record[last=9900]: off=24404248 len=4
-- entry headers (record 0) --
palmdoc   : compression=2 (PalmDOC-LZ77) numTextRecords=5271 recordSize=4096 encryption=0
mobi      : version=6 type=2 encoding=65001 uid=2230530750 headerLen=264
title     : "-《最强反派系统》（校对版全本）作者：封七月" (titleOffset=616 titleLength=64)
structure : resourceStart(first-image,abs)=5275 huffcdic(rel)=0 numHuffcdic=0 indx(rel)=5272
kf8 fields: n/a (version<8，该区扩展字段不适用)
flags     : exthFlag=0x850 (exth=yes) trailingFlags=0x3
-- EXTH (21 records) --
[116] unknown : u32=181877 raw=[00 02 c6 75]
[106] published-date : u32=842019129 raw=[32 30 31 39]
[109] rights : str="Created with EasyPub v1.50" len=26 hex=[43 72 65 61 74 65 64 20 77 69 74 68 20 45 61 73]
[542] unknown : u32=1397970522 raw=[53 53 56 5a]
[524] language : str="zh-CN" len=5 hex=[7a 68 2d 43 4e]
[525] unknown : str="horizontal-lr" len=13 hex=[68 6f 72 69 7a 6f 6e 74 61 6c 2d 6c 72]
[129] coverURI(per Kotlin map) : str="kindle:embed:0002" len=17 hex=[6b 69 6e 64 6c 65 3a 65 6d 62 65 64 3a 30 30 30]
[131] unknown-131 : u32=1 raw=[00 00 00 01]
[204] creator-software : u32=200 raw=[00 00 00 c8]
[205] unknown : u32=2 raw=[00 00 00 02]
[206] unknown : u32=9 raw=[00 00 00 09]
[535] unknown : str="1029-0897292" len=12 hex=[31 30 32 39 2d 30 38 39 37 32 39 32]
[207] unknown : u32=0 raw=[00 00 00 00]
[547] unknown : str="I.n.M.e.m.o.r.y." len=16 hex=[49 00 6e 00 4d 00 65 00 6d 00 6f 00 72 00 79 00]
[125] num-resources : u32=3 raw=[00 00 00 03]
[201] cover-offset : u32=0 raw=[00 00 00 00]
[203] unknown : u32=0 raw=[00 00 00 00]
[202] thumbnail-offset : u32=2 raw=[00 00 00 02]
[121] kf8-boundary : u32=5281 raw=[00 00 14 a1]
[113] asin : str="B00MVUINPP" len=10 hex=[42 30 30 4d 56 55 49 4e 50 50]
[501] unknown : u32=1161973579 raw=[45 42 4f 4b]
key: title(503)="(none)" author(100)="(none)"
-- KF8 entry probe (Q25) --
entry A (version>=8 direct): version=6 -> miss
entry B (EXTH 121 boundary): boundary=5281
  re-read record 5281: version=8 fdst=4610 frag=4598 skel=4602 -> KF8 head OK
  -> combo file: KF6 head at record 0 + KF8 head at boundary 5281
active entry: record 5281 (boundary) version=8
FDST: index=4610 (abs=9891) [file tail] magic=FDST numEntries=2
  fdst[0]: start=0 end=18818953
  fdst[1]: start=18818953 end=18822382
SKEL: index=4602 (abs=9883) [file tail] magic=INDX hdrLen=192 type=0 numRecordsField=1 totalEntries=1509
  tagx="TAGX" idxt="IDXT"
FRAG: index=4598 (abs=9879) [file tail] magic=INDX hdrLen=192 type=0 numRecordsField=2 totalEntries=3041
  tagx="TAGX" idxt="IDXT"
GUIDE: index=4604 (abs=9885) [file tail] magic=INDX hdrLen=192 type=0 numRecordsField=1 totalEntries=2
  tagx="TAGX" idxt="IDXT"
resources : first-image-index(abs)=4610 -> 资源记录区间约 [4610, 9901)（同文件尾部 PDB records）
EXTH 129   : len=17 hex=[6b 69 6e 64 6c 65 3a 65 6d 62 65 64 3a 30 30 30 32] ascii="kindle:embed:0002"
  verdict: 字符串（kindle:… URI），非偏移入口
EXTH 131   : len=4 hex=[00 00 00 01] ascii="...."
  as u32=1 (recordCount=9901, textRecords=4596)
  as record index (base+1=abs 5282): head=[3c 3f 78 6d 6c f6 65 72 73 69 6f 6e] magic="<?xm"
  verdict: 单个 u32；可当 record 索引但无 FDST/SKEL/FRAG 魔数佐证
VERDICT   : KF8 structure = same-file trailing FDST/SKEL/FRAG (INDX) records; entry = EXTH 121 boundary @5281 (re-read head); EXTH 129/131 offset-entry hypothesis = NOT SUPPORTED
-- decompression trial --
huff build: skipped (compression=2 PalmDOC-LZ77)
trial     : textRecord[0] 1745B -> 4096B in 1.1 ms
head      : "<?xml version="1.0" encoding="utf-8" ?><!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd"><html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-CN"><hea"
-- timing x3 (threshold-1 baseline) --
open      : parse+build+firstRecord min=0.1 ms median=0.2 ms max=0.4 ms
open(w/ read): 12.1 ms  <- 对照「打开 20MB AZW3 > 3s」（下界：不含 HTML 解析/排版）
full      : parse+build+allRecords(4596) -> 18822382B decompressed min=161.7 ms median=164.6 ms max=177.3 ms
full(w/ read): 176.5 ms  <- 对照「单本解压 + 解析 > 2s」（下界：不含 HTML 清洗/切段）

======== tmp_book\《牧神记》（校对版全本）作者：宅猪 - 嘒彼小星.azw3 (24077744 bytes) ========
[read] file -> memory: 12.6 ms
-- PDB container --
name      : "epubor.com"
type      : "BOOK"  creator: "MOBI"
records   : 5802
record[0]  : off=46496 len=1024
record[1]  : off=47520 len=4097
record[2]  : off=51617 len=4097
record[last=5801]: off=24077740 len=4
-- entry headers (record 0) --
palmdoc   : compression=1 (none) numTextRecords=5783 recordSize=4096 encryption=0
mobi      : version=8 type=2 encoding=65001 uid=0 headerLen=264
title     : "《牧神记》（校对版全本）作者：宅猪" (titleOffset=696 titleLength=51)
structure : resourceStart(first-image,abs)=5796 huffcdic(rel)=0 numHuffcdic=0 indx(rel)=5793
kf8 fields: fdst=5798 (numFdst=2) frag=5784 skel=5788 guide=5790  [record 相对索引，基准=boundary]
flags     : exthFlag=0x50 (exth=yes) trailingFlags=0x1
-- EXTH (15 records) --
[129] coverURI(per Kotlin map) : str="kindle:embed:0001" len=17 hex=[6b 69 6e 64 6c 65 3a 65 6d 62 65 64 3a 30 30 30]
[201] cover-offset : u32=0 raw=[00 00 00 00]
[202] thumbnail-offset : u32=1 raw=[00 00 00 01]
[203] unknown : u32=0 raw=[00 00 00 00]
[16777217] unknown : str="eCore v0.9.12.751 [ http://www.epubor.com/ecore." len=54 hex=[65 43 6f 72 65 20 76 30 2e 39 2e 31 32 2e 37 35]
[16777218] unknown : u32=(1433171049, 1835103333) raw=[55 6c 74 69 6d 61 74 65]
[16777219] unknown : str="Epubor" len=6 hex=[45 70 75 62 6f 72]
[16777220] unknown : str="http://www.epubor.com" len=21 hex=[68 74 74 70 3a 2f 2f 77 77 77 2e 65 70 75 62 6f 72]
[501] unknown : u32=1161973579 raw=[45 42 4f 4b]
[100] author/creator : str="............" len=12 hex=[e5 98 92 e5 bd bc e5 b0 8f e6 98 9f]
[106] published-date : u32=842019129 raw=[32 30 31 39]
[103] description : str="................................................" len=78 hex=[e6 9b b4 e5 a4 9a e7 b2 be e6 a0 a1 e5 b0 8f e8]
[113] asin : str="B00XUCKM65" len=10 hex=[42 30 30 58 55 43 4b 4d 36 35]
[524] language : str="zh-CN" len=5 hex=[7a 68 2d 43 4e]
[503] updated-title : str="................................................" len=51 hex=[e3 80 8a e7 89 a7 e7 a5 9e e8 ae b0 e3 80 8b ef]
key: title(503)="..................................................." author(100)="............"
-- KF8 entry probe (Q25) --
entry A (version>=8 direct): version=8 -> HIT
entry B (EXTH 121 boundary): boundary=-1
  (EXTH 121 absent or -1 -> not a combo file)
active entry: record 0 version=8
FDST: index=5798 (abs=5798) [file tail] magic=FDST numEntries=2
  fdst[0]: start=0 end=23677859
  fdst[1]: start=23677859 end=23681288
SKEL: index=5788 (abs=5788) [file tail] magic=INDX hdrLen=192 type=0 numRecordsField=1 totalEntries=1836
  tagx="TAGX" idxt="IDXT"
FRAG: index=5784 (abs=5784) [file tail] magic=INDX hdrLen=192 type=0 numRecordsField=2 totalEntries=3683
  tagx="TAGX" idxt="IDXT"
GUIDE: index=5790 (abs=5790) [file tail] magic=INDX hdrLen=192 type=0 numRecordsField=1 totalEntries=2
  tagx="TAGX" idxt="IDXT"
resources : first-image-index(abs)=5796 -> 资源记录区间约 [5796, 5802)（同文件尾部 PDB records）
EXTH 129   : len=17 hex=[6b 69 6e 64 6c 65 3a 65 6d 62 65 64 3a 30 30 30 31] ascii="kindle:embed:0001"
  verdict: 字符串（kindle:… URI），非偏移入口
EXTH 131   : ABSENT -> 「偏移入口」不成立（无此 record）
VERDICT   : KF8 structure = same-file trailing FDST/SKEL/FRAG (INDX) records; entry = version>=8 direct; EXTH 129/131 offset-entry hypothesis = NOT SUPPORTED
-- decompression trial --
huff build: skipped (compression=1 none)
trial     : textRecord[0] 4097B -> 4096B in 0.0 ms
head      : "<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd"><html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-CN" lang="zh-CN">..<head><meta http"
-- timing x3 (threshold-1 baseline) --
open      : parse+build+firstRecord min=0.0 ms median=0.0 ms max=0.1 ms
open(w/ read): 12.7 ms  <- 对照「打开 20MB AZW3 > 3s」（下界：不含 HTML 解析/排版）
full      : parse+build+allRecords(5783) -> 23681289B decompressed min=9.1 ms median=11.1 ms max=21.2 ms
full(w/ read): 23.7 ms  <- 对照「单本解压 + 解析 > 2s」（下界：不含 HTML 清洗/切段）
```

> 控制台为 GBK 终端时 UTF-8 中文在 `str=` 预览里显 `.`，以 `hex=` 为准（如 author hex `e5 98 92 e5 bd bc e5 b0 8f e6 98 9f` = 「嘒彼小星」）。
> combo 样本的 entry headers dump 显示 record 0（KF6）头，而 timing 计量的是 **active entry**（KF8 @5281，4596 条）——两处 `numTextRecords` 不同属预期。

## 4. 已知边界（如实记录）

1. **Huff/CDIC 未实测**：本批两样本 compression ∈ {1, 2}，`HuffCdic` 构建与解压路径**代码就位但未被真实样本执行**。`mobi` 0.8.0 fork/pin 的 KF8 最小验证（`Q25`）已由本基线覆盖结构/入口侧；**解压侧须补 compression=17480（Huff/CDIC）样本**（如早期 KindleGen 产物）再宣称全验证。
2. **耗时为开发机（Windows x64）下界口径**：不含 HTML 清洗/切段/排版；**正式判定须在 Android 主力机复测**（PRD §15.6.3 阈值 1 以真机为准）。数字随机器与负载波动，看数量级。
3. **样本形态覆盖**：combo（KF6+KF8）与纯 KF8 各一，均中文 UTF-8（encoding=65001）、非加密（encryption=0）；**加密 MOBI 未覆盖**（对齐「加密文件明确拒绝」口径，实现时走拒绝出口）。
4. 探针为**原型基线工具**，不是 `lib/` 实现；M2b-T05 正式实现时以本文件的 Q25 结论为规格输入（KF8 入口判定顺序、129/131 不采信）。

## 5. 对 M2b-T05 实现的规格输入

1. **KF8 入口判定顺序**：先 `version>=8` 直入 record 0 头；miss 再读 EXTH 121 boundary record 重得 KF8 头（combo 文件的 active entry = boundary 处，文本记录相对基准随之切换）。
2. **KF8 结构解析**：`fdst/frag/skel/guide` 字段是 **record 相对索引（基准=boundary）**，指向同文件尾部 records；须验魔数（`FDST`/`INDX`+TAGX/IDXT）防坏文件。
3. **EXTH 129/131 不作偏移入口**：129 = 封面 `kindle:embed:` URI；131 语义未定、不依赖。
4. **解压三路**：1 none 直取（剥尾）/ 2 PalmDOC-LZ77（重叠拷贝语义逐字节保持）/ 17480 Huff/CDIC（位级解压 + 异常输入保护，**待真实样本验证**）。
5. **耗时预算**：容器解析+解压侧余量 1~2 个数量级，实现时性能重心放在 HTML 清洗/切段与章节切分。
