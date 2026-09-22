// `CNT-04c` 纯逻辑单测：splitLinkHref / findChapterIndex / findParagraphIndex /
// LinkBackStack（返回原位置栈）。
//
// 纯 Dart `test()`（非 `testWidgets`）——link_navigator 不依赖 widget 树。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/model/chapter.dart';
import 'package:mreader/reader/link_navigator.dart';
import 'package:mreader/typography/anchor.dart';

Chapter _ch(String href) =>
    Chapter(href: href, title: 't', level: 0, locate: '');

void main() {
  group('splitLinkHref', () {
    test('章内 #id → path 空、fragment 为 id', () {
      final r = splitLinkHref('#note1');
      expect(r.path, '');
      expect(r.fragment, 'note1');
    });

    test('跨文件 path → fragment 空串（非 null）', () {
      final r = splitLinkHref('OEBPS/text/ch2.xhtml');
      expect(r.path, 'OEBPS/text/ch2.xhtml');
      expect(r.fragment, '');
    });

    test('跨文件 path#id 两段都取到', () {
      final r = splitLinkHref('ch2.xhtml#s');
      expect(r.path, 'ch2.xhtml');
      expect(r.fragment, 's');
    });

    test('无 # 的任意串 → fragment 恒为空串', () {
      expect(splitLinkHref('plain').fragment, '');
      expect(splitLinkHref('').fragment, '');
    });

    test('多个 # 时以第一个切分', () {
      final r = splitLinkHref('ch.xhtml#a#b');
      expect(r.path, 'ch.xhtml');
      expect(r.fragment, 'a#b');
    });
  });

  group('findChapterIndex', () {
    final List<Chapter> chapters = <Chapter>[
      _ch('OEBPS/text/ch1.xhtml'),
      _ch('OEBPS/第二章.xhtml'),
    ];

    test('精确命中', () {
      expect(findChapterIndex(chapters, 'OEBPS/text/ch1.xhtml'), 0);
    });

    test('大小写不敏感（fx03 类脏书）', () {
      expect(findChapterIndex(chapters, 'oebps/TEXT/Ch1.XHTML'), 0);
    });

    test('百分号解码后匹配（编码 href ↔ 裸条目名）', () {
      expect(
        findChapterIndex(chapters, 'OEBPS/%E7%AC%AC%E4%BA%8C%E7%AB%A0.xhtml'),
        1,
      );
    });

    test('空 path（章内链接）→ -1，由调用方落到当前章', () {
      expect(findChapterIndex(chapters, ''), -1);
    });

    test('不命中 → -1（静默忽略，不抛异常）', () {
      expect(findChapterIndex(chapters, 'no/such/file.xhtml'), -1);
      expect(findChapterIndex(const <Chapter>[], 'ch1.xhtml'), -1);
    });
  });

  group('findParagraphIndex', () {
    // 与抽取层输出形态一致：ID 标记在段首；ID + A 可共存（脚注含返回链接）。
    final List<String> paragraphs = <String>[
      '普通段落',
      '\x00ID:fn1\x00注释一',
      '\x00ID:fn2\x00注释二 \x00A:#top\x00\u21a9\x00A\x00',
    ];

    test('扫描 \\x00ID:id\\x00 命中段落下标', () {
      expect(findParagraphIndex(paragraphs, 'fn1'), 1);
    });

    test('ID + A 共存段落同样命中（脚注返回锚）', () {
      expect(findParagraphIndex(paragraphs, 'fn2'), 2);
    });

    test('空 fragment → -1', () {
      expect(findParagraphIndex(paragraphs, ''), -1);
    });

    test('不存在的 id → -1（静默忽略，不抛异常）', () {
      expect(findParagraphIndex(paragraphs, 'missing'), -1);
    });

    test('百分号编码 fragment 回退解码匹配（#fn%31 → fn1）', () {
      expect(findParagraphIndex(paragraphs, 'fn%31'), 1);
    });

    test('id 前缀不误命中（fn 不命中 fn1 的标记）', () {
      expect(findParagraphIndex(paragraphs, 'fn'), -1);
    });

    test('空段落列表不崩', () {
      expect(findParagraphIndex(const <String>[], 'fn1'), -1);
    });
  });

  group('LinkBackStack', () {
    test('压栈弹栈 LIFO', () {
      final LinkBackStack stack = LinkBackStack();
      const ScrollAnchor a1 = ScrollAnchor(chapterIndex: 0, relativePos: 0.1);
      const ScrollAnchor a2 = ScrollAnchor(chapterIndex: 2, relativePos: 0.9);
      stack.push(a1);
      stack.push(a2);
      expect(stack.length, 2);
      expect(stack.isNotEmpty, isTrue);
      expect(stack.pop(), a2); // 后进先出
      expect(stack.pop(), a1);
      expect(stack.isEmpty, isTrue);
    });

    test('空栈 pop → null，不抛异常', () {
      final LinkBackStack stack = LinkBackStack();
      expect(stack.pop(), isNull);
      expect(stack.isEmpty, isTrue);
    });

    test('clear 清空', () {
      final LinkBackStack stack = LinkBackStack();
      stack.push(const ScrollAnchor(chapterIndex: 1, relativePos: 0.5));
      stack.push(const ScrollAnchor(chapterIndex: 2, relativePos: 0.5));
      stack.clear();
      expect(stack.length, 0);
      expect(stack.pop(), isNull);
    });
  });
}
