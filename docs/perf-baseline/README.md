# 性能基线（PERF-02 内存收敛 / PERF-03 分段渲染）

> 本目录记录 **M1-T07** 的「改前 / 改后」可复现性能数字。
> 样本由 `tool/gen_perf_fixtures.dart` 生成到**系统临时目录**，**不入库**（见 `.gitignore`）。

> **目录索引（该目录已被三批任务共用，先看这里）**
>
> | 文件 | 属于 | 口径 | 用途 |
> |---|---|---|---|
> | `README.md`（本文件） | M1-T07 / M2a | **内存 / 首屏墙钟**的 before / after | `PERF-02` 内存收敛、`PERF-03` 分段渲染、`PERF-01` 接线 |
> | `thresholds.md` | **M3.5-T02** | **门槛判定**（§H.1 计时协议 + §H.4 三段式） | `RUST-06` 先测后引：六项候选「上不上 Rust」结论（含「不上」也是交付物） |
> | `mobi.md` | M2b-T05 | 纯 Dart MOBI 原型探针下界 | 候选 1 基线（解析器属 M4，`thresholds.md` 直接引用） |
> | `search.md` | M2b-T04 | 阈值 4 早期基线（`tool/search_bench.dart`，3 轮） | `CNT-06` 搜索首屏 / 帧时间口径 |
> | `<YYYY-MM-DD>-<device>.json` | 各批 | §H.2 机读原始记录信封 | 每次实测留档，**人工 commit**（决定判定的是 `judging: true` 的那份，即 Android 主力机） |

## 1. 结论（TL;DR）

### 1.1 首屏（打开即用）

| 指标 | 改前 | 改后 | 变化 |
|---|---|---|---|
| **320 章 EPUB 首屏时间**（min / median，5 轮） | 123 / 144 ms | **45 / 60 ms** | **≈ −63% / −58%** |
| **320 章 EPUB 首屏后驻留 RSS** | 497.9 MB | **429.2 MB** | **≈ −69 MB** |
| **100 章大头 EPUB 首屏后驻留 RSS** | 585.0 MB | **427.3 MB** | **≈ −158 MB** |
| 20MB TXT / 单超长章 EPUB | — | — | 持平（TXT 路径本次未改） |

### 1.2 稳态（`PERF-02` ① 的真实口径：**读过的章不驻留**）

| 场景 | 改前 | 改后 |
|---|---|---|
| 打开 320 章 EPUB（80MB 图）后**再读完 50 章** | 497.9 → 497.9 MB（+0.0） | 429.2 → **429.8 MB（+0.6）** |
| 打开 100 章大头 EPUB（≈48MB 正文）后**再读完 100 章** | 585.0 → **562.5 MB** | 427.3 → **426.8 MB（−0.5）** |

一句话：**打开大书不再把整本条目（含图片 / 字体 / CSS）一次性解压常驻；且「读完一整本」也不会把内存顶回「全书大小」**——稳态内存只与**当前在视窗口**（阅读页 LRU ≤ 30 章）有关，与**累计读过的章数**无关。

> 说明：绝对 `rssMB` 含 Dart VM + JIT 基线（约 420 MB），且有轮间抖动，故**看差值 / 稳态增量**而非绝对值；
> 稳态增量（±1 MB 级）远比噪声幅度小，是这里最稳的信号。

## 2. 方法（可复现）

### 2.1 测量口径

在 **`BookSource` 层**测两件事：

```
① 首屏（默认）：load()（结构+元数据） → chapters()（章节表） → content(目标章 ±1)（首批正文）
② 稳态（readChapters=N）：首屏后再「顺序读完前 N 章」
```

为什么在这一层：纯 Dart、与 UI / FakeAsync 无关、可重复；阅读页的首屏正是「等这一组调用返回 + 首次布局」。

- **`minMs` / `medianMs`**：首屏整条链路的墙钟耗时（多轮取 min / 中位数）；
- **`rssMB` / `peakMB`**：`ProcessInfo.currentRss`（末轮首屏后）/ `ProcessInfo.maxRss`（进程峰值）；
- **`rssAfterReadMB`**：末轮「读完 N 章」后的 `currentRss`——**与 `rssMB` 之差**才是稳态口径；
- **一次进程只测一个样本**（避免跨样本 RSS 互相污染），并可多轮。

### 2.2 复现步骤

```bash
# 1) 生成样本（写到临时目录；参数见 tool/gen_perf_fixtures.dart）
dart run tool/gen_perf_fixtures.dart "$TMPDIR/mreader_perf"
#   big_20mb.txt       ~20.7MB / 800 章
#   big_320.epub       320 章 + 20×4MB 图片（解压后图片合计 80MB；zip 内因全零可压至极小）
#   big_bodies.epub    100 章 × ~480KB 正文（解压后 ≈48MB）
#   long_chapter.epub  单章 ≈12 万字符

# 2) 逐样本测量（一次进程一个样本）
dart run tool/perf_bench.dart "$TMPDIR/mreader_perf" big_20mb.txt       after 5 0
dart run tool/perf_bench.dart "$TMPDIR/mreader_perf" big_320.epub       after 5 50
dart run tool/perf_bench.dart "$TMPDIR/mreader_perf" long_chapter.epub  after 5 0
dart run tool/perf_bench.dart "$TMPDIR/mreader_perf" big_bodies.epub    after 3 100

# 3) 复现「改前」：把三个文件回到 M1-T07 之前（1bb5802），用同一组命令、标签换 before
git checkout 1bb5802 -- lib/epub/epub_parser.dart lib/epub/zip_paths.dart lib/model/epub_book.dart
#   ... 跑上面同一组命令，标签 before ...
git checkout HEAD -- lib/epub/epub_parser.dart lib/epub/zip_paths.dart lib/model/epub_book.dart
```

### 2.3 样本参数

| 样本 | 章数 | 单章段落 | 单段字符 | 非章节资源 | 解压后正文 | 解压后图片 |
|---|---|---|---|---|---|---|
| `big_20mb.txt` | 800 | 300 | — | — | ~20MB | — |
| `big_320.epub` | 320 | 12 | — | 20 × PNG(4MB) | ~200KB | **80 MB** |
| `big_bodies.epub` | 100 | 60 | 8000 | — | **≈48 MB** | — |
| `long_chapter.epub` | 1 | 1200 | 100 | — | ~12 万字符 | — |

图片用**全零字节**：zip 里压缩到几乎为零，但**解压后体积 = 4MB/张**。因此「是否预解压图片」
在文件体量上看不出来，在**驻留内存**上一目了然——正是 `PERF-02` ① 要抓的。

## 3. 原始输出（粘贴，勿手改）

**改前（`before`，`1bb5802`：`load()` 对所有条目 `contentOfArchiveFile` 预解压；`EpubSection` 持解压字节）**

```
BENCH[before] big_20mb.txt       chapters=800 iters=5 minMs=410  medianMs=503  rssMB=426.8 peakMB=626.9
BENCH[before] big_320.epub       chapters=320 iters=5 minMs=123  medianMs=144  rssMB=497.9 peakMB=618.0 readChapters=50  rssAfterReadMB=497.9
BENCH[before] long_chapter.epub  chapters=1   iters=5 minMs=19   medianMs=22   rssMB=419.2 peakMB=589.2
BENCH[before] big_bodies.epub    chapters=100 iters=3 minMs=4521 medianMs=4545 rssMB=585.0 peakMB=706.6 readChapters=100 rssAfterReadMB=562.5
```

**改后（`after`，M1-T07 收尾：结构解析只建条目名索引；正文 / 图片 / 封面候选**按需、非驻留**解压）**

```
BENCH[after]  big_20mb.txt       chapters=800 iters=5 minMs=403  medianMs=529  rssMB=364.3 peakMB=563.8
BENCH[after]  big_320.epub       chapters=320 iters=5 minMs=45   medianMs=60   rssMB=429.2 peakMB=588.5 readChapters=50  rssAfterReadMB=429.8
BENCH[after]  long_chapter.epub  chapters=1   iters=5 minMs=24   medianMs=28   rssMB=414.1 peakMB=589.7
BENCH[after]  big_bodies.epub    chapters=100 iters=3 minMs=4758 medianMs=4833 rssMB=427.3 peakMB=586.0 readChapters=100 rssAfterReadMB=426.8
```

> `big_bodies.epub` 首屏 ~4.5–4.8s 属**预期**：该样本**无目录**，`chapters()` 走「按 spine 生成平坦目录」
> 回退路径，需逐章取标题（改前 / 改后都一样，故不是本任务的回归）。
> 环境：Windows / Dart 3.12（`flutter test` 同款 SDK）。数字随机器与负载波动，**看改前 / 改后差值**即可。

## 4. 结构性证据（不依赖计时）

改后的内存收敛不是「调参调出来的」，而是结构上成立：

1. **只建条目名索引，不预解压**：`epub_parser.dart` 用 `Map<String, ArchiveFile> byName`
   （`ArchiveFile.content` 本身按需解压），替换了旧实现的 `Map<String, Uint8List> files`（逐条 `contentOfArchiveFile`）。
2. **正文按需、且**不驻留**：`EpubSection.lazy` 的 `rawBytes` **无缓存**（每次访问都重新加载，
   见 `test/perf` 的计数断言）；正文推迟到 `DartEpubSource.content(i)` 才读取。
3. **解压结果不留底**：`zip_paths.dart` 的 `lazyEntryLoader` **不用** `ArchiveFile.content`
   （其 `_content` 一次解压即**永久缓存**），而是从**压缩态字节**每次现解（STORE 原样 / DEFLATE 走 `inflateBuffer`）——
   故 `totalCharCount()` / `search()` 遍历全书后，已读章节会被 GC 回收。
4. **非章节资源（图 / 字 / CSS）永不进正文路径**：spine 解析用 `textualVerdict()`（仅凭
   `media-type` / 扩展名）判定，明确非文本**连解压都不做**；封面候选 `readEntry` 也改为按需解压。
5. **驻留有界**：阅读页正文由 `ChapterCache`（LRU，上限 `kMaxLoadedChapters = 30`）兜底，
   首帧仅等「目标章 ±1」，其余后台按「离当前章由近及远」逐批补齐（见 `test/perf/lazy_load_test.dart`）。
6. **isolate 可迁移**：`parseEpubStructure(bytes)` 产出**纯数据、无闭包**的结构，可跨 isolate
   （`compute()` / `IsolateRunner`）；`parseEpubResult` 才在**本 isolate**绑定 `loadBytes` / `readEntry` 闭包。

## 5. 相关测试

| 测试文件 | 断言 |
|---|---|
| `test/perf/lazy_load_test.dart` | 320 章首帧批次 ≤ 3；补齐后驻留 ≤ 30 且 < 总章数；含图片书窗口中心驻留 ≤ 30；LRU 小上界逐出；超长章逐段（>1000 段、>10 万字符、无单段整章）；**① 稳态**：`EpubSection.lazy` 每次访问都重新加载（无无界缓存，计数断言）+ 读完 100 章大头书后 RSS 增量 < 解压后正文总量的一半 |
| `test/task/isolate_runner_test.dart` | `Isolate.run` 薄封装：纯函数往返 + **debugName 取证**（任务确在独立 isolate 执行）；不可序列化入参 / 捕获闭包**明确失败、不静默**；`runWithFallback` 派发失败 / 远端意外 → 回落本 isolate 重跑，业务错误经信封原样冒出（M2a-T06） |
| `test/format/dart_epub_source_test.dart` | flatTitles 预取 5 条（M2a-T06b）：无目录书填充 / 有目录书不填充 / 空标题存 `''` 补占位 / tamper 注入值压过现场解压（验咨询）/ miss 回退现场取 |

## 6. 已知边界（本次未覆盖 / 后续）

- `PERF-02` 的**磁盘缓存**（`docs/进度表.md` 风险 2）仍待 M2；本任务只做「内存收敛」。
- `PERF-01` 的 **isolate 真正接线**已于 **M2a-T06** 交付（后台 `parseEpubStructureTask` + 主 isolate
  `bindEpubResult`，实测见 §7.1）；本 M1-T07 批次当时只交了 `parseEpubStructure`（纯数据）+
  `IsolateRunner`（当时为 `compute()` 薄封装）两块底座。
- **无目录大书的平坦目录取标题已闭环**（M2a-T06b，方案 a）：`flatTitles` 预取表入解析 isolate
  （仅 toc 为空时填充、非缓存解压字节即弃），`chapters()` 零解压；`big_bodies.epub` maxGap
  3996 → **194ms**（§7.2）。
- `tool/*` 与 `test/perf/*` 用纯 Dart `test()`（**非** `testWidgets`）：本项目已两次实证
  `testWidgets` 体内 `await` 真异步 IO 会挂死（FakeAsync 不排空微任务队列），故不在此复现。

## 7. M1 交付基线（`M1-T09`，供 M2a-T06 `PERF-01` before 对照）

| 样本 | 首屏时间（min / median） | 首屏后 RSS | 读完 N 章后 RSS | 说明 |
|---|---|---|---|---|
| `big_320.epub`（320 章 + 80MB 图） | 45 / 60 ms | 429.2 MB | 429.8 MB（读 50 章，+0.6） | 图片不常驻，稳态不随读章数增长 |
| `big_bodies.epub`（100 章 ≈48MB 正文） | 4758 / 4833 ms | 427.3 MB | 426.8 MB（读 100 章，−0.5） | 正文非驻留，读完全书 RSS 不回升 |
| `big_20mb.txt`（800 章 ≈20MB） | 403 / 529 ms | 364.3 MB | — | TXT 路径本次未改 |
| `long_chapter.epub`（单章 12 万字符） | 24 / 28 ms | 414.1 MB | — | 逐段渲染，无单段整章 |

> **M2a-T06（`PERF-01` compute 化）的 before 对照**：上表即为 before 数字（首屏 / RSS 口径）。
> **实测 after 与 `maxGapMs` 前后对照见 §7.1**。

**全量测试**：`flutter test` → **279 passed，1 failed**（`cover_store_test` #4：`dart:ui` 缩略图，已知不阻塞）。

### 7.1 M2a-T06（`PERF-01`）接线 before / after —— `maxGapMs` 口径

`maxGapMs` = 主 isolate 心跳（10ms 周期定时器）最大间隔，**含收尾间隔**（微任务链饿死定时器时
= 整段连续阻塞时长）≈「UI 最长连续无响应时长」，即 `PERF-01` 验收① 的可测代理。
before / after 均以同版本 `tool/perf_bench.dart`（5 轮、一次进程一样本）实测：

| 样本 | `maxGapMs` before | `maxGapMs` after | 变化 |
|---|---|---|---|
| `big_20mb.txt`（800 章 ≈20MB） | 994 | **27** | ≈ −97% |
| `big_320.epub`（320 章 + 80MB 图） | 475 | **130** | ≈ −73% |
| `long_chapter.epub`（单章 12 万字符） | 334 | **96** | ≈ −71% |
| `big_bodies.epub`（100 章 ≈48MB 正文，**无目录**） | 9348 | **3996** | ≈ −57%（仍 >1s，见结论 3） |

after 的首屏与内存（稳态口径不回归）：

| 样本 | 首屏 min / median | 首屏后 RSS | 读完 N 章后 RSS |
|---|---|---|---|
| `big_20mb.txt` | 380 / 410 ms | 408.7 MB | — |
| `big_320.epub` | 43 / 56 ms | 359.3 MB | 360.4 MB（读 50 章，+1.1） |
| `long_chapter.epub` | 30 / 32 ms | 341.8 MB | — |
| `big_bodies.epub` | 3835 / 3884 ms | 353.9 MB | 353.8 MB（读 100 章，−0.1） |

结论：

1. **解析移出主 isolate 生效**：EPUB `parseEpubStructureTask` 与 TXT 准备 / 解码
   （`_txtPrepareTask` / `_txtDecodeTask`）全部后台化后，`maxGapMs` 全线大幅下降
   （20MB TXT 994 → 27ms，图片大书 475 → 130ms）。
2. **稳态不回归**（`PERF-02` 口径）：读完 N 章后 RSS 不回升（+1.1 / −0.1 MB，噪声级）。
3. **残余项（已闭环，M2a-T06b）**：`big_bodies.epub`（无目录大书）当时仍有 **3996ms** 连续无响应——
   源头**不是解析**（已后台化），而是 `chapters()` 的「无目录平坦目录」回退（`RD-01` ④）：
   `_flatChapter` 逐章 `extractSection(section.rawBytes).title`（解压 + HTML 解析 × 章数）在
   主 isolate 同步跑（`lib/format/dart_epub_source.dart` `_flatChapter`）。处置已选
   （a）**平坦目录构建 isolate 化**：M2a-T06b 把取标题移入解析 isolate（`flatTitles` 预取表），
   `big_bodies` maxGap 3996 → **194ms**，`PERF-01` 验收①（「50MB 书打开期间 UI 无超 1 秒
   无响应」）**全样本达成**（实测见 §7.2）。

### 7.2 M2a-T06b（残余修复 `flatTitles`）—— §7.1 结论 3 闭环

同版本 `tool/perf_bench.dart`（5 轮、一次进程一样本，标签 `flat`）实测：

| 样本 | `maxGapMs` §7.1 after | `maxGapMs` T06b 后 | 变化 |
|---|---|---|---|
| `big_20mb.txt`（800 章 ≈20MB） | 27 | 29 | 持平（噪声级；TXT 路径未动） |
| `big_320.epub`（320 章 + 80MB 图，**无目录**） | 130 | **25** | ≈ −81% |
| `long_chapter.epub`（单章 12 万字符，**无目录**） | 96 | **45** | ≈ −53% |
| `big_bodies.epub`（100 章 ≈48MB 正文，**无目录**） | 3996 | **194** | ≈ −95% |

> 三个 EPUB 样本**全部无目录**（`tool/perf_fixtures.dart` 不产 nav / ncx），全走平坦目录
> 回退路径——改善面与修复面完全对齐（TXT 样本不动、持平即无回归）。

首屏与内存（稳态口径不回归）：

| 样本 | 首屏 min / median | 首屏后 RSS | 读完 N 章后 RSS |
|---|---|---|---|
| `big_20mb.txt` | 478 / 569 ms | 409.1 MB | — |
| `big_320.epub` | 70 / 84 ms | 379.7 MB | 380.9 MB（读 50 章，+1.2） |
| `long_chapter.epub` | 35 / 45 ms | 334.0 MB | — |
| `big_bodies.epub` | 5602 / 5757 ms | 354.2 MB | 354.3 MB（读 100 章，+0.1） |

结论：

1. **`PERF-01` 验收①达成**（「50MB 书打开期间 UI 无超 1 秒无响应」）：四样本 `maxGapMs`
   全线 <200ms；无目录大书 3996 → **194ms**，平坦目录取标题不再冻结主 isolate。
2. **稳态不回归**（`PERF-02` ①）：读完 N 章 RSS +1.2 / +0.1 MB（噪声级）——`flatTitles`
   只驻留 `href -> 标题` 字符串，提取过程字节即弃。
3. **首屏墙钟**：大书 min 3835 → 5602ms。总工作量未变（标题提取整体从 `chapters()` 搬入
   解析 isolate，链路仍为「解析 → 绑定 → 章节表 → 首批正文」串行），升幅构成未逐项归因：
   已知本机同码日间波动即有 ~1s 级（§3 与 §7.1 的同码两表自身相差 ~0.9s），另后台 isolate
   冷堆上做 100 章解压 + HTML 解析的 GC 成本可能高于主 isolate 热堆。属「响应性换墙钟」的
   可接受交换；如需回收可做标题专用轻量提取（非本批目标）。

### 7.3 M2a-T05 验收回归（2026-09-24，标签 `t05`）

同版本 `tool/perf_bench.dart`（5 / 5 / 5 / 3 轮、一次进程一样本）在 M2a 收官时点复测：

| 样本 | `maxGapMs` T06b 后 | `maxGapMs` T05 回归 | 变化 |
|---|---|---|---|
| `big_20mb.txt`（800 章 ≈20MB） | 29 | 30 | 持平（噪声级） |
| `big_320.epub`（320 章 + 80MB 图） | 25 | 24 | 持平 |
| `long_chapter.epub`（单章 12 万字符） | 45 | 33 | 持平 |
| `big_bodies.epub`（100 章 ≈48MB 正文） | 194 | 186 | 持平 |

结论：**`PERF-01` 验收①在 M2a 收官时点复核成立**——四样本 `maxGapMs` 全线 <200ms
（1s 阈值的 1/5 以内），与 T06b 基线持平（±10ms 噪声级），**无回归**；稳态 RSS 同口径
不回归（读 50/100 章 +1.0 / −0.6 MB）；`big_bodies` 首屏墙钟 5576ms 与 §7.2 的 5602ms 持平。

> 环境：Windows / Dart 3.12（`flutter test` 同款 SDK）。数字随机器与负载波动，**看 before / after 差值**。

## 8. M3.5-T02 门槛基线：用法与留档模板（架构 §H.2）

判定「上不上 Rust」的测量与留档走 `thresholds.md` 那一套，**与本文件 §1~§7 的内存口径不要混用**
（一个测**内存**、一个测**门槛**）。

### 8.1 怎么跑

```bash
# 生成样本（一次即可；写到临时目录，不入库）
dart run tool/gen_perf_fixtures.dart "$TMPDIR/mreader_perf"

# 测量：整组默认 skip，必须置 MREADER_PERF_BENCH=1
MREADER_PERF_BENCH=1 \
MREADER_PERF_DIR="$TMPDIR/mreader_perf" \
MREADER_PERF_DEVICE="<机型>" \
MREADER_PERF_OUT=docs/perf-baseline/<YYYY-MM-DD>-<机型>.json \
flutter test test/perf/baseline_harness.dart

# 候选 1（MOBI/AZW3）另需真实样本
MREADER_PERF_MOBI="tmp_book/<真实 azw3>" …
```

- 真实脏书自动从 `tmp_book/` 扫（**不入库**；没有该目录时这部分不声明、不红）。
- 会话默认 `skip`：单次约 6 分钟（7 轮 × 全书解压 + 8 次完整后台搜索），不进日常分组回归。
- 单条用例自带 5 分钟超时（`kBenchTimeout`），**不必**再传 `--timeout`。
- `MREADER_PERF_OUT` 只是免去手抄：**留档仍由人复核后 commit**（§H.2 要求人工留档）。

### 8.2 留档表格模板（人工填写；机读记录在 JSON 里）

```markdown
### <YYYY-MM-DD> · <机型 / 系统>（judging: <true|false>）

| # | 候选能力 | 阈值 | 实测中位数（N=7） | min / max / p90 | 判定 | 结论 |
|---|---|---|---|---|---|---|
| 1 | MOBI/AZW3 解压 | 3s / 2s | | | | |
| 2a | EPUB 解压（分层，仅归因） | 400ms | | | | |
| 2 | EPUB 2a+2b 合计（触发口径） | 800ms / 50MB 2s | | | | |
| 2b | XHTML → 段落（首版不纳入） | 合并触发 | | | | |
| 3 | TXT 编码探测与分章 | 800ms | | | | |
| 4 | 搜索首屏 | 1.5s | | | | |
| 4' | 搜索单帧 | 16ms | | | | |
| 5 | BM25 索引 | 10s / 1.5× | | | | |

- 样本：<生成 / 真实脏书，文件名 + 规模>
- 冷读（含 IO，不参与判定）：<ms>
- 结论偏离 / 口径备注：<如「2a 含无目录书 flatTitles 预取 → 下界 = 2b」>
```

### 8.3 判定纪律（写在模板旁边，防事后走样）

1. **只认中位数**（§H.1），不拿第一轮 / min 去判；
2. **只有 `judging: true`（Android 主力机）的那份是正式判定**，桌面 / 开发机只作劣化哨兵（§H.3）；
3. **`over` 才能授权上 Rust，`borderline` 与 `under` 都不得实施**（`RUST-06` 反向硬约束）；
4. **未超阈值的结论同样要留档**（`RUST-06` ④）——「不上 Rust」是一份合格的交付结论，不是空缺；
5. 「零命中 / 样本缺失 / 前置条件未满足」一律记 `notMeasured`，**不得**当作「达标」或「超标」；
6. 阈值调整**只许一次且必须写回 PRD**（`Q22`）——改 `threshold_judge.dart` 不改 PRD 会红测。
