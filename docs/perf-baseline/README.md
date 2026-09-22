# 性能基线（PERF-02 内存收敛 / PERF-03 分段渲染）

> 本目录记录 **M1-T07** 的「改前 / 改后」可复现性能数字。
> 样本由 `tool/gen_perf_fixtures.dart` 生成到**系统临时目录**，**不入库**（见 `.gitignore`）。

## 1. 结论（TL;DR）

| 指标 | 改前 | 改后 | 变化 |
|---|---|---|---|
| **300+ 章 EPUB 首屏时间**（min / median，5 轮） | 112 / 148 ms | **42 / 58 ms** | **≈ −63% / −61%** |
| **300+ 章 EPUB 驻留 RSS**（首屏后） | 504.7 MB | **433.7 MB** | **≈ −71 MB** |
| **300+ 章 EPUB 峰值 RSS** | 623.8 MB | **588.5 MB** | ≈ −35 MB |
| 20MB TXT 首屏时间（回归基线） | 413 / 429 ms | 413 / 417 ms | 持平（TXT 路径本次未改） |
| 单超长章 EPUB 首屏（回归基线） | 23 / 25 ms | 22 / 28 ms | 持平 |

一句话：**打开大书时不再把整本条目（含图片 / 字体 / CSS）一次性解压常驻**——首屏时间与驻留内存同步收敛，TXT / 小书无回归。

## 2. 方法（可复现）

### 2.1 测量口径

在 **`BookSource` 层**测「首屏」——进入阅读页前必须完成的工作：

```
load()（结构 + 元数据） → chapters()（章节表） → content(目标章 ±1)（首批正文）
```

为什么在这一层：纯 Dart、与 UI / FakeAsync 无关、可重复；阅读页的首屏正是「等这一组调用返回 + 首次布局」。

- **`firstScreenMs`**：上述整条链路的墙钟耗时；取 5 轮的 **最小值**（预热后最稳）与**中位数**；
- **`rssMB` / `peakMB`**：`ProcessInfo.currentRss`（末轮驻留）/ `ProcessInfo.maxRss`（进程峰值）。
  Dart VM 基线本身约 420 MB（含 JIT），故**看差值**而非绝对值；
- **一次进程只测一个样本**，避免跨样本 RSS 互相污染（`tool/perf_bench.dart` 强制单样本 + 多轮）。

### 2.2 复现步骤

```bash
# 1) 生成样本（写到临时目录；参数见 tool/gen_perf_fixtures.dart）
dart run tool/gen_perf_fixtures.dart "$TMPDIR/mreader_perf"
#   产物：big_20mb.txt（≈20.7MB / 800 章）
#         big_320.epub（320 章 + 20×4MB 图片；解压后图片合计 80MB，zip 内因全零可压至极小）
#         long_chapter.epub（单章 ≈12 万字符）

# 2) 逐样本测量（一次进程一个样本，5 轮）
for f in big_20mb.txt big_320.epub long_chapter.epub; do
  dart run tool/perf_bench.dart "$TMPDIR/mreader_perf" "$f" after 5
done

# 3) 复现「改前」：把三个文件回到 M1-T07 之前（1bb5802），再跑同一条命令
git checkout 1bb5802 -- lib/epub/epub_parser.dart lib/epub/zip_paths.dart lib/model/epub_book.dart
#   ... 跑 after 同一命令，标签换成 before ...
git checkout HEAD -- lib/epub/epub_parser.dart lib/epub/zip_paths.dart lib/model/epub_book.dart
```

### 2.3 样本参数

| 样本 | 章数 | 单章段落 | 非章节资源 | 解压后图片合计 |
|---|---|---|---|---|
| `big_20mb.txt` | 800 | 300 | — | — |
| `big_320.epub` | 320 | 12 | 20 × PNG(4MB) | **80 MB** |
| `long_chapter.epub` | 1 | 1200 | — | — |

图片用**全零字节**：zip 里压缩到几乎为零，但**解压后体积 = 4MB/张**。因此「是否预解压图片」这一项，在文件体量上看不出来，在**驻留内存**上却一目了然——正是 `PERF-02` ① 要抓的东西。

## 3. 原始输出（粘贴，勿手改）

**改前（`before`，`1bb5802` 的解析器：对所有条目 `contentOfArchiveFile` 预解压）**

```
BENCH[before] big_20mb.txt      chapters=800 iters=5 minMs=413 medianMs=429 rssMB=423.8 peakMB=623.2
BENCH[before] big_320.epub      chapters=320 iters=5 minMs=112 medianMs=148 rssMB=504.7 peakMB=623.8
BENCH[before] long_chapter.epub chapters=1   iters=5 minMs=23  medianMs=25  rssMB=420.4 peakMB=590.1
```

**改后（`after`，M1-T07：结构解析只建条目名索引，正文 / 图片按需解压）**

```
BENCH[after]  big_20mb.txt      chapters=800 iters=5 minMs=413 medianMs=417 rssMB=424.3 peakMB=623.6
BENCH[after]  big_320.epub      chapters=320 iters=5 minMs=42  medianMs=58  rssMB=433.7 peakMB=588.5
BENCH[after]  long_chapter.epub chapters=1   iters=5 minMs=22  medianMs=28  rssMB=418.8 peakMB=587.7
```

> 环境：Windows / Dart 3.12（`flutter test` 同款 SDK）。数字随机器与负载波动，**看改前/改后差值**即可。

## 4. 结构性证据（不依赖计时）

改后的内存收敛不是「调参调出来的」，而是结构上成立：

1. **只建条目名索引，不预解压**：`epub_parser.dart` 用 `Map<String, ArchiveFile> byName`
   （`ArchiveFile.content` 本身按需解压），替换了旧实现的 `Map<String, Uint8List> files`（逐条 `contentOfArchiveFile`）。
2. **正文按需**：`EpubSection.lazy` 用回调解码，`load()`/`chapters()` **不解压任何章节正文**，
   正文推迟到 `DartEpubSource.content(i)` 才读取。
3. **非章节资源（图 / 字 / CSS）永不进正文路径**：spine 解析用 `textualVerdict()`（仅凭
   `media-type` / 扩展名）判定，明确非文本直接跳过、**连解压都不做**。
4. **驻留有界**：阅读页正文由 `ChapterCache`（LRU，上限 `kMaxLoadedChapters = 30`）兜底，
   首帧仅等「目标章 ±1」，其余后台按「离当前章由近及远」逐批补齐（见 `test/perf/lazy_load_test.dart`）。

## 5. 相关测试

| 测试文件 | 断言 |
|---|---|
| `test/perf/lazy_load_test.dart` | 320 章首帧批次 ≤ 3；补齐后驻留 ≤ 30 且 < 总章数；含图片书窗口中心驻留 ≤ 30；LRU 小上界逐出；超长章逐段（>1000 段、>10 万字符、无单段等于整章） |
| `test/task/isolate_runner_test.dart` | `compute()` 薄封装：纯函数往返；不可序列化入参 / 捕获闭包**明确失败、不静默** |

## 6. 已知边界（本次未覆盖 / 后续）

- `PERF-02` 的**磁盘缓存**（`docs/进度表.md` 风险 2）仍待 M2；本任务只做「内存收敛」。
- `tool/*` 与 `test/perf/*` 用纯 Dart `test()`（**非** `testWidgets`）：本项目已两次实证
  `testWidgets` 体内 `await` 真异步 IO 会挂死（FakeAsync 不排空微任务队列），故不在此复现。
