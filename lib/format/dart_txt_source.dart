// TXT 的纯 Dart [BookSource] 实现（`'dart-txt'`）。
//
// **纯 Dart 层**：不 import Flutter、不 import `dart:io`，只吃 bytes ——
// 这正是 `PERF-01`（解析移出主 isolate）要求的形状：整个对象可以直接丢进 `compute()`。
// M3.5 若把「编码探测 / 大文件分章」Rust 化，会新增 `RustTxtSource` 实现同一接口，
// 本文件保持不动（PRD §15.6.2：Rust 首版只做「探测出编码名」，解码仍留 Dart）。
//
// ## 分章算法出处（PRD 附录 A：算法/格式规范级可借鉴来源）
//
// 1:1 照译参考实现：
//   `567Reader/app/src/main/java/com/qreader/reader/model/localBook/TextFile.kt`
//   · 规则择优 `getTocRule()`（`:497-535`）
//   · 规则分章 `analyze(rr)`（`:159-389`）
//   · 无规则分块 `analyze(fileStart, fileEnd)`（`:394-492`）
//   · 内置规则表 `assets/defaultData/txtTocRule.json` 中 `enable == true` 的 12 条
//
// **按源码真实语义照译**（而非 PRD 转述）：择优三变量 csNum / numE / maxNum 的语义见
// [_pickRule] 上方注释；阈值常量的**字节 -> 字符**换算差异见各常量注释。
//
// ## 刻意跳过（Java/Android 专有，纯 Dart 无从照搬）
//
// · **Rhino JS 标题净化**（`replacement()` / `evalJs()` / `JsExtensions`）：依赖
//   `RhinoScriptEngine` 与 `$book/$index/$lastVolumeTitle` 注入，Android 专有。
//   无 JS 时参考实现的 `replacement` 原样返回匹配文本，故本实现直接取匹配文本（trim 后）。
// · **`isVolume` / `lastVolumeTitle`**：仅为 JS 与「卷分组显示」服务；本项目的
//   `Chapter` 模型没有该字段（架构 §A.1），故不表达——卷标题会**保留为普通章节**
//   （与参考实现一致：参考实现同样把它们留在 toc 里，只是打了 isVolume 标记）。
// · **按字节的偏移/长度**：参考实现在字节层切分（`toByteArray(charset)`、`buffer[i]==0x0a`），
//   并用 `curOffset`（字节）做绝对定位；本项目的 `Chapter.href` 约定为**字符偏移**
//   （`lib/model/chapter.dart`），故整体改为**字符级**实现。对中文书，字符阈值与
//   参考实现的字节阈值触发点不同（如 100KB 字节 ≈ 3.3 万汉字）。
// · **512KB 读取缓冲的跨块拼接**：参考实现的 `bufferPos` 是「读块序号」产物；本实现
//   保留其**命名形状** `第N章(M)`（N=字符块序号），但不再模拟字节缓冲搬运。
//   规则**择优**同样只取首个 512KB 块（与参考实现一致；否则对整本大书跑 12 条
//   lookbehind 规则会到分钟级——实测 20MB 无标记文本由 >6min 降到百毫秒级）。
//
// ## 内存（`RD-02` ③：20MB 不闪退；M1-T07 的 `PERF-02` 输入）
//
// 全文**只解码一次**并缓存；分章边界用**字符区间**表示，`content(i)` 用 `substring` 取，
// **不每章重新解码整本**。峰值量级 ≈ 原始 bytes（20MB）+ 解码后的 String
// （Dart 字符串按 UTF-16 code unit 计，中文 BMP 约 2 字节/字；20MB GBK ≈ 10M 字 ≈ 20MB）
// + 分章结果（少量），即**约为输入文件的 2 倍**。刻意不做「逐字节映射」那套省内存设计——
// 本实现的定位是「正确且可测的纯 Dart 基线」，内存收敛交给 M1-T07。
import 'dart:typed_data';

import '../epub/text_codec.dart';
import '../meta/txt_meta.dart';
import 'book_source.dart';

// `Chapter` / `ChapterContent` / `MReaderFormatException` 经 `book_source.dart`
// 的 export 转出，不再单独 import（与 `dart_epub_source.dart` 一致）。

/// 无规则分块时，每块的最大**字符**数（参考实现 `maxLengthWithNoToc = 10 * 1024` 字节）。
const int _maxLengthWithNoToc = 10 * 1024;

/// 有规则分章时，单章的最大**字符**数（参考实现 `maxLengthWithToc = 102400` 字节）。
const int _maxLengthWithToc = 100 * 1024;

/// 参考实现的读取块大小（`bufferSize = 512000` 字节）；本实现仅借它生成 `第N章(M)` 的 N。
const int _chunkBlockChars = 512000;

/// 择优领先量（参考实现 `overRuleCount`）：后续规则命中数须比当前最优**多 2** 才替换。
const int _overRuleCount = 2;

/// 择优提前终止阈值（参考实现 `maxNum > 70`）。
const int _maxNumBreak = 70;

/// 判定「上一匹配与本匹配之间夹着正文」的间隔（参考实现 `> 1000` → 视为正式章节）。
const int _longGapChars = 1000;

/// 判定「疑似卷标题」的短间隔（参考实现 `< 100` → `numE++`）。
const int _shortGapChars = 100;

/// 无规则分块的收尾阈值（参考实现 `bufferStart > 100` 才单列尾章，否则并入上一章）。
const int _minTailChars = 100;

/// 行分隔：`\r\n` / `\r` / `\n`。
final RegExp _lineBreak = RegExp(r'\r\n|\r|\n');

/// 打开本地 TXT（纯字节入口）。
///
/// ## dispose 契约（与 [DartEpubSource] 一致，`RUST-01` 上层无感）
///
/// [dispose] 之后、以及「调用与 dispose 竞态」时，所有公开方法都**返回优雅空结果、
/// 绝不抛异常**：`load()` → 最小 [BookMeta]（title `'未命名'`、origins 全 `MetaOrigin.none`）；
/// `chapters()` / `content()` → 空；`search()` → 流立即结束；`totalCharCount()` → `null`。
/// 实现方式：**每个 `await` 恢复后重查 [_disposed]**，不依赖 `!` 断言。
class DartTxtSource implements BookSource {
  DartTxtSource({required this.fileName, required this.bytes});

  /// 原始文件名（书名缺失时兜底；也是唯一元数据来源）。
  final String fileName;

  /// TXT 的完整字节。
  final Uint8List bytes;

  String? _text;
  List<_Segment>? _segments;
  List<Chapter>? _chapters;
  Future<void>? _preparing;
  int? _totalChars;
  bool _disposed = false;

  /// 已释放 / 竞态时 `load()` 的最小返回（title 不空、origins 全 `none`）。
  static const BookMeta _disposedMeta = BookMeta(
    title: '未命名',
    titleOrigin: MetaOrigin.none,
    author: '',
    authorOrigin: MetaOrigin.none,
    intro: '',
    introOrigin: MetaOrigin.none,
    cover: NoCover(),
    coverOrigin: MetaOrigin.none,
    language: '',
    auto: BookMetaAuto(title: '未命名', author: '', intro: ''),
  );

  @override
  String get implId => 'dart-txt';

  @override
  Future<BookMeta> load() async {
    await _ensurePrepared();
    if (_disposed) return _disposedMeta;
    // `META-04` + `META-01`：书名 / 作者经文件名规则链（命中即停）+ 统一兜底。
    // TXT 无内嵌封面：`cover` 恒为 `NoCover`（`META-07` 的合成封面是运行时绘制）。
    return buildTxtMeta(fileName: fileName);
  }

  @override
  Future<List<Chapter>> chapters() async {
    await _ensurePrepared();
    if (_disposed) return const <Chapter>[];
    return _chapters ?? const <Chapter>[];
  }

  @override
  Future<ChapterContent> content(int chapterIndex) async {
    await _ensurePrepared();
    // dispose 竞态：`await` 恢复后可能已被释放（`_text` / `_segments` 已清空）。
    // 用局部变量取快照 + 判空，**不用 `!` 断言**（那是竞态崩溃的根因）。
    final List<_Segment>? segments = _segments;
    final String? text = _text;
    if (_disposed || segments == null || text == null) {
      return const ChapterContent.paragraphs(<String>[]);
    }
    if (chapterIndex < 0 || chapterIndex >= segments.length) {
      return const ChapterContent.paragraphs(<String>[]); // 越界不抛异常
    }

    final _Segment segment = segments[chapterIndex];
    final List<String> paragraphs =
        _splitParagraphs(text.substring(segment.start, segment.end));

    // 首行与章名重复时剥掉——与 EPUB 侧 `extractSection` 的既有口径一致
    // （UI 单独渲染标题，正文不该再重复一遍）。
    final List<Chapter>? chapterList = _chapters;
    if (paragraphs.isNotEmpty &&
        chapterList != null &&
        chapterIndex < chapterList.length &&
        paragraphs.first == chapterList[chapterIndex].title) {
      paragraphs.removeAt(0);
    }
    return ChapterContent.paragraphs(paragraphs);
  }

  @override
  SourceCapabilities capabilities() => const SourceCapabilities(
        hasImages: false,
        hasFootnotes: false,
        reflowable: true,
        searchable: true,
        charCountSupported: true,
      );

  @override
  Future<int?> totalCharCount() async {
    final int? cached = _totalChars;
    if (cached != null) return cached;
    // 刻意**不在 load() 里算**：20MB 的书会把打开动作拖慢。
    final String text = await _textOnce();
    if (_disposed) return null; // dispose 竞态：优雅返回 null
    int count = 0;
    for (int i = 0; i < text.length; i++) {
      if (!_isWhitespaceUnit(text.codeUnitAt(i))) count++;
    }
    _totalChars = count;
    return count;
    // 口径：按 UTF-16 code unit 计（= `String.length`），仅排除空白；
    // 与 EPUB 侧 `totalCharCount()` 用 `paragraph.length` 累加的口径一致。
    // M2b 的 `STAT-14` 会统一 EPUB / TXT 两个实现的口径。
  }

  @override
  Stream<SearchEvent> search(String query, {required CancelToken cancel}) async* {
    if (query.isEmpty) return;
    await _ensurePrepared();
    if (_disposed) return; // dispose 竞态：立即结束流
    final List<Chapter>? chapterList = _chapters;
    if (chapterList == null || chapterList.isEmpty) return;
    final int total = chapterList.length;

    // 朴素子串扫描（与 `DartEpubSource.search` 同一形状）：逐章逐段 indexOf。
    // **不建索引**——索引属 M2b；本实现同时是 Rust 阈值 3 的纯 Dart 基线。
    for (int i = 0; i < total; i++) {
      if (cancel.isCancelled || _disposed) return;
      final ChapterContent chapterContent = await content(i);
      if (_disposed) return; // `content` 的 await 期间可能已被释放

      int offset = 0;
      for (final String paragraph in chapterContent.paragraphList) {
        int from = 0;
        while (true) {
          final int at = paragraph.indexOf(query, from);
          if (at < 0) break;
          yield SearchEvent.hit(SearchHit(
            chapterIndex: i,
            chapterTitle: chapterList[i].title,
            offset: offset + at,
            context: paragraph,
          ));
          if (cancel.isCancelled) return;
          from = at + query.length;
        }
        offset += paragraph.length;
      }

      yield SearchEvent.progress((i + 1) / total);
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _preparing = null;
    _text = null;
    _segments = null;
    _chapters = null;
    _totalChars = null;
  }

  /// 是否已释放（供体检 / 测试观察）。
  bool get isDisposed => _disposed;

  // ---------------------------------------------------------------------------
  // 准备（解码 + 分章），Future 去重
  // ---------------------------------------------------------------------------

  Future<void> _ensurePrepared() {
    if (_disposed) return Future<void>.value(); // 已释放：不再触发解析
    return _preparing ??= _prepare();
  }

  Future<void> _prepare() async {
    final String text = await _textOnce();
    if (_disposed) return; // 竞态：准备完成时已释放，不再写回
    if (text.trim().isEmpty) {
      throw const MReaderFormatException(FormatErrorCode.txtNoContent);
    }
    final List<_Segment> segments = _analyze(text);
    if (_disposed) return;
    _segments = segments;
    _chapters = List<Chapter>.unmodifiable(<Chapter>[
      for (final _Segment s in segments)
        Chapter(href: 'txt:${s.start}', title: s.title, level: 0, locate: ''),
    ]);
  }

  /// 全文解码一次并缓存（`decodeText` 已按 `NF-C4` 六级兜底；此处再防御性剥掉行首 BOM 残留）。
  Future<String> _textOnce() async {
    final String? cached = _text;
    if (cached != null) return cached;
    final String decoded = decodeText(bytes);
    final String text =
        decoded.startsWith('\uFEFF') ? decoded.substring(1) : decoded;
    if (!_disposed) _text = text;
    return text;
  }

  // ---------------------------------------------------------------------------
  // 分章
  // ---------------------------------------------------------------------------

  List<_Segment> _analyze(String text) {
    // **只在首个 512KB 块上做规则择优**（对照参考实现：`getChapterList()` 只把
    // 首个 `bufferSize = 512000` 字节的块交给 `getTocRule()`）。这既是忠实照译，
    // 也避免对整本大书跑 12 条带 lookbehind 的规则（实测 20MB 会从分钟级降到百毫秒级）。
    final String sample = text.length > _chunkBlockChars
        ? text.substring(0, _chunkBlockChars)
        : text;
    final _TocRule? rule = _pickRule(sample);
    // 无任何规则命中 -> 按 10KB 分块（RD-02 ②）。
    if (rule == null) return _splitByLength(text, 0, text.length);
    return _splitByRule(text, rule);
  }

  /// 规则择优（对照参考实现 `getTocRule()`）。
  ///
  /// [text] 传入的是**首个 512KB 块**（见 [_analyze]）——参考实现同样只在首块上择优。
  ///
  /// 三个变量的**真实语义**：
  /// · `csNum` = **命中章节数**：被该规则接纳为「正式章节」的匹配数
  ///   （首个匹配、或与前一次接纳匹配的间距 > 1000 字者）；
  /// · `numE`  = **疑似卷（误判）数**：两次匹配间距 < 100 字的次数
  ///   ——「卷标题紧跟下一章标题」是典型的卷误判，故要按数量压它；
  /// · `maxNum`= **当前最优规则的 csNum**（跨规则择优的比较基准，初值 -1）。
  ///
  /// 接纳条件：`csNum >= numE * 3`（正式章节数至少是疑似卷数的 3 倍）
  /// 且 `csNum > maxNum + 2`（须比当前最优多命中 2 个才替换，避免被靠后但等量的规则盖掉）；
  /// 选中最优后若 `maxNum > 70` 立即终止（已足够可信）。
  _TocRule? _pickRule(String text) {
    _TocRule? best;
    int maxNum = -1;
    for (final _TocRule rule in _defaultTocRules) {
      final RegExp pattern;
      try {
        pattern = RegExp(rule.pattern, multiLine: true);
      } catch (_) {
        continue; // 规则正则语法错误：跳过（对照参考实现的 PatternSyntaxException 分支）
      }

      int start = 0;
      int csNum = 0;
      int numE = 0;
      for (final RegExpMatch m in pattern.allMatches(text)) {
        final int contentLength = m.start - start;
        if (start == 0 || contentLength > _longGapChars) {
          final String title = m.group(0) ?? '';
          if (title.isNotEmpty) csNum++;
          start = m.end;
        } else if (contentLength < _shortGapChars) {
          numE++;
        }
      }

      if (csNum >= numE * 3 && csNum > maxNum + _overRuleCount) {
        maxNum = csNum;
        best = rule;
        if (maxNum > _maxNumBreak) break;
      }
    }
    return best;
  }

  /// 按命中的规则切章（对照参考实现 `analyze(rr)` 的可见结果）。
  ///
  /// 字符级等价结果：
  /// · 第一个标题之前的正文（非空白）→「前言」章 `[0, firstMatch.start)`；
  /// · 每个匹配 → 一章，正文 = `[本匹配.end, 下一匹配.start)`（标题本身不进正文）；
  /// · 单章正文 > [_maxLengthWithToc] → 二次拆分，子章名为 `章名(N)`。
  List<_Segment> _splitByRule(String text, _TocRule rule) {
    final RegExp pattern = RegExp(rule.pattern, multiLine: true);
    final List<RegExpMatch> matches = pattern.allMatches(text).toList();
    if (matches.isEmpty) return _splitByLength(text, 0, text.length);

    final List<_Segment> segments = <_Segment>[];

    final int firstStart = matches.first.start;
    if (firstStart > 0 && text.substring(0, firstStart).trim().isNotEmpty) {
      segments.add(_Segment(0, firstStart, '前言'));
    }

    for (int i = 0; i < matches.length; i++) {
      final RegExpMatch m = matches[i];
      // 参考实现把原始匹配交给用户 JS 净化；本实现跳过 JS，直接取匹配文本（trim 后）。
      final String title = (m.group(0) ?? '').trim();
      final int segStart = m.end;
      final int segEnd =
          i + 1 < matches.length ? matches[i + 1].start : text.length;
      if (segEnd <= segStart) continue; // 防御：空区间（相邻标题紧贴）

      if (segEnd - segStart > _maxLengthWithToc) {
        // 超长章：二次拆分（参考实现把原章截空并标 isVolume，再用无规则分块重切，
        // 子章名 `章名(N)`；本项目 Chapter 模型无 isVolume，故原章**不留空壳**）。
        segments.addAll(
          _splitByLength(text, segStart, segEnd, titlePrefix: title),
        );
      } else {
        segments.add(_Segment(
          segStart,
          segEnd,
          title.isNotEmpty ? title : '第 ${segments.length + 1} 节',
        ));
      }
    }

    return segments.isEmpty ? _splitByLength(text, 0, text.length) : segments;
  }

  /// 无规则分块（对照参考实现 `analyze(fileStart, fileEnd)`）。
  ///
  /// 每块 ≤ [_maxLengthWithNoToc] 字，且尽量在换行处断开；块名为
  /// `第N章(M)`（N = 字符块序号，M = 块内序号）；[titlePrefix] 非空时用 `前缀(M)`。
  /// 末尾残块 ≤ [_minTailChars] 字并入上一章。
  List<_Segment> _splitByLength(
    String text,
    int from,
    int to, {
    String? titlePrefix,
  }) {
    final List<_Segment> segments = <_Segment>[];
    int pos = from;
    int blockIndex = 1;
    int chapterPos = 0;
    int blockEnd = from + _chunkBlockChars;

    while (to - pos > _maxLengthWithNoToc) {
      if (pos >= blockEnd) {
        blockIndex++;
        chapterPos = 0;
        blockEnd = pos + _chunkBlockChars;
      }
      final int cut = pos + _maxLengthWithNoToc;
      final int nl = text.indexOf('\n', cut);
      final int end = (nl >= 0 && nl < to) ? nl : to;
      chapterPos++;
      segments.add(_Segment(pos, end, _chunkTitle(titlePrefix, blockIndex, chapterPos)));
      pos = end;
    }

    // 收尾：剩余不足一块。参考实现：残块 > 100 字（或尚无章节）才单列，否则并入上一章。
    if (segments.isEmpty || to - pos > _minTailChars) {
      chapterPos++;
      segments.add(_Segment(pos, to, _chunkTitle(titlePrefix, blockIndex, chapterPos)));
    } else if (pos < to && segments.isNotEmpty) {
      final _Segment last = segments.removeLast();
      segments.add(_Segment(last.start, to, last.title));
    }
    return segments;
  }

  String _chunkTitle(String? prefix, int blockIndex, int chapterPos) =>
      prefix == null ? '第$blockIndex章($chapterPos)' : '$prefix($chapterPos)';

  // ---------------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------------

  /// 把正文按行切成段落：按 `\r\n|\r|\n` 分、逐行剥行首 BOM + trim、丢空行。
  static List<String> _splitParagraphs(String raw) {
    final List<String> out = <String>[];
    for (String line in raw.split(_lineBreak)) {
      if (line.isNotEmpty && line.codeUnitAt(0) == 0xFEFF) {
        line = line.substring(1); // 行首 BOM 残留
      }
      final String trimmed = line.trim();
      if (trimmed.isNotEmpty) out.add(trimmed);
    }
    return out;
  }

  /// 是否空白字符（与 `String.trim` 的口径接近；另含全角空格 U+3000）。
  static bool _isWhitespaceUnit(int c) =>
      c == 0x20 || (c >= 0x09 && c <= 0x0D) || c == 0x3000 || c == 0x00A0;
}

/// 一章的字符区间与章名（内部结构）。
class _Segment {
  const _Segment(this.start, this.end, this.title);

  final int start;
  final int end;
  final String title;
}

/// 一条 TXT 目录规则（章名 + 正则源码）。
class _TocRule {
  const _TocRule(this.name, this.pattern);

  /// 规则名（仅供排障 / 记录，不参与逻辑）。
  final String name;

  /// 正则源码（`RegExp` 的 `multiLine` 打开，对照 `Pattern.MULTILINE`）。
  final String pattern;
}

/// 内置目录规则集：`txtTocRule.json` 中 `enable == true` 的 12 条，按 `serialNumber` 升序。
///
/// 与参考实现的差异：参考实现从 Room 数据表取「用户启用」的规则（表空则灌入默认表），
/// 本项目本批**只内置这份默认表**（规则管理 UI 不在本批范围）。
const List<_TocRule> _defaultTocRules = <_TocRule>[
  _TocRule(
    '目录(去空白)',
    r'(?<=[　\s])(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第\s{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|集(?![合和]))).{0,30}$',
  ),
  _TocRule(
    '目录',
    r'^[ 　\t]{0,4}(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第\s{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|集(?![合和])|部(?![分赛游])|篇(?!张))).{0,30}$',
  ),
  _TocRule('数字 分隔符 标题名称', r'^[ 　\t]{0,4}\d{1,5}[:：,.， 、_—\-].{1,30}$'),
  _TocRule(
    '大写数字 分隔符 标题名称',
    r'^[ 　\t]{0,4}(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|[零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}章?)[ 、_—\-].{1,30}$',
  ),
  _TocRule('正文 标题/序号', r'^[ 　\t]{0,4}正文[ 　]{1,4}.{0,20}$'),
  _TocRule(
    'Chapter/Section/Part/Episode 序号 标题',
    r'^[ 　\t]{0,4}(?:[Cc]hapter|[Ss]ection|[Pp]art|ＰＡＲＴ|[Nn][oO][.、]|[Ee]pisode|(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外)\s{0,4}\d{1,4}.{0,30}$',
  ),
  _TocRule(
    '特殊符号 序号 标题',
    r'(?<=[\s　])[【〔〖「『〈［\[](?:第|[Cc]hapter)[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,10}[章节].{0,20}$',
  ),
  _TocRule(
    '特殊符号 标题(单个)',
    r'(?<=[\s　]{0,4})(?:[☆★✦✧].{1,30}|(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外)[ 　]{0,4}$',
  ),
  _TocRule(
    '章/卷 序号 标题',
    r'^[ \t　]{0,4}(?:(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|[卷章][\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8})[ 　]{0,4}.{0,30}$',
  ),
  _TocRule(
    '书名 括号 序号',
    r'^[一-龥]{1,20}[ 　\t]{0,4}[(（][\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}[)）][ 　\t]{0,4}$',
  ),
  _TocRule(
    '书名 序号',
    r'^[一-龥]{1,20}[ 　\t]{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}[ 　\t]{0,4}$',
  ),
  _TocRule(
    '字数分割 分节阅读',
    r'(?<=[ 　\t]{0,4})(?:.{0,15}分[页节章段]阅读[-_ ]|第\s{0,4}[\d零一二两三四五六七八九十百千万]{1,6}\s{0,4}[页节]).{0,30}$',
  ),
];
