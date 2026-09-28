// 纯 Dart 的 EPUB 解析层。
//
// 对外入口（**两层，务必分清**）：
//   · `parseEpubStructure(bytes) -> EpubStructure`——**纯数据、无闭包**，可跨 isolate
//     （`compute()` / `lib/task/isolate_runner.dart`）；只含结构 / 元数据 / 目录 /
//     封面候选 href / 条目名索引，**不含任何字节**。
//   · `parseEpubResult(bytes) -> EpubParseResult`——在同一次解析里**额外绑定**出带
//     `loadBytes`（章节正文按需）与 `readEntry`（封面候选按需）的 [EpubBook] / [OpfView]，
//     供 `lib/meta/epub_meta.dart`（`META-02/03`）与 `DartEpubSource` 消费。
//
// ⚠️ **isolate 边界（`PERF-01`，`M2a-T06` 已接线）**：`parseEpubResult` 的返回值**不可跨
//    isolate 传递**——它内部的 `loadBytes` / `readEntry` 是**闭包**，`SendPort` 会直接拒绝。
//    正确接线（`DartEpubSource._parsedOnce` 已采用）：后台 isolate 跑
//    [parseEpubStructureTask]（即 [parseEpubStructure] 纯数据）→ 结构经 [EpubParseOutcome]
//    信封传回 → 再由持有原始 `bytes` 的 isolate 调 [bindEpubResult] 绑定闭包
//    （见 `docs/schedule.md` M2a-T06 勘误）。
//
// `PERF-02` ①（内存收敛）：结构解析阶段**只建「条目名 → ArchiveFile」索引、绝不预解压**；
//    章节正文由绑定期产出的 `loadBytes` **按需、非驻留**解压（见 `zip_paths.dart` 的
//    `lazyEntryLoader`），非章节资源（图 / 字 / CSS）在与正文无关的路径上永不读取。
//    **唯一有界例外**（[_parse] 第 8 步）：无目录书的 `flatTitles` 预取——逐章非缓存
//    解压取标题后**字节即弃**，不驻留任何解压结果（只留 `href -> 标题` 字符串）。
//
// 章节正文的 XHTML -> 文本转换在 section_extractor.dart 里按需调用。
//
// 错误口径：一律抛 [MReaderFormatException]（文案唯一来源 `lib/format/error_messages.dart`），
// 调用方据此给用户**可读的中文提示**（`RD-05`），绝不白屏。
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../diagnostics/perf_log.dart';
import '../format/error_messages.dart';
import '../model/chapter.dart';
import '../model/epub_book.dart';
import 'epub_toc.dart';
import 'section_extractor.dart';
import 'text_codec.dart';
import 'xml_util.dart';
import 'zip_paths.dart';

/// **已废弃**：保留为 [MReaderFormatException] 的子类，仅为兼容既有引用。
///
/// 新代码请直接抛 [MReaderFormatException]（错误码 + 唯一中文文案）。
@Deprecated('改用 MReaderFormatException（RD-05 唯一文案来源）')
class EpubParseException extends MReaderFormatException {
  const EpubParseException(this.rawMessage)
      : super(FormatErrorCode.corruptFile);

  /// 旧式自由文本消息（本类只为兼容而存在）。
  final String rawMessage;

  @override
  String get message => rawMessage;

  @override
  String toString() => rawMessage;
}

/// 一个封面候选（`META-02` 四来源，**已按优先级排序**）。
///
/// 见架构 §N.4 动作项 D1。[source] 是**非契约的调试标签**（哪一路来源），
/// 不参与等价性判定、不落盘（§N.2 的 `debugTag` 思想）。
class CoverCandidate {
  const CoverCandidate({required this.href, required this.source});

  /// 包内路径（已归一化）。
  final String href;

  /// 来源标签（仅调试 / 排障）。
  final String source;
}

/// 一个 spine 项的**纯数据引用**（[parseEpubStructure] 的产物；不含字节、不含闭包）。
class EpubSectionRef {
  const EpubSectionRef({
    required this.id,
    required this.href,
    this.linear = true,
  });

  /// OPF manifest 中的 id。
  final String id;

  /// 归一化后的包内路径，例如 `OEBPS/text/ch1.xhtml`。
  final String href;

  /// spine 的 `linear` 属性：`linear="no"`（非主线内容，如注释/答案/勘误）为 `false`。
  ///
  /// `CNT-05`：非主线章节**不再剔除**，而是保留进 [EpubStructure.sections]
  /// 并以本标记区分，由消费方（`DartEpubSource.chapters()`）在章节表标注
  /// 「（非主线）」展示。属性缺省（未写）视为 `true`（主线阅读内容）。
  final bool linear;
}

/// [parseEpubStructure] 的返回：**纯数据、无闭包**，可跨 isolate（`compute()` / IsolateRunner）。
///
/// ⚠️ 与 [EpubParseResult] 不同：本结构**不含任何字节、也不含任何闭包**——章节正文与封面候选
/// 字节都要由**取得本结构的 isolate**（通常主 isolate，它持有原始 `bytes`）再按需读取。
/// 闭包（`readEntry` / `loadBytes`）**不可**跨 isolate 传递，会被 `SendPort` 拒绝；
/// 这正是它把「结构」与「绑定」拆开的原因。
class EpubStructure {
  const EpubStructure({
    required this.title,
    required this.author,
    required this.language,
    required this.description,
    required this.creators,
    required this.fileName,
    required this.sections,
    required this.toc,
    required this.coverCandidates,
    required this.entryNames,
    this.flatTitles = const <String, String>{},
  });

  /// `dc:title`（首个非空）；无则空串。
  final String title;

  /// `dc:creator`（首个非空）；无则空串。
  final String author;

  /// `dc:language`；无则空串。
  final String language;

  /// `dc:description`（简介；`META-01` 的 `intro` 来源）。
  final String description;

  /// `dc:creator` **多值**，**稳定顺序整体保留**（`META-03` / `Q17`）；不切分。
  final List<String> creators;

  /// 原始文件名（书名缺失时兜底显示）。
  final String fileName;

  /// spine 顺序的章节引用（已剔除非文本资源）。
  ///
  /// `CNT-05`：`linear="no"` 的非主线章节**保留**在此并标 [EpubSectionRef.linear]
  /// 为 `false`，由消费方在章节表标注「（非主线）」展示。
  final List<EpubSectionRef> sections;

  /// 目录（`RD-01`）；**空列表表示无可用目录**，调用方降级为「按 spine 生成平坦目录」。
  final List<Chapter> toc;

  /// 封面候选（`META-02` 四来源，**已按优先级排序**，命中即停）。
  final List<CoverCandidate> coverCandidates;

  /// 包内条目名索引：`小写真实名 -> 真实名`（供取得结构的 isolate 重新定位条目）。
  final Map<String, String> entryNames;

  /// 平坦目录预取标题表（`PERF-01` 残余项）：`章 href -> 章标题`，**仅 toc 为空时填充**。
  ///
  /// 与 [toc] 的降级语义配套：无目录书的平坦目录标题取自每章正文 h1，若留到消费方
  /// （`DartEpubSource.chapters()`）现场逐章「解压 + HTML 解析」会冻结主 isolate，
  /// 故在解析 isolate（[_parse]）一次取好、**字节即弃**只留字符串。值为空串 = 已预取
  /// 但无标题；查不到键 = 未预取，消费方回退现场取（见 `EpubBook.flatTitles`）。
  final Map<String, String> flatTitles;

  /// 封面候选 href 列表（`coverCandidates` 的 href 投影，便于只看路径的调用方）。
  List<String> get coverCandidateHrefs =>
      coverCandidates.map((CoverCandidate c) => c.href).toList();
}

/// `lib/meta/epub_meta.dart`（纯 Dart）消费的 OPF 视图（架构 §N.4 动作项 D1）。
///
/// 与 [EpubBook] **同一次解析**产出——复用已打开的 zip 归档，**不重复解压**。
/// 它只承载「元数据提取所需的少量信息」，不持有整本条目表：
/// [readEntry] 只覆盖封面候选相关的少量条目字节（最多 4 张图），
/// 避免 `PERF-01` 下把整本解压结果钉在内存里。
class OpfView {
  const OpfView({
    required this.title,
    required this.creators,
    required this.language,
    required this.description,
    required this.coverCandidates,
    required this.readEntry,
  });

  /// `dc:title`（首个非空）；无则 `null`。
  final String? title;

  /// `dc:creator` **多值**，**稳定顺序整体保留**（`META-03` / `Q17`）；不切分。
  final List<String> creators;

  /// `dc:language`；无则 `null`。
  final String? language;

  /// `dc:description`（简介；`META-01` 的 `intro` 字段来源）。
  ///
  /// **§N.4 的代码草案未列本字段——属显式增补**：§N.3 要求 `BookMeta.intro`
  /// 在导入时一次性写入并给出来源标记，而 intro 的内嵌来源正是 OPF 的 `dc:description`。
  final String? description;

  /// 封面候选（`META-02` 四来源，**已按优先级排序**，命中即停）。
  final List<CoverCandidate> coverCandidates;

  /// 读包内条目字节（封面命中即停时用）——**按需解压、不常驻**（`PERF-02`）。
  final Uint8List? Function(String href)? readEntry;
}

/// `parseEpubResult` 的返回：结构与元数据视图**同一次解析**产出。
///
/// ⚠️ **不可跨 isolate**（内含 `readEntry` 闭包）——要 `compute()` 请走 [parseEpubStructure]。
class EpubParseResult {
  const EpubParseResult({required this.book, required this.opfView});

  final EpubBook book;
  final OpfView opfView;
}

/// 把一个 EPUB 字节流解析成 [EpubBook]。
///
/// 步骤：
/// 1. 解 zip；
/// 2. 读 `META-INF/container.xml` 找出 OPF 的真实路径（**绝不硬编码** `OEBPS/content.opf`）；
/// 3. 解析 OPF 的 metadata / manifest / spine；
/// 4. **加密检测**（读 `META-INF/encryption.xml`，`RD-05`）——必须在返回可读章节之前；
/// 5. 解析目录（EPUB3 nav / EPUB2 ncx 双路径，`RD-01`）；
/// 6. 按 spine 顺序取出各章引用（正文按需解压）。
///
/// 失败一律抛 [MReaderFormatException]，消息可读。
Future<EpubBook> parseEpub(Uint8List bytes, {String fileName = ''}) async {
  final EpubParseResult result =
      await parseEpubResult(bytes, fileName: fileName);
  return result.book;
}

/// **结构解析（纯数据、可跨 isolate）**——把 EPUB 字节流解析成 [EpubStructure]。
///
/// 只产出「结构 + 元数据 + 目录 + 封面候选 + 条目名索引」，**不含任何闭包或解压结果**，
/// 故可安全丢进 `compute()` / `IsolateRunner`（`PERF-01` / `PERF-02` ①）。
///
/// 要拿到带 `loadBytes` / `readEntry` 的 [EpubBook] / [OpfView]，请在**取得本结构的
/// isolate** 上调用 [parseEpubResult]（或按 `entryNames` 自行绑定）。
Future<EpubStructure> parseEpubStructure(
  Uint8List bytes, {
  String fileName = '',
}) async =>
    _parse(bytes, fileName).structure;

/// 与 [parseEpub] 相同，但额外返回 [OpfView]（供 `lib/meta/epub_meta.dart` 消费）。
///
/// 内部 = [_parse]（与 [parseEpubStructure] **共用同一个核心**，故只解一次 zip）+
/// **在调用方 isolate 上**绑定出 [EpubBook] 的 `loadBytes` 与 [OpfView] 的 `readEntry`。
///
/// ⚠️ **返回值不可跨 isolate**：两个绑定字段都是闭包，`SendPort` 会拒绝。
/// 要移出主 isolate，请用 [parseEpubStructure]（纯数据）在后台解析，再回主 isolate 绑定。
Future<EpubParseResult> parseEpubResult(
  Uint8List bytes, {
  String fileName = '',
}) async {
  final _ParsedEpub parsed = _parse(bytes, fileName);
  return EpubParseResult(
    book: _bindBook(parsed),
    opfView: _bindOpfView(parsed),
  );
}

// ---------------------------------------------------------------------------
// PERF-01（M2a-T06）：isolate 任务入口（纯数据） + 主 isolate 绑定
// ---------------------------------------------------------------------------

/// [parseEpubStructureTask] 的入参（纯数据，可跨 isolate）。
class EpubParseRequest {
  const EpubParseRequest(this.bytes, {this.fileName = ''});

  /// EPUB 的完整字节。
  final Uint8List bytes;

  /// 原始文件名（书名缺失时兜底显示）。
  final String fileName;
}

/// [parseEpubStructureTask] 的返回信封（纯数据，可跨 isolate）。
///
/// 不变量：[structure] 与 [error] **恰一非空**。业务错误（[MReaderFormatException]）
/// 经信封传递而非 throw —— 让 `IsolateRunner.runWithFallback` 能把「业务错误」与
/// 「派发失败 / 远端意外」分开处理（只有后者才回落本 isolate 重跑）。
class EpubParseOutcome {
  /// 解析成功：携带纯数据结构。
  const EpubParseOutcome.ok(this.structure) : error = null;

  /// 业务失败（坏文件 / 加密等）：携带原样错误，由调用方 rethrow。
  const EpubParseOutcome.failed(this.error) : structure = null;

  /// 纯数据结构（成功时非空）。
  final EpubStructure? structure;

  /// 业务错误（失败时非空）。
  final MReaderFormatException? error;
}

/// `PERF-01` 的 **isolate 任务入口**（顶层纯函数，供 `IsolateRunner` 派发）。
///
/// 只跑 [parseEpubStructure]（纯数据、无闭包）；业务错误收进 [EpubParseOutcome] 信封。
/// 取得结构后，由**持有原始 `bytes` 的 isolate** 调 [bindEpubResult] 绑定闭包。
Future<EpubParseOutcome> parseEpubStructureTask(
  EpubParseRequest request,
) async {
  final Stopwatch clock = Stopwatch()..start();
  try {
    final EpubStructure structure =
        await parseEpubStructure(request.bytes, fileName: request.fileName);
    // 耗时日志（后台 isolate 内打印同样落 stdout）：结构解析总时长 +
    // 章节数 / 目录数（无目录书 flatTitles 的分账见 _parse 第 8 步）。
    PerfLog.step('epub.parse', clock.elapsedMilliseconds,
        'bytes=${request.bytes.length} sections=${structure.sections.length} '
        'toc=${structure.toc.length}');
    return EpubParseOutcome.ok(structure);
  } on MReaderFormatException catch (e) {
    return EpubParseOutcome.failed(e);
  }
}

/// **绑定（本 isolate）**——把 [parseEpubStructure] 的纯数据产物绑定成带闭包的
/// [EpubParseResult]（`PERF-01` 后半程：结构在后台 isolate 解析、绑定在持有原始
/// [bytes] 的 isolate 进行，闭包从不跨 isolate）。
///
/// 内部重新解一次 zip，只为取「条目名 → ArchiveFile」句柄：中央目录扫描 O(条目数)、
/// **不解压**——`PERF-02` ① 的按需、非驻留解压语义不变（索引构建与 [_parse] 同构）。
EpubParseResult bindEpubResult(Uint8List bytes, EpubStructure structure) {
  final Archive? archive = tryDecodeZip(bytes);
  if (archive == null) {
    // 病态情形：后台刚解析成功、本侧重解却失败。与 [_parse] 的 zip 失败同码。
    throw const MReaderFormatException(FormatErrorCode.notZip);
  }
  final Map<String, ArchiveFile> byName = <String, ArchiveFile>{};
  final Map<String, String> lowerIndex = <String, String>{};
  for (final ArchiveFile f in archive.files) {
    if (!f.isFile) continue;
    final String name = normalizeZipPath(f.name);
    if (name.isEmpty) continue;
    byName[name] = f;
    lowerIndex[name.toLowerCase()] = name;
  }
  final _ParsedEpub parsed = _ParsedEpub(
    structure: structure,
    byName: byName,
    lowerIndex: lowerIndex,
  );
  return EpubParseResult(
    book: _bindBook(parsed),
    opfView: _bindOpfView(parsed),
  );
}

// ---------------------------------------------------------------------------
// 核心解析：结构（纯数据） + 本 isolate 的归档句柄
// ---------------------------------------------------------------------------

/// 解析中间产物：结构（纯数据） + **本 isolate 内**的归档句柄（绑定闭包用，不跨 isolate）。
class _ParsedEpub {
  _ParsedEpub({
    required this.structure,
    required this.byName,
    required this.lowerIndex,
  });

  final EpubStructure structure;

  /// `真实条目名 -> ArchiveFile`（**未解压**，`PERF-02` ①）。
  final Map<String, ArchiveFile> byName;

  /// `小写条目名 -> 真实条目名`（大小写不敏感命中用）。
  final Map<String, String> lowerIndex;
}

/// 核心解析（同步）：产出 [EpubStructure] + 本 isolate 的归档句柄。
_ParsedEpub _parse(Uint8List bytes, String fileName) {
  if (bytes.isEmpty) {
    throw const MReaderFormatException(FormatErrorCode.emptyFile);
  }

  final Archive? archive = tryDecodeZip(bytes);
  if (archive == null) {
    throw const MReaderFormatException(FormatErrorCode.notZip);
  }

  // 建立包内路径索引。EPUB 内部一律使用 '/'，但可能出现 './' 前缀或重复斜杠。
  //
  // ⚠️ `PERF-02` ①（内存收敛）：**只建「条目名 → ArchiveFile」索引，绝不预解压字节**。
  //    archive 3.x 的 `ArchiveFile.content` 是按需解压（且**一次解压即永久缓存** `_content`）；
  //    一旦在此对所有条目求 `.content`（旧实现 `files[name] = contentOfArchiveFile(f)` 正是如此），
  //    就会把整本（含图片 / 字体 / CSS）一次性解压并常驻——这正是要消除的。改为按需解压后，
  //    **非章节资源（图 / 字 / CSS）在与正文无关的路径上永不读取、保持压缩态**。
  final Map<String, ArchiveFile> byName = <String, ArchiveFile>{};
  final Map<String, String> lowerIndex = <String, String>{};
  for (final ArchiveFile f in archive.files) {
    if (!f.isFile) continue;
    final String name = normalizeZipPath(f.name);
    if (name.isEmpty) continue;
    byName[name] = f;
    lowerIndex[name.toLowerCase()] = name;
  }

  /// 供本函数与 [parseToc] 共用的命中逻辑（大小写不敏感 + 百分号三试探）；
  /// 命中真实条目名后**按需解压**该条目（其余条目保持压缩态）。
  Uint8List? lookup(String packagePath) {
    final String? name = resolveEntryName(lowerIndex, packagePath);
    if (name == null) return null;
    final ArchiveFile? file = byName[name];
    if (file == null) return null;
    return contentOfArchiveFile(file);
  }

  // 1) container.xml -> OPF 路径
  final Uint8List? containerBytes = lookup('META-INF/container.xml');
  if (containerBytes == null) {
    throw const MReaderFormatException(FormatErrorCode.missingContainer);
  }

  final XmlDocument? containerDoc = tryParseXml(decodeText(containerBytes));
  if (containerDoc == null) {
    throw const MReaderFormatException(FormatErrorCode.badContainerXml);
  }

  String? opfPath;
  for (final XmlElement el in findAllByLocalName(containerDoc, 'rootfile')) {
    final String? full = el.getAttribute('full-path');
    if (full != null && full.trim().isNotEmpty) {
      opfPath = normalizeZipPath(full);
      break;
    }
  }
  if (opfPath == null || opfPath.isEmpty) {
    throw const MReaderFormatException(FormatErrorCode.missingOpf);
  }

  final Uint8List? opfBytes = lookup(opfPath);
  if (opfBytes == null) {
    throw MReaderFormatException(
      FormatErrorCode.corruptFile,
      detail: 'OPF 不存在于包内：$opfPath',
    );
  }

  final XmlDocument? opfDoc = tryParseXml(decodeText(opfBytes));
  if (opfDoc == null) {
    throw MReaderFormatException(FormatErrorCode.badOpf, detail: opfPath);
  }

  // OPF 所在目录，作为 manifest href 的相对基准。
  final String opfDir = p.posix.dirname(opfPath);

  // 2) metadata（按 localName 匹配，兼容各种命名空间前缀写法）
  final String title = firstLocalizedText(opfDoc, 'title');
  final String author = firstLocalizedText(opfDoc, 'creator');
  final String language = firstLocalizedText(opfDoc, 'language');
  final String description = firstLocalizedText(opfDoc, 'description');

  /// `dc:creator` 的**多值、稳定顺序**列表（`META-03` / `Q17`）。
  final List<String> creators = <String>[];
  for (final XmlElement el in findAllByLocalName(opfDoc, 'creator')) {
    final String text = collapsedText(el);
    if (text.isNotEmpty) creators.add(text);
  }

  // 3) manifest：id -> href / media-type
  final Map<String, String> idToHref = <String, String>{};
  final Map<String, String> idToMediaType = <String, String>{};
  for (final XmlElement item in findAllByLocalName(opfDoc, 'item')) {
    final String? id = item.getAttribute('id');
    final String? href = item.getAttribute('href');
    if (id == null || href == null || href.trim().isEmpty) continue;
    idToHref[id] = resolveHref(opfDir, href);
    final String? mediaType = item.getAttribute('media-type');
    if (mediaType != null) idToMediaType[id] = mediaType;
  }

  // 4) 加密检测（RD-05）：必须在返回任何可读章节之前。
  _rejectEncryptedEpub(lookup, idToHref, idToMediaType);

  // 5) 目录（RD-01）：无目录时返回空列表，由调用方降级为平坦目录。
  //    目录项类型就是全项目唯一的 Chapter（见 lib/model/chapter.dart）。
  final List<Chapter> toc =
      parseToc(opfDoc: opfDoc, opfDir: opfDir, lookup: lookup);

  // 6) spine：阅读顺序 —— **只记录 id/href 引用**，正文留给绑定期按需解压（`PERF-02` ①）。
  //    `linear="no"`（非主线内容）**保留**进列表并标 `linear: false`（`CNT-05`：
  //    章节表可见并标注「（非主线）」）；资源过滤对它**照常执行**——图片/字体/CSS
  //    即使标了 `linear="no"` 也不当章节。
  final List<EpubSectionRef> sectionRefs = <EpubSectionRef>[];
  for (final XmlElement itemref in findAllByLocalName(opfDoc, 'itemref')) {
    final String? linear = itemref.getAttribute('linear');
    final bool isLinear = !(linear != null && linear.toLowerCase() == 'no');
    final String? idref = itemref.getAttribute('idref');
    if (idref == null) continue;

    final String? href = idToHref[idref];
    if (href == null) continue;

    final ArchiveFile? file = _resolveFile(byName, lowerIndex, href);
    if (file == null) continue; // 资源缺失：优雅跳过，不让整本书解析失败。

    // 图片 / 字体 / CSS 等资源**不当章节**。
    // media-type 缺失时用扩展名 + 字节魔数兜底（现实里封面图常被塞进 spine 且漏写 media-type）。
    final String? mediaType = idToMediaType[idref];
    final bool? verdict = textualVerdict(mediaType, href);
    if (verdict == false) continue; // 明确非文本：不解压直接跳过。
    if (verdict == null) {
      // 声明不足（无 media-type 且扩展名不暴露）：需解压该**单个**条目做字节魔数兜底。
      if (!looksTextual(mediaType, href, contentOfArchiveFile(file))) continue;
    }
    sectionRefs.add(EpubSectionRef(id: idref, href: href, linear: isLinear));
  }

  if (sectionRefs.isEmpty) {
    throw const MReaderFormatException(FormatErrorCode.emptySpine);
  }

  // 7) 封面候选（META-02 四来源，已按优先级排序）——只解析出 href，**不预解压**（绑定期按需）。
  final List<CoverCandidate> coverCandidates =
      _buildCoverCandidates(opfDoc, opfDir, idToHref, idToMediaType);

  // 8) 平坦目录预取标题（PERF-01 残余项）：**仅无目录的书**填充 `href -> 标题`。
  //    无目录书的章节表降级为「按 spine 平坦目录」，标题取自每章正文的 h1；若留到
  //    `DartEpubSource.chapters()` 现场逐章「解压 + HTML 解析」，大书会把主 isolate
  //    冻住（perf-bench big_bodies 3996ms 实测）。这里是 PERF-02 ①「绝不预解压」的
  //    **唯一有界例外**：逐章经 lazyEntryLoader **非缓存**解压取 title 后**字节即弃**
  //    （不走 ArchiveFile.content——它一次解压即永久缓存，会让整本驻留），只留字符串。
  //    空标题也存（= 已预取但无标题）；缺文件的章跳过（与绑定期 _bindBook 过滤一致，
  //    键用 href 不用索引，天然不错位）。
  final Map<String, String> flatTitles = <String, String>{};
  if (toc.isEmpty) {
    // 耗时日志：无目录书的标题预取是「打开」的已知大户（逐章解压 + XHTML 解析），
    // 单独分账——真机若在此处出现秒级耗时即命中该路径（挂账 #6）。
    final Stopwatch flatClock = Stopwatch()..start();
    for (final EpubSectionRef ref in sectionRefs) {
      final ArchiveFile? file = _resolveFile(byName, lowerIndex, ref.href);
      if (file == null) continue;
      flatTitles[ref.href] = extractSection(lazyEntryLoader(file)()).title;
    }
    PerfLog.step('epub.flatTitles', flatClock.elapsedMilliseconds,
        'sections=${sectionRefs.length}');
  }

  final EpubStructure structure = EpubStructure(
    title: title,
    author: author,
    language: language,
    description: description,
    creators: creators,
    fileName: fileName,
    sections: sectionRefs,
    toc: toc,
    coverCandidates: coverCandidates,
    entryNames: lowerIndex,
    flatTitles: flatTitles,
  );

  return _ParsedEpub(
    structure: structure,
    byName: byName,
    lowerIndex: lowerIndex,
  );
}

// ---------------------------------------------------------------------------
// 绑定：结构（纯数据） -> 带闭包的 EpubBook / OpfView（**仅在本 isolate 内有效**）
// ---------------------------------------------------------------------------

/// 按包内路径定位归档条目（**不解压**）。
ArchiveFile? _resolveFile(
  Map<String, ArchiveFile> byName,
  Map<String, String> lowerIndex,
  String packagePath,
) {
  final String? name = resolveEntryName(lowerIndex, packagePath);
  return name == null ? null : byName[name];
}

/// 把结构绑定成 [EpubBook]：每章挂一个**按需、非驻留**的 `loadBytes`（`PERF-02` ①）。
EpubBook _bindBook(_ParsedEpub parsed) {
  final EpubStructure s = parsed.structure;
  final List<EpubSection> sections = <EpubSection>[];
  for (final EpubSectionRef ref in s.sections) {
    final ArchiveFile? file = _resolveFile(parsed.byName, parsed.lowerIndex, ref.href);
    if (file == null) continue;
    sections.add(EpubSection.lazy(
      id: ref.id,
      href: ref.href,
      loadBytes: lazyEntryLoader(file),
      linear: ref.linear,
    ));
  }
  return EpubBook(
    title: s.title,
    author: s.author,
    language: s.language,
    fileName: s.fileName,
    sections: sections,
    toc: s.toc,
    flatTitles: s.flatTitles,
  );
}

/// 把结构绑定成 [OpfView]：`readEntry` **按需解压封面候选**（不再一次性解压常驻全部候选）。
OpfView _bindOpfView(_ParsedEpub parsed) {
  final EpubStructure s = parsed.structure;
  return OpfView(
    title: s.title.isEmpty ? null : s.title,
    creators: s.creators,
    language: s.language.isEmpty ? null : s.language,
    description: s.description.isEmpty ? null : s.description,
    coverCandidates: s.coverCandidates,
    readEntry: (String href) {
      final ArchiveFile? file =
          _resolveFile(parsed.byName, parsed.lowerIndex, href);
      if (file == null) return null;
      return lazyEntryLoader(file)();
    },
  );
}

// ---------------------------------------------------------------------------
// 封面候选（META-02 四来源，有序、命中即停）
// ---------------------------------------------------------------------------

/// 图片扩展名（④ 文件名兜底用）。
const Set<String> _imageExtensions = <String>{
  'jpg', 'jpeg', 'jpe', 'png', 'gif', 'bmp', 'webp',
  'tif', 'tiff', 'avif', 'heic', 'apng', 'svg',
};

/// 按 `META-02` 的**显式优先级**收集封面候选（去重，命中即停由消费方保证）：
/// ① OPF `<meta name="cover" content="id">` 指向的 manifest item；
/// ② manifest item 的 `properties` 含 `cover-image`（EPUB3 最常见）；
/// ③ guide `<reference type="cover" href>`；
/// ④ 文件名含 `cover` 的图片项。
///
/// **禁止用无序集合存放多来源**（否则结果依赖遍历顺序，`META-02`）——
/// 这里用**有序 List + 去重 Set**。
List<CoverCandidate> _buildCoverCandidates(
  XmlDocument opfDoc,
  String opfDir,
  Map<String, String> idToHref,
  Map<String, String> idToMediaType,
) {
  final List<CoverCandidate> out = <CoverCandidate>[];
  final Set<String> seen = <String>{};

  void add(String? href, String source) {
    final String key = (href ?? '').trim();
    if (key.isEmpty) return;
    if (!seen.add(key)) return;
    out.add(CoverCandidate(href: key, source: source));
  }

  // ① <meta name="cover" content="id">
  for (final XmlElement meta in findAllByLocalName(opfDoc, 'meta')) {
    final String name = (meta.getAttribute('name') ?? '').trim().toLowerCase();
    if (name != 'cover') continue;
    final String? content = meta.getAttribute('content');
    if (content == null) continue;
    add(idToHref[content.trim()], 'opf-meta-cover');
  }

  // ② properties 含 cover-image
  for (final XmlElement item in findAllByLocalName(opfDoc, 'item')) {
    final String props = (item.getAttribute('properties') ?? '').toLowerCase();
    if (props.isEmpty) continue;
    final List<String> tokens = props.split(RegExp(r'\s+'));
    if (!tokens.contains('cover-image')) continue;
    final String? id = item.getAttribute('id');
    if (id == null) continue;
    add(idToHref[id], 'properties-cover-image');
  }

  // ③ guide <reference type="cover" href>
  for (final XmlElement ref in findAllByLocalName(opfDoc, 'reference')) {
    final String type = (ref.getAttribute('type') ?? '').trim().toLowerCase();
    if (type != 'cover') continue;
    final String? href = ref.getAttribute('href');
    if (href == null) continue;
    add(resolveHref(opfDir, href), 'guide-cover');
  }

  // ④ 文件名含 cover 的图片项
  for (final XmlElement item in findAllByLocalName(opfDoc, 'item')) {
    final String? id = item.getAttribute('id');
    final String? href = item.getAttribute('href');
    if (id == null || href == null) continue;
    final String mediaType = (idToMediaType[id] ?? '').toLowerCase().trim();
    final String path =
        normalizeZipPath(decodePercentPath(href)).toLowerCase();
    final String base = path.split('/').last;
    if (!base.contains('cover')) continue;
    if (!_looksImage(mediaType, path)) continue;
    add(idToHref[id], 'filename-cover');
  }

  return out;
}

/// [mediaType] / [path]（小写）是否像图片。
bool _looksImage(String mediaType, String path) {
  if (mediaType.startsWith('image/')) return true;
  final int dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return false;
  return _imageExtensions.contains(path.substring(dot + 1));
}

// ---------------------------------------------------------------------------
// 加密检测（RD-05）
// ---------------------------------------------------------------------------

/// IDPF / Adobe 的**字体混淆**算法：DRM-free 书给内嵌字体做的混淆，**不算加密**。
const Set<String> _fontObfuscationAlgorithms = <String>{
  'http://www.idpf.org/2008/embedding', // IDPF 字体混淆
  'http://ns.adobe.com/pdf/enc#RC', // Adobe 字体混淆
};

/// 字体资源扩展名。
const Set<String> _fontExtensions = <String>{
  'otf', 'ttf', 'ttc', 'woff', 'woff2',
};

/// 检测 `META-INF/encryption.xml` 并拒绝真正加密的书。
///
/// 判定规则（**逐条对齐 `RD-05`**，务必不要误杀正常书）：
/// 1. `encryption.xml` **不存在 → 不加密**；
/// 2. 存在时逐个看 `<EncryptedData>`，取其 `<EncryptionMethod Algorithm>` 与
///    `<CipherReference URI>`；
/// 3. `Algorithm` 属字体混淆（IDPF / Adobe）→ **不算加密**；
/// 4. 被加密目标是**字体资源**（扩展名，或 manifest 里 media-type 为字体）→ **不算加密**；
/// 5. 其余情况（非字体目标 + 非字体混淆算法）→ 判为加密，抛 [FormatErrorCode.encryptedEpub]。
void _rejectEncryptedEpub(
  Uint8List? Function(String path) lookup,
  Map<String, String> idToHref,
  Map<String, String> idToMediaType,
) {
  final Uint8List? encBytes = lookup('META-INF/encryption.xml');
  if (encBytes == null) return; // 规则 1：不存在 -> 不加密

  final XmlDocument? doc = tryParseXml(decodeText(encBytes));
  if (doc == null) {
    // encryption.xml 自己都解不开：不作为加密证据（避免把脏书误判为加密而拒开）。
    return;
  }

  for (final XmlElement data in findAllByLocalName(doc, 'EncryptedData')) {
    final String algorithm =
        (firstAttributeIn(data, 'EncryptionMethod', 'Algorithm') ?? '').trim();
    final String uri =
        (firstAttributeIn(data, 'CipherReference', 'URI') ?? '').trim();

    // 规则 3：字体混淆算法 -> 不算加密。
    if (_fontObfuscationAlgorithms.contains(algorithm)) continue;

    // 规则 4：目标是字体 -> 不算加密。
    if (_isFontResource(uri, idToHref, idToMediaType)) continue;

    // 规则 5：判为加密。detail 只给调试用的资源 URI。
    throw MReaderFormatException(
      FormatErrorCode.encryptedEpub,
      detail: uri.isEmpty ? null : 'encrypted: $uri',
    );
  }
}

/// [uri]（`<CipherReference URI>`，包内相对路径）是否指向字体资源。
bool _isFontResource(
  String uri,
  Map<String, String> idToHref,
  Map<String, String> idToMediaType,
) {
  final String target = resolveHref('', uri).toLowerCase();
  if (target.isEmpty) return false;

  final int dot = target.lastIndexOf('.');
  if (dot >= 0 && dot < target.length - 1) {
    if (_fontExtensions.contains(target.substring(dot + 1))) return true;
  }

  for (final MapEntry<String, String> entry in idToHref.entries) {
    if (entry.value.toLowerCase() != target) continue;
    final String mediaType =
        (idToMediaType[entry.key] ?? '').toLowerCase().trim();
    if (mediaType.startsWith('font/')) return true;
    if (mediaType.startsWith('application/font')) return true;
    if (mediaType.startsWith('application/x-font')) return true;
    if (mediaType == 'application/vnd.ms-opentype') return true;
  }
  return false;
}
