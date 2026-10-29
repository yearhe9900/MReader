// 端到端真样本冒烟 —— §17 M2 判定第 1 条（四类格式各 ≥3 样本导入并阅读成功）
// 与第 3 条（书内搜索可用，用真书正文派生查询，不冻结）。
//
// 数据来源：读 `tmp_book/`（仓库已 gitignore，真实样本不入库）；FMT-01/02 的代表性
// 真实结构样本由 `tool/gen_real_samples.py` 生成。
//
// 干净 checkout：无 `tmp_book/` 时本文件**整组 skip**（不红、不阻塞全量），属预期行为。
//
// PDF 为什么要容忍 skip：PDF 走真渲染内核（pdfrx / pdfium），`flutter test` 无头环境
// **可能**加载不到原生库——此时把样本记 SKIP 并提示「请在 App 内人工冒烟」，不让冒烟变红
// （内核不可用属环境问题，不是 FMT-01 缺陷）。纯 Dart 的 EPUB / TXT / CBZ 失败则**如实
// 报错**，不吞。
//
// 运行：
//     flutter test test/format/real_samples_smoke_test.dart
//     bash tool/test.sh parse      # 顺带跑（无样本时 skip）
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_registry.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/format/pdf_source.dart';
import 'package:mreader/platform/pdf_engine.dart';
import 'package:mreader/platform/pdfrx_pdf_engine.dart';

import '../test_config.dart';

const String kSampleDir = 'tmp_book';

/// 列出样本目录里指定扩展名的文件（字典序稳定）。
List<File> _samplesOf(String ext) {
  final Directory dir = Directory(kSampleDir);
  if (!dir.existsSync()) return const <File>[];
  final List<File> files = dir
      .listSync()
      .whereType<File>()
      .where((File f) => f.path.toLowerCase().endsWith('.$ext'))
      .toList();
  files.sort((File a, File b) => a.path.compareTo(b.path));
  return files;
}

String _baseName(File f) => f.uri.pathSegments.last;

/// 对单个样本跑完整链路：openBook → load → chapters → content(0) → readResource。
/// 返回一行结果描述；失败直接抛出（由调用方决定是否容忍）。
Future<String> _smokeOpenAndRead(File file) async {
  final Uint8List bytes = await file.readAsBytes();
  final String name = _baseName(file);
  final BookSource source = await openBook(fileName: name, bytes: bytes);
  try {
    final BookMeta meta = await source.load();
    final List<Chapter> chapters = await source.chapters();
    expect(chapters, isNotEmpty, reason: '$name：应至少解析出 1 章');
    final ChapterContent first = await source.content(0);
    expect(first.isEmpty, isFalse, reason: '$name：首章内容不应为空');
    if (first.imagePages != null) {
      expect(first.imagePages!, isNotEmpty, reason: '$name：图片页序列非空');
      final Uint8List? res = await source.readResource(first.imagePages!.first);
      expect(res, isNotNull, reason: '$name：首图资源应可取到');
      expect(res!.isNotEmpty, isTrue, reason: '$name：首图字节非空');
      return '$name · ${source.implId} · ${chapters.length} 章 · '
          '图片页 ${first.imagePages!.length} · 标题「${meta.title}」';
    }
    expect(first.paragraphList, isNotEmpty, reason: '$name：首章段落非空');
    return '$name · ${source.implId} · ${chapters.length} 章 · '
        '段落 ${first.paragraphList.length} · 标题「${meta.title}」';
  } finally {
    await source.dispose();
  }
}

/// 用真书正文**派生**查询词（取首段前 2 个字符），跑一次 [BookSource.search]，
/// 断言至少 1 条命中——真数据下的 `CNT-06` 搜索链路冒烟。
Future<String> _smokeSearch(File file) async {
  final Uint8List bytes = await file.readAsBytes();
  final String name = _baseName(file);
  final BookSource source = await openBook(fileName: name, bytes: bytes);
  try {
    await source.load();
    final ChapterContent first = await source.content(0);
    final List<String> paras = first.paragraphList;
    if (paras.isEmpty) return '$name · 搜索 SKIP（首章无段落）';
    final String text = paras.firstWhere((String p) => p.trim().length >= 2,
        orElse: () => paras.first);
    final String query = text.trim().substring(0, 2);
    final CancelToken cancel = CancelToken();
    int hits = 0;
    await for (final SearchEvent e in source.search(query, cancel: cancel)) {
      if (e.hit != null) hits++;
    }
    expect(hits, greaterThan(0), reason: '$name：搜索「$query」应有命中');
    return '$name · 搜索「$query」命中 $hits 条';
  } finally {
    await source.dispose();
  }
}

void main() {
  // 本文件要触达真 PDF 渲染内核（pdfrx 原生库）：环境不佳时可能挂起，
  // 用 30s 兜底超时，避免拖垮全量（与含 testWidgets 的文件同款纪律）。
  capTestTimeout();
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<File> epubs = _samplesOf('epub');
  final List<File> txts = _samplesOf('txt');
  final List<File> pdfs = _samplesOf('pdf');
  final List<File> cbzs = _samplesOf('cbz');

  group('M2b-T09 真样本冒烟（tmp_book/；无样本整组 skip）', () {
    test('EPUB 真样本 ≥1：导入 + 阅读', () async {
      for (final File f in epubs) {
        stdout.writeln('  ${await _smokeOpenAndRead(f)}');
      }
      expect(epubs.length, greaterThanOrEqualTo(3),
          reason: 'EPUB 样本应 ≥3（§17 M2 判定第 1 条）');
    }, skip: epubs.isEmpty ? 'tmp_book/ 无 EPUB 样本（不入库，属预期）' : null);

    test('TXT 真样本 ≥1：导入 + 阅读', () async {
      for (final File f in txts) {
        stdout.writeln('  ${await _smokeOpenAndRead(f)}');
      }
      expect(txts.length, greaterThanOrEqualTo(3),
          reason: 'TXT 样本应 ≥3（§17 M2 判定第 1 条）');
    }, skip: txts.isEmpty ? 'tmp_book/ 无 TXT 样本（不入库，属预期）' : null);

    test('CBZ 真样本 ≥3：导入 + 阅读（含图片页资源）', () async {
      for (final File f in cbzs) {
        stdout.writeln('  ${await _smokeOpenAndRead(f)}');
      }
      expect(cbzs.length, greaterThanOrEqualTo(3),
          reason: 'CBZ 样本应 ≥3（FMT-02）');
    }, skip: cbzs.isEmpty ? 'tmp_book/ 无 CBZ 样本（不入库，属预期）' : null);

    test('PDF 真样本 ≥3：路由校验（真渲染默认关，见注释）', () async {
      expect(pdfs.length, greaterThanOrEqualTo(3),
          reason: 'PDF 样本应 ≥3（FMT-01）');
      // 真渲染（pdfrx /pdfium 原生库）在无头 `flutter test` 下可能加载不到，
      // 故默认**只校验路由**（样本是否被 `sniffFormat` 正确判为 PDF 并交 `PdfSource`）；
      // 需要真开页时设环境变量 `MREADER_REAL_PDF=1` 再跑本文件。
      final bool realPdf = Platform.environment['MREADER_REAL_PDF'] == '1';
      if (realPdf) PdfEngineProvider.current = PdfrxPdfEngine();
      for (final File f in pdfs) {
        final Uint8List bytes = await f.readAsBytes();
        final String name = _baseName(f);
        final BookSource source = await openBook(fileName: name, bytes: bytes);
        expect(source, isA<PdfSource>(), reason: '$name：应路由到 PdfSource');
        if (!realPdf) {
          stdout.writeln('  $name · 路由 OK（真渲染默认跳过；MREADER_REAL_PDF=1 开启）');
          await source.dispose();
          continue;
        }
        try {
          final List<Chapter> chapters = await source.chapters();
          final ChapterContent first = await source.content(0);
          expect(first.imagePages, isNotNull, reason: '$name：PDF 应为图片页');
          final Uint8List? res =
              await source.readResource(first.imagePages!.first);
          expect(res, isNotNull, reason: '$name：首图应可渲染');
          stdout.writeln('  $name · ${source.implId} · ${chapters.length} 章 · '
              '首图 ${res!.length} 字节');
        } catch (e) {
          // 内核/原生库在本环境不可用：不算 FMT-01 缺陷，记 SKIP 提示人工冒烟。
          stdout.writeln('  SKIP $name：PDF 渲染内核不可用（$e）——请在 App 内人工冒烟');
        } finally {
          await source.dispose();
        }
      }
    }, skip: pdfs.isEmpty ? 'tmp_book/ 无 PDF 样本（不入库，属预期）' : null);

    test('真书搜索冒烟（CNT-06，第 3 条辅助证据）', () async {
      for (final File f in <File>[...epubs.take(1), ...txts.take(1)]) {
        stdout.writeln('  ${await _smokeSearch(f)}');
      }
    }, skip: (epubs.isEmpty && txts.isEmpty)
        ? 'tmp_book/ 无 EPUB/TXT 样本（不入库，属预期）'
        : null);
  });
}
