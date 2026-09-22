// 性能样本生成器（命令行）。**样本不入库**——默认写到系统临时目录。
//
// 用法：
//   dart run tool/gen_perf_fixtures.dart            # 写到系统临时目录
//   dart run tool/gen_perf_fixtures.dart <目录>      # 写到指定目录
//
// 产物：
//   · big_320.epub      —— 320 章 + 10×2MB 图片（验证非章节资源不常驻）
//   · long_chapter.epub —— 单章 ~12 万字符（`PERF-03`）
//   · big_20mb.txt      —— ~20MB、800 章（首帧时间 / 峰值内存基线）
import 'dart:io';
import 'dart:typed_data';

import 'perf_fixtures.dart';

void main(List<String> args) {
  final Directory out = args.isNotEmpty
      ? (Directory(args.first)..createSync(recursive: true))
      : Directory.systemTemp.createTempSync('mreader_perf_');

  final Map<String, Uint8List> samples = <String, Uint8List>{
    'big_320.epub': buildEpub(
      chapters: 320,
      imageCount: 20,
      imageBytesEach: 4 * 1024 * 1024,
    ),
    'long_chapter.epub': buildLongChapterEpub(),
    'big_20mb.txt': buildTxt(),
  };

  final StringBuffer report = StringBuffer();
  for (final MapEntry<String, Uint8List> e in samples.entries) {
    final File f = File('${out.path}${Platform.pathSeparator}${e.key}');
    f.writeAsBytesSync(e.value);
    report.writeln(
      '  ${e.key}: ${(e.value.lengthInBytes / 1024 / 1024).toStringAsFixed(2)} MB',
    );
  }
  stdout.writeln('样本输出目录：${out.path}');
  stdout.write(report.toString());
}
