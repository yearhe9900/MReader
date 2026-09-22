// `section_extractor` 定向断言：`CNT-02` 行内换行 + `CNT-03` 表格按行退化
// + `CNT-04a` 链接 / 锚点标记。
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

  group('CNT-04a 链接与锚点标记', () {
    test('<a href="#fn1"> 包住所包文字写成 A 标记', () {
      final ExtractedSection section =
          extractBody('<p>见<a href="#fn1">脚注1</a>。</p>');
      expect(section.paragraphs, <String>[
        '见\x00A:#fn1\x00脚注1\x00A\x00。',
      ]);
    });

    test('跨文件 href 走 resolveHref 归一化并保留 fragment（baseDir 空）', () {
      final ExtractedSection section =
          extractBody('<a href="text/ch2.xhtml#sec1">第二章</a>');
      expect(section.paragraphs, <String>[
        '\x00A:text/ch2.xhtml#sec1\x00第二章\x00A\x00',
      ]);
    });

    test('跨文件 href 按 baseDir 归一化（与 <img src> 同一手法）', () {
      final ExtractedSection section = extractSection(
        Uint8List.fromList(
            utf8.encode('<html><body><a href="../text/ch2.xhtml#s">x</a>'
                '</body></html>')),
        baseDir: 'OEBPS/ch',
      );
      expect(section.paragraphs, <String>[
        '\x00A:OEBPS/text/ch2.xhtml#s\x00x\x00A\x00',
      ]);
    });

    test('<a> 无 href：只保留文字；name 作为锚点写 ID 标记', () {
      final ExtractedSection section =
          extractBody('<p><a name="fn1">脚注</a></p>');
      expect(section.paragraphs, <String>['\x00ID:fn1\x00脚注']);
      // 无 href → 不产生链接标记。
      expect(section.paragraphs.single.contains('\x00A:'), isFalse);
    });

    test('块级 id 写在段落开头', () {
      final ExtractedSection section = extractBody('<p id="sec1">正文</p>');
      expect(section.paragraphs, <String>['\x00ID:sec1\x00正文']);
    });

    test('ID 与链接标记共存于同一段落（脚注返回锚）', () {
      final ExtractedSection section = extractBody(
          '<aside id="fn1"><p>脚注内容 <a href="#ref1">↩</a></p></aside>');
      expect(section.paragraphs, <String>[
        '\x00ID:fn1\x00脚注内容 \x00A:#ref1\x00↩\x00A\x00',
      ]);
    });

    test('标题剥离时 ID 标记接力到下一段（指向标题的锚点不失效）', () {
      final ExtractedSection section =
          extractBody('<h1 id="top">章一</h1><p>后文</p>');
      expect(section.title, '章一');
      expect(section.paragraphs, <String>['\x00ID:top\x00后文']);
    });

    test('纯锚点空元素不产出空白段落：标记挂到相邻段落', () {
      final ExtractedSection trailing =
          extractBody('<p>前</p><div id="empty"></div>');
      expect(trailing.paragraphs, <String>['前\x00ID:empty\x00']);

      final ExtractedSection alone = extractBody('<div id="x"></div>');
      expect(alone.paragraphs, isEmpty);
    });

    test('无链接无 id 的段落完全不受影响（不回归）', () {
      final ExtractedSection section =
          extractBody('<p>普通段一。</p><p>普通段二。</p>');
      expect(section.paragraphs, <String>['普通段一。', '普通段二。']);
      expect(section.paragraphs.any((String p) => p.contains('\x00')), isFalse);
    });
  });
}
