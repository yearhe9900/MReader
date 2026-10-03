// `M3-T02`：划词选区底座纯逻辑（`AI-02`/`AI-03`/`TTS-02` 前置）。
//
// 覆盖：段落 key 编解码（含 href 带冒号/斜杠的歧义防御）、词边界归一
// （ASCII 扩词 / 空 range 从点按位兜底 / 全空白）、段落纯文本化（NUL 标记 +
// `<b>`/`<i>` 白名单标签）、ParaSelection 空判定。
// 纯 `test()`，无 widget、无 IO。
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:mreader/reader/selection_overlay.dart';

void main() {
  group('paragraphKey / parseParagraphKey', () {
    test('往返：paraIndex 在前，href 原样（可含冒号 / 斜杠）', () {
      final ValueKey<String> key = paragraphKey('OEBPS/ch1.xhtml#s2', 7);
      final ({int paraIndex, String href})? parsed = parseParagraphKey(key);
      expect(parsed, isNotNull);
      expect(parsed!.paraIndex, 7);
      expect(parsed.href, 'OEBPS/ch1.xhtml#s2');
    });

    test('非段落 key（其它 ValueKey / 非 ValueKey）→ null', () {
      expect(parseParagraphKey(const ValueKey<int>(3)), isNull);
      expect(parseParagraphKey(const ValueKey<String>('other')), isNull);
      expect(parseParagraphKey(const Key('plain')), isNull);
      expect(parseParagraphKey(null), isNull);
    });

    test('结构损坏（段数不对 / 下标非数字）→ null', () {
      expect(
        parseParagraphKey(const ValueKey<String>('para\u0001abc')),
        isNull,
      );
      expect(
        parseParagraphKey(const ValueKey<String>('para\u0001x\u0001h1')),
        isNull,
      );
      expect(
        parseParagraphKey(const ValueKey<String>('para\u00011\u0001h1\u0001x')),
        isNull,
      );
    });
  });

  group('normalizeWordRange', () {
    test('ASCII 词点中间 → 双向扩成整词', () {
      expect(
        normalizeWordRange('say hello world', 5, 5, 5),
        (start: 4, end: 9),
      );
    });

    test('range 带两侧空白 → 剥掉', () {
      expect(
        normalizeWordRange('  hello  ', 0, 9, 3),
        (start: 2, end: 7),
      );
    });

    test('起止颠倒 → 先交换再处理', () {
      // 'ab cd ef'：5..2 交换为 2..5 → 剥空白 → ASCII 扩成 'cd'。
      expect(
        normalizeWordRange('ab cd ef', 5, 2, 5),
        (start: 3, end: 5),
      );
    });

    test('空 range（起止同点落在词中间）→ 从点按位扩成整词', () {
      expect(
        normalizeWordRange('abc def', 4, 4, 4),
        (start: 4, end: 7),
      );
    });

    test('空 range 落在空白上 → 右先左后找最近非空白', () {
      // 点按位 3（空格）：右侧 4 是 'z'。
      expect(
        normalizeWordRange('ab z', 3, 3, 3),
        (start: 3, end: 4),
      );
      // 点按位 3（行尾空格）：右侧无，回左找到 'b' → 扩成整词 'ab'。
      expect(
        normalizeWordRange('ab  ', 3, 3, 3),
        (start: 0, end: 2),
      );
    });

    test('CJK 不扩词：原范围保留（剥空白后）', () {
      expect(
        normalizeWordRange('你好世界', 1, 3, 1),
        (start: 1, end: 3),
      );
    });

    test('纯空白文本 → (0, 0) 空选区', () {
      expect(normalizeWordRange('   ', 0, 3, 1), (start: 0, end: 0));
    });

    test('越界输入先 clamp', () {
      expect(
        normalizeWordRange('abc', -5, 99, 0),
        (start: 0, end: 3),
      );
    });
  });

  group('plainParagraphText', () {
    test('无标记纯文本原样', () {
      expect(plainParagraphText('普通段落'), '普通段落');
    });

    test('NUL 标记段只取偶数段（IMG/A/ID 标记不进 AI 输入）', () {
      expect(
        plainParagraphText('前\x00AOEBPS/a\x00后'),
        '前后',
      );
      // 多个标记：0/2/4 段为可见文本。
      expect(
        plainParagraphText('a\x00I1\x00b\x00IMG2\x00c'),
        'abc',
      );
    });

    test('<b>/<i> 白名单标签剥掉', () {
      expect(plainParagraphText('一<b>二</b>三<i>四</i>'), '一二三四');
      expect(plainParagraphText('<b>加粗</b>'), '加粗');
    });

    test('标记与标签混合', () {
      expect(
        plainParagraphText('见<b>注\x00N1\x00释</b>处'),
        '见注释处',
      );
    });
  });

  group('ParaSelection', () {
    test('isEmpty：空范围或空文本', () {
      const ParaSelection a = ParaSelection(
        chapterHref: 'h1',
        paraIndex: 0,
        start: 0,
        end: 0,
        text: 'x',
      );
      expect(a.isEmpty, isTrue);
      const ParaSelection b = ParaSelection(
        chapterHref: 'h1',
        paraIndex: 0,
        start: 0,
        end: 3,
        text: '',
      );
      expect(b.isEmpty, isTrue);
      const ParaSelection c = ParaSelection(
        chapterHref: 'h1',
        paraIndex: 0,
        start: 0,
        end: 3,
        text: 'abc',
      );
      expect(c.isEmpty, isFalse);
    });
  });
}
