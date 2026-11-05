// 开发者开关：PDF 内核分发契约（默认关不回归 / 开启走 rrk-pdf L1 文字重排）。
//
// 开启路径需原生库；无库时 `markTestSkipped`（与 `rust_kernel_api_test.dart` 同口径）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_registry.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/settings/developer_options.dart';
import 'package:mreader/src/rust/api/guard.dart' show probe;
import 'package:mreader/src/rust/frb_generated.dart';

import 'pdf_fakes.dart';

bool? _kernelReady;

Future<bool> _ensureKernel() async {
  final bool? cached = _kernelReady;
  if (cached != null) return cached;
  try {
    await RustLib.init();
    return _kernelReady = true;
  } catch (_) {
    try {
      probe(); // 二次 init 被拒但内核在跑：probe 能回值即视为可用。
      return _kernelReady = true;
    } catch (_) {
      return _kernelReady = false;
    }
  }
}

void main() {
  tearDown(() => DeveloperOptions.pdfUseRustKernel = false);

  test('默认关闭：PDF 仍走 pdfrx 固版式源（不回归）', () async {
    expect(DeveloperOptions.pdfUseRustKernel, isFalse);
    final BookSource source = await openBook(
      fileName: 'sample.pdf',
      bytes: minimalPdfBytes(),
    );
    expect(source.implId, 'pdfrx-pdf');
    await source.dispose();
  });

  test('开关开启：PDF 走 rrk-pdf 内核源（L1 段落文字，非图片页）', () async {
    if (!await _ensureKernel()) {
      markTestSkipped('原生库不可用，跳过内核分发用例');
      return;
    }
    final File sample = File('rust/fixtures/sample.pdf');
    if (!sample.existsSync()) {
      markTestSkipped('缺 rust/fixtures/sample.pdf');
      return;
    }
    DeveloperOptions.pdfUseRustKernel = true;
    final BookSource source = await openBook(
      fileName: 'sample.pdf',
      bytes: await sample.readAsBytes(),
    );
    expect(source.implId, 'rust-pdf');
    final List<Chapter> chapters = await source.chapters();
    expect(chapters, isNotEmpty);
    expect(chapters.first.href, startsWith('pdf:'));
    final ChapterContent content = await source.content(0);
    expect(content.imagePages, isNull, reason: 'L1 是文字版段落，不是图片页');
    await source.dispose();
  });
}
