// `CNT-02` 定向断言：`<br>` 行内换行 + `<p>` 段间距不回归。
//
// 背景：旧实现把 `<br>` / `<hr>` 一并当段落边界，诗歌等逐行内容被切成
// 独立段落，「行距」被放大成「段间距」。CNT-02 改为：`<br>` 只写入
// `'\n'`（行内换行，不切段），`<hr>` 保持 flush（段落分割语义不变）。
// 本文件锁住这两个行为，防止后续改动回归（fixture 回归见
// `test/epub_fixtures_test.dart`，本文件是它的纯内存最小补充）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/epub/section_extractor.dart';

/// 现造一段 XHTML 正文并抽取（纯内存，不依赖 fixture 文件）。
ExtractedSection extractBody(String bodyHtml) => extractSection(
      Uint8List.fromList(utf8.encode('<html><body>$bodyHtml</body></html>')),
    );

void main() {
  group('CNT-02 <br> 行内换行', () {
    test('<br> 不切新段：前后文本保留为同一段，行间为行距', () {
      final ExtractedSection section =
          extractBody('<p>床前明月光<br>疑是地上霜</p>');
      expect(section.paragraphs, <String>['床前明月光\n疑是地上霜']);
    });

    test('<br/> 与 <br /> 同样只写入换行，不切段', () {
      final ExtractedSection section =
          extractBody('<p>一<br/>二<br />三</p>');
      expect(section.paragraphs, <String>['一\n二\n三']);
    });

    test('<p> 段间距不回归：相邻 <p> 仍是独立段落', () {
      final ExtractedSection section =
          extractBody('<p>第一段。</p><p>第二段。</p>');
      expect(section.paragraphs, <String>['第一段。', '第二段。']);
    });

    test('<hr> 仍切段（既有段落分割语义保持）', () {
      final ExtractedSection section = extractBody('上半<hr>下半');
      expect(section.paragraphs, <String>['上半', '下半']);
    });
  });
}
