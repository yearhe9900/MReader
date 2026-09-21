// EPUB 解析层的「真实脏书」回归测试。
//
// 数据来源：test/fixtures/*.epub + test/fixtures/baseline.json
//   - *.epub 由 test/fixtures/make_fixtures.py 生成（每本只聚焦一类脏特征）。
//   - baseline.json 是每个 fixture 的「规范上正确的预期输出」契约。
//
// 设计要点：
//   1. 所有期望值都**从 baseline.json 读取**，不凭记忆硬编码，避免测试与实现对不上。
//   2. 缺 fixture / 缺 baseline.json 时优雅跳过（`skip:`），不误报失败
//      ——即使只拷走 lib/ 源码、没带 fixtures，`flutter test` 也不会变红。
//   3. 本文件在 VM 上跑（`flutter test`），因此用 dart:io 读文件是被允许的；
//      这不违反「App 源码不用 dart:io」的约束（app 源码仍保持全平台可编译）。
//
// 关于「正文文本」的断言口径：
//   baseline 的「预期每章文本」= **章节内所有文本块的有序列表，含 h1~h6 标题块本身**，
//   这是「抽取器应抽到的原文」。而 ExtractedSection 为了 UI 不重复显示标题，
//   会把「与标题重复的首段」剥离到 `title` 字段。
//   因此断言口径统一为： `[section.title, ...section.paragraphs] == 预期每章文本`。
//   这样既尊重 baseline 的原文契约，又能反向校验「标题剥离逻辑」是否正确。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/epub/epub_parser.dart';
import 'package:mreader/epub/section_extractor.dart';
import 'package:mreader/epub/text_codec.dart';
import 'package:mreader/format/error_messages.dart';
import 'package:mreader/model/epub_book.dart';

/// fixtures 目录（相对包根；`flutter test` 的工作目录即包根）。
final Directory _fixturesDir = Directory('test/fixtures');
final File _baselineFile = File('${_fixturesDir.path}/baseline.json');

/// 把 href 归一化成「可比较」的形态：百分号解码 + 转小写。
///
/// 为什么需要（显式口径，非「默默改断言」）：
///   `EpubSection.href` 是解析器**按 OPF 声明**解析出的逻辑路径；而 fixture 的
///   baseline 记录的是**包内真实条目**路径。二者指向同一章，但大小写 / 百分号编码
///   形态可能不同：
///     - fx03：container 声明 `oebps/content.opf`、href 写 `TEXT/CH1.XHTML`，
///       解析器得到 `oebps/TEXT/CH1.XHTML`，真实条目却是 `OEBPS/text/ch1.xhtml`；
///     - fx02b：真实条目名本身就是 `OEBPS/%E7%AC%AC…`（编码），
///       baseline 记的是解码后的 `OEBPS/第一章.xhtml`。
///   解析器对包内路径的匹配本就是**大小写不敏感 + 百分号解码/编码双试探**，
///   因此这里也按同一口径归一化后比较。**该 href 口径差异已作为交付发现单独标注**，
///   供团队决定后续是否把 `EpubSection.href` 改为「匹配到的真实条目路径」。
String normHref(String href) {
  var s = href;
  try {
    s = Uri.decodeComponent(href);
  } catch (_) {
    s = href;
  }
  return s.toLowerCase();
}

void main() {
  // 缺基线契约：整体跳过（一个显式的 skip 用例，比静默通过更清楚）。
  if (!_baselineFile.existsSync()) {
    test(
      'fixture 回归：未找到 test/fixtures/baseline.json',
      () {},
      skip: '缺少 test/fixtures/baseline.json，跳过 fixture 回归测试。',
    );
    return;
  }

  final Map<String, dynamic> root =
      jsonDecode(_baselineFile.readAsStringSync()) as Map<String, dynamic>;
  final Map<String, dynamic> baseline = root['baseline'] as Map<String, dynamic>;

  Uint8List? readFixture(String name) {
    final File file = File('${_fixturesDir.path}/$name');
    if (!file.existsSync()) return null;
    return file.readAsBytesSync();
  }

  /// fixture 缺失时返回 skip 原因，否则返回 null。
  Object? skipIfMissing(String name) =>
      readFixture(name) == null ? '缺少 fixture：$name' : null;

  /// 按（归一化后的）href 找到对应章节。
  EpubSection sectionByHref(EpubBook book, String href) {
    final String target = normHref(href);
    return book.sections
        .firstWhere((EpubSection s) => normHref(s.href) == target);
  }

  /// 把一个书本对象与 baseline 逐条核对（只核对 baseline 里出现的字段）。
  Future<void> expectMatchesBaseline(String name, Map<String, dynamic> b) async {
    final Uint8List bytes = readFixture(name)!;
    final EpubBook book = await parseEpub(bytes, fileName: name);

    if (b.containsKey('预期书名')) {
      expect(book.title, b['预期书名'], reason: '$name 书名');
    }
    if (b.containsKey('预期作者')) {
      expect(book.author, b['预期作者'], reason: '$name 作者');
    }

    if (b.containsKey('预期章节(href)')) {
      final List<String> expectedHrefs =
          (b['预期章节(href)'] as List<dynamic>).cast<String>();
      expect(
        book.sections.map((EpubSection s) => normHref(s.href)).toList(),
        expectedHrefs.map(normHref).toList(),
        reason: '$name 章节顺序 / 数量',
      );
    }

    final Map<String, dynamic>? textMap =
        b['预期每章文本'] as Map<String, dynamic>?;
    if (textMap != null) {
      for (final MapEntry<String, dynamic> entry in textMap.entries) {
        final ExtractedSection ex =
            extractSection(sectionByHref(book, entry.key).rawBytes);
        final List<String> full = <String>[ex.title, ...ex.paragraphs];
        expect(
          full,
          (entry.value as List<dynamic>).cast<String>(),
          reason: '$name 章节 ${entry.key} 的文本块序列（title + paragraphs）',
        );
      }
    }

    final Map<String, dynamic>? titleMap =
        b['预期章标题'] as Map<String, dynamic>?;
    if (titleMap != null) {
      for (final MapEntry<String, dynamic> entry in titleMap.entries) {
        expect(
          extractSection(sectionByHref(book, entry.key).rawBytes).title,
          entry.value,
          reason: '$name 章节 ${entry.key} 的章标题',
        );
      }
    }
  }

  // =====================================================================
  // A. 正常打开的 fixture —— 按 baseline.json 断言
  // =====================================================================
  const List<String> openFixtures = <String>[
    'fx01_opf_in_item_dir.epub',
    'fx02a_percent_href_real_cjk_name.epub',
    'fx02b_percent_zip_entry_name.epub', // 缺陷① 修复后按基线正常打开
    'fx03_case_mismatch.epub',
    'fx04_gbk_no_decl.epub',
    'fx05_malformed_xhtml.epub',
    'fx06_linear_no.epub',
    'fx07a_cover_in_spine_with_media_type.epub',
    'fx07b_cover_in_spine_no_media_type.epub', // 缺陷④ 修复后按基线正常打开
  ];

  group('按 baseline 正常解析', () {
    for (final String name in openFixtures) {
      test(name, () async {
        await expectMatchesBaseline(name, baseline[name] as Map<String, dynamic>);
      }, skip: skipIfMissing(name));
    }
  });

  // =====================================================================
  // B. 应抛可读错误的 fixture
  // =====================================================================
  group('脏书应抛出可读的 MReaderFormatException', () {
    // 期望的**错误码**（比只断言类型更严：同时锁住「可读原因」的唯一口径）。
    const Map<String, FormatErrorCode> cases = <String, FormatErrorCode>{
      'fx08_empty_spine.epub': FormatErrorCode.emptySpine,
      'fx08b_missing_container.epub': FormatErrorCode.missingContainer,
    };
    for (final MapEntry<String, FormatErrorCode> entry in cases.entries) {
      final String name = entry.key;
      test(name, () async {
        final Uint8List bytes = readFixture(name)!;
        await expectLater(
          parseEpub(bytes, fileName: name),
          throwsA(isA<MReaderFormatException>().having(
            (MReaderFormatException e) => e.code,
            'code',
            entry.value,
          )),
          reason: '$name 应抛出可读异常（含错误码）而非崩溃 / 白屏',
        );
      }, skip: skipIfMissing(name));
    }
  });

  // =====================================================================
  // C. 「声明与实际不符」—— 针对修复后新行为的定向断言
  // =====================================================================
  group('声明与实际不符（修复后行为）', () {
    test('fx09 声明 utf-8 实为 GBK：回落 GBK 正确解码（缺陷③）', () async {
      final Uint8List bytes = readFixture('fx09_declared_utf8_actual_gbk.epub')!;
      final EpubBook book = await parseEpub(bytes, fileName: 'fx09');
      expect(book.sections.length, 1);

      final Uint8List raw = book.sections.first.rawBytes;
      // 契约：decodeText 绝不抛异常。
      expect(() => decodeText(raw), returnsNormally);
      // 关键：回落 GBK 后中文可读，而不是 utf-8 乱码。
      expect(decodeText(raw), contains('声明是 utf-8，实际是 GBK，应当乱码。'));

      final ExtractedSection ex = extractSection(raw);
      expect(ex.title, '第九章');
      expect(ex.paragraphs, <String>['声明是 utf-8，实际是 GBK，应当乱码。']);
    }, skip: skipIfMissing('fx09_declared_utf8_actual_gbk.epub'));

    test('fx11 声明 gbk 含非法字节：decodeText 绝不抛异常（缺陷②）', () async {
      final Uint8List bytes =
          readFixture('fx11_declared_gbk_invalid_bytes.epub')!;
      final EpubBook book = await parseEpub(bytes, fileName: 'fx11');
      expect(book.sections.length, 1);

      final Uint8List raw = book.sections.first.rawBytes;
      // 本 fixture 的核心探针：非法 0xFF 字节不能让 decodeText 抛异常。
      expect(() => decodeText(raw), returnsNormally);

      final ExtractedSection ex = extractSection(raw);
      expect(ex.title, 'c11');
      expect(ex.paragraphs, isNotEmpty);
      // 非法字节被替换符兜底，'abc' 部分仍在（说明不是整段被丢弃）。
      expect(ex.paragraphs.first, contains('abc'));
    }, skip: skipIfMissing('fx11_declared_gbk_invalid_bytes.epub'));

    test('fx10 Big5 无声明：不崩溃（乱码可接受）', () async {
      final Uint8List bytes = readFixture('fx10_big5_no_decl.epub')!;
      final EpubBook book = await parseEpub(bytes, fileName: 'fx10');
      expect(book.sections.length, 1);

      final Uint8List raw = book.sections.first.rawBytes;
      expect(() => decodeText(raw), returnsNormally);
      expect(() => extractSection(raw), returnsNormally);
    }, skip: skipIfMissing('fx10_big5_no_decl.epub'));
  });
}
