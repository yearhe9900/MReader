# M2b-T04 全书搜索性能基线（阈值 4，CNT-06）

> 生成方式：`dart run tool/search_bench.dart …`（`2b6f05e`），样本由
> `tool/gen_perf_fixtures.dart` 写到系统临时目录（**样本不入库**）。
> 开发机（Windows x64、`dart run` JIT）**下界口径**，正式判定须 Android 主力机
> AOT 复测（与 `mobi.md` 同一口径声明）。

## 1. 阈值对照结论

阈值 4（PRD §15.6）：**50MB 书全库搜索首屏结果 > 1.5s**，或**搜索期间单帧 > 16ms
（UI 卡顿）**。对照实测（每组 3 轮）：

| # | 样本 | 文件 | 文本量 | 查询词 | 命中 | firstHit min/median | total min/median | maxGap | 首屏判定 |
|---|------|------|--------|--------|------|--------------------|------------------|--------|----------|
| 1 | big_bodies.epub（稀有词） | 0.66MB | ≈48M 字符（100 章 ×60 段 ×8000 字；解压 ≈145MB 字节） | `第1章第1段` | 1 ✓ | 4179 / 4227ms | 8418 / 8496ms | 25ms | **超标 2.8×** |
| 2 | big_bodies.epub（常见词） | 同上 | 同上 | `第1段` | 100 ✓ | 4037 / 4204ms | 8190 / 8496ms | 23ms | **超标 2.7×** |
| 3 | big_20mb.txt（稀有词） | 20.73MB | 20.7MB、800 章 | `这是第1章的第1段` | 1 ✓ | 447 / 476ms | 516 / 542ms | 18ms | 达标 |
| 4 | big_20mb.txt（常见词） | 同上 | 同上 | `第1段` | 800 ✓ | 442 / 450ms | 514 / 522ms | 24ms | 达标 |
| 5 | big_320.epub（对照） | 0.47MB | 320 章 ×12 短段 | `第1章第1段` | 1 ✓ | 59 / 84ms | 111 / 150ms | 25ms | 达标 |

- **首屏（1.5s 口径）**：TXT 20.7MB **达标**（0.45s）；320 章小正文 EPUB **达标**（<0.1s）；
  **无 toc 大正文 EPUB（48M 字符）超标**（4.2s > 1.5s），根因见 §2。
  → **2026-10-06 挂账 #6 实施后复测：52ms 达标**（同机同词 3 轮，见 §5 复跑输出；
  优化 = 搜索路径跳过 flatTitles 预取，§6 a 项）。
- **命中计数（验收①「与实际出现次数一致」）**：五组全部与人工推演一致
  （稀有词恰 1、常见词每章段 1 = 100 / 800）。
- **单帧（16ms 口径）**：maxGap 本底 18~25ms——心跳法在 Windows 上**不具 16ms
  区分力**（§3）。此口径结论降级为架构面陈述：搜索重活全程在后台 isolate
  （`usedIsolate=true` 五组实证），主 isolate 无搜索计算占用；UI 帧级真测
  （`FrameTiming`）留 T09 真机冒烟。

## 2. 超标根因（#1/2：big_bodies.epub 4.2s）

两查询首命中都在章 1 首段，而 `DartEpubSource.search` 是逐章惰性扫描
（`dart_epub_source.dart:252` 起）——**4.2s 全在开源前置**，链条：

1. big_bodies.epub 无目录（`buildLargeBodyEpub` 的 OPF 无 nav/ncx）→ 触发
   **flatTitles 全书预取**：`epub_parser.dart:518-523` 逐章
   `extractSection(lazyEntryLoader(file)())` 解压 + XML 解析抽标题
   （`dart_epub_source.dart:340`：预取表仅在 toc 为空时填充）= 100 章 × 1.44MB
   xhtml 全书解压（≈145MB inflate + 切段）。
2. 搜索走后台重建路径（`SearchBookSpec` → 搜索 isolate 内 `openBook`），
   **每次搜索都吃一次该解析成本**——阅读页已有的解析缓存含闭包、不可序列化进
   isolate（`EpubParseResult` 契约）。
3. 对照坐实「耗时 ∝ 章 xhtml 总解压量」：#5 big_320 同为无 toc 书但章体积极小 →
   59ms；#3/4 TXT 无此预取（一次切分到位）→ 0.45s。
4. 有 toc 真实书（如 tmp_book 527 章 EPUB）走目录分支**不触发**预取——预期显著
   更快，待真书复测（§4）。

## 3. 方法与口径

- `firstHitMs` = `SearchSession.firstHitElapsed`：发起 → 首条 hit 到泵口，
  **含 isolate 消息往返**（端到端口径）；`firstEventMs` 同源取首任意事件。
- `maxGapMs` = Timer.periodic 10ms 主 isolate 心跳最大打点间隔，**含收尾间隔**、
  整窗无打点按整窗计（`perf_bench.dart` 同款口径，微任务链饿死定时器不得漏计）。
- **心跳法的 Windows 本底噪声 ≈ 15~25ms**（系统定时器粒度 15.6ms + 调度抖动）：
  空闲主 isolate 同样测出 18~25ms，故对阈值 4 后半（单帧 16ms）**不具区分力**，
  仅可捕捉百 ms 级阻塞（T06 曾用它分辨 3996ms → 194ms）。如实声明，UI 帧级判定
  以 `FrameTiming`（M2b-T07 `PerfFrameMonitor` 的 >16ms 光栅口径）在真机测。
- 「50MB 书」双口径都覆盖：#1/2 按**文本量**（48M 字符 ≈ 50MB 文本；EPUB zip
  压缩率高，文件仅 0.66MB），#3 按**文件**（20.7MB）。
- 多轮 3 次取 min/median：JIT 首轮含预热，min 最稳（perf_bench 同口径）。

## 4. 已知边界

- 开发机 Windows x64 + `dart run`（JIT）下界口径；正式判定须 Android 主力机
  + AOT 复测。
- 有 toc 真实大书未测（tmp_book 私书不入库）；预期免役 flatTitles，待复测确认。
- PDF（本 isolate 流式路径）不进本基线：形状是逐页 `await pageText` 让出事件循环
  （功能正确性由 `pdf_search_test` 覆盖），卡顿面与 EPUB/TXT 不同源。
- 取消延迟未计量（协议级取消语义由 `search_session_test` 覆盖）。

## 5. 原始输出

**基线（2026-09-24，优化前）**：

```
SEARCH[bodies-rare] big_bodies.epub query=第1章第1段 hits=1 usedIsolate=true iters=3 firstHitMinMs=4179 firstHitMedianMs=4227 firstEventMs=4227 totalMinMs=8418 totalMedianMs=8496 maxGapMs=25 fileMB=0.66
SEARCH[bodies-common] big_bodies.epub query=第1段 hits=100 usedIsolate=true iters=3 firstHitMinMs=4037 firstHitMedianMs=4204 firstEventMs=4037 totalMinMs=8190 totalMedianMs=8496 maxGapMs=23 fileMB=0.66
SEARCH[txt-rare] big_20mb.txt query=这是第1章的第1段 hits=1 usedIsolate=true iters=3 firstHitMinMs=447 firstHitMedianMs=476 firstEventMs=476 totalMinMs=516 totalMedianMs=542 maxGapMs=18 fileMB=20.73
SEARCH[txt-common] big_20mb.txt query=第1段 hits=800 usedIsolate=true iters=3 firstHitMinMs=442 firstHitMedianMs=450 firstEventMs=450 totalMinMs=514 totalMedianMs=522 maxGapMs=24 fileMB=20.73
SEARCH[small-chapters] big_320.epub query=第1章第1段 hits=1 usedIsolate=true iters=3 firstHitMinMs=59 firstHitMedianMs=84 firstEventMs=59 totalMinMs=111 totalMedianMs=150 maxGapMs=25 fileMB=0.47
```

**挂账 #6 实施后复跑（2026-10-06，同机同词同轮数，`aba22eb`）**：

```
SEARCH[rare] big_bodies.epub query=第1章第1段 hits=1 usedIsolate=true iters=3 firstHitMinMs=52 firstHitMedianMs=65 firstEventMs=52 totalMinMs=4286 totalMedianMs=4328 maxGapMs=24 fileMB=0.66
SEARCH[common] big_bodies.epub query=第1段 hits=100 usedIsolate=true iters=3 firstHitMinMs=53 firstHitMedianMs=62 firstEventMs=53 totalMinMs=4322 totalMedianMs=4360 maxGapMs=22 fileMB=0.66
SEARCH[rare] big_320.epub query=第1章第1段 hits=1 usedIsolate=true iters=3 firstHitMinMs=26 firstHitMedianMs=40 firstEventMs=26 totalMinMs=89 totalMedianMs=113 maxGapMs=20 fileMB=0.47
SEARCH[rare] big_20mb.txt query=这是第1章的第1段 hits=1 usedIsolate=true iters=3 firstHitMinMs=430 firstHitMedianMs=440 firstEventMs=430 totalMinMs=498 totalMedianMs=508 maxGapMs=18 fileMB=20.73
```

对照结论（开发机下界口径）：
- **无 toc 大书首屏 4179/4227ms → 52/65ms（约 80×，2.8× over → 达标）**；
- 全书 total 8418 → 4286ms（减半：省掉预取那一遍全书解压；剩余为逐章扫描本底）；
- 对照组不变量：big_320 59→26ms（同优化顺带受益，本底波动内）、TXT 447→430ms
  （本就不走该路径）、**命中计数四组全部与人工推演一致**（1/100/1/1，验收①无回归）；
- 单帧 maxGap 18~24ms：本底噪声区间不变（§3 口径，不具 16ms 区分力）。
- **正式判定仍待 Android 主力机 AOT 复跑**（§4；阈值 4 三段式中的首屏口径已翻转，
  单帧口径与真书 c 项复测同批）。

## 6. 对后续的规格输入

1. **无 toc 大书的搜索首屏 4.2s 超阈值 4**——优化候选与处置（挂账 #6）：
   a) ~~flatTitles 惰性化（toc 空时先出章列表、标题后台补）~~ → **2026-10-06 实施为
      「搜索路径整段跳过预取」**：`EpubParseRequest.prefetchFlatTitles: false`
      （`search_session.dart` 两处 `openBook` 传入），无 toc 书的解析期预取对搜索
      **纯前置成本**（搜索循环本来就逐章 `extractSection`），跳过后命中章标题从该
      结果零成本取得；跳过时 `flatTitles` 填 `href -> ''` 全占位防消费方回退现场
      解压，占位结构**禁写回**结构缓存。详见 `tech-usage.md` §2.66；
   b) 搜索先于标题预取开始扫章（首屏结果不等全书标题）——已被 a) 取代，不再单做；
   c) 有 toc 真书复测确认免役后再定优先级——**仍待真机复测**（§4 边界不变）。
   **开发机复测已回填（§5 复跑输出）：首屏 4179 → 52ms 达标**；
   Android 主力机正式判定待与 M3.5-T02 同批复跑。
2. UI 帧级卡顿判定须走 `FrameTiming` 真机口径（心跳法本底噪声见 §3）。
3. 阈值 5（AI 场景）基线仍待 AI 落地后补（M3 殿后既定注记）。
