// `section_extractor` 定向断言：`CNT-02` 行内换行 + `CNT-03` 表格按行退化。
//
// 背景：旧实现把 `<br>` / `<hr>` / 表格标签一并当段落边界——诗歌逐行内容
// 被切成独立段落（行距变段间距），3×3 表格碎成 9+ 段。现行为：
//   - CNT-02：`<br>` 只写入 `'\n'`（行内换行，不切段）；`<hr>` 保持
//     flush（段落分割语义不变）；`<p>` 之间仍切段。
//   - CNT-03：`<table>` 每个 `<tr>` 退化为一个纯文本段落，单元格以
//     `' | '` 连接；`<thead>/<tbody>/<tfoot>` 透明；单元格内联标签照常。
// 本文件锁住这些行为，防止后续改动回归（fixture 回归见
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

  group('CNT-03 表格按行退化渲染', () {
    test('3×3 表格退化为 3 个段落，每段 3 个单元格内容', () {
      final ExtractedSection section = extractBody(
        '<table>'
        '<tr><td>甲一</td><td>甲二</td><td>甲三</td></tr>'
        '<tr><td>乙一</td><td>乙二</td><td>乙三</td></tr>'
        '<tr><td>丙一</td><td>丙二</td><td>丙三</td></tr>'
        '</table>',
      );
      expect(section.paragraphs, <String>[
        '甲一 | 甲二 | 甲三',
        '乙一 | 乙二 | 乙三',
        '丙一 | 丙二 | 丙三',
      ]);
    });

    test('thead + th 表头行同理按行渲染', () {
      final ExtractedSection section = extractBody(
        '<table><thead><tr><th>名</th><th>值</th></tr></thead>'
        '<tbody><tr><td>甲</td><td>1</td></tr>'
        '<tr><td>乙</td><td>2</td></tr></tbody></table>',
      );
      expect(section.paragraphs, <String>[
        '名 | 值',
        '甲 | 1',
        '乙 | 2',
      ]);
    });

    test('单元格内 <b> 保留字面标签', () {
      final ExtractedSection section = extractBody(
        '<table><tr><td>普通<b>加粗</b></td><td>下一列</td></tr></table>',
      );
      expect(section.paragraphs, <String>['普通<b>加粗</b> | 下一列']);
    });

    test('单元格内 <br> 变行内换行，不切出新段落', () {
      final ExtractedSection section = extractBody(
        '<table><tr><td>上<br>下</td><td>b</td></tr></table>',
      );
      expect(section.paragraphs, <String>['上\n下 | b']);
    });

    test('caption 退化为表格前的独立段落（内容不丢失）', () {
      final ExtractedSection section = extractBody(
        '<table><caption>表一</caption>'
        '<tr><td>x</td><td>y</td></tr></table>',
      );
      expect(section.paragraphs, <String>['表一', 'x | y']);
    });

    test('宽表格：超长单元格与 nbsp 产出纯文本段落（可折行不溢出）', () {
      final String longCell =
          List<String>.filled(300, '宽', growable: false).join();
      final ExtractedSection section = extractBody(
        '<table><tr><td>左&nbsp;列</td><td>$longCell</td><td>右</td></tr>'
        '</table>',
      );
      expect(section.paragraphs, hasLength(1));
      final String row = section.paragraphs.single;
      expect(row, contains(longCell));
      // 不换行空格会阻断折行 -> 横向溢出；抽取层必须把它归一为普通空格
      // （Text 节点空白折叠 \s+ 已覆盖 U+00A0，此断言防未来回归）。
      expect(row.contains(String.fromCharCode(0x00A0)), isFalse,
          reason: '段落不得含强制不换行字符（U+00A0）');
      // 表格标签不得以字面文本漏进行段。
      expect(row.contains('<td'), isFalse);
      expect(row.contains('<table'), isFalse);
    });

    test('嵌套表格不崩，内容随所在单元格降级为文本', () {
      final ExtractedSection section = extractBody(
        '<table><tr><td>外层'
        '<table><tr><td>内层</td></tr></table>'
        '</td><td>右</td></tr></table>',
      );
      expect(section.paragraphs, hasLength(1));
      expect(section.paragraphs.single, contains('外层'));
      expect(section.paragraphs.single, contains('内层'));
    });

    test('表格前后文本各自成段（无表格时行为不回归）', () {
      final ExtractedSection section = extractBody(
        '<p>前文。</p>'
        '<table><tr><td>a</td><td>b</td></tr></table>'
        '<p>后文。</p>',
      );
      expect(section.paragraphs, <String>['前文。', 'a | b', '后文。']);
    });
  });
}
