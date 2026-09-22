// ScrollAnchor 位置锚定单测（`TYP-02`）。
//
// 纯 Dart `test()`（非 `testWidgets`）——用 `correctionFromRaw` 纯数值版
// 直接断言偏移计算，不依赖 Flutter widget 树 / tester.pump。
//
// 本项目已两次实证 `testWidgets` 测试体内 `await` 真异步 IO 会挂死。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/typography/anchor.dart';

void main() {
  group('ScrollAnchor', () {
    test('construct + toString', () {
      const ScrollAnchor a = ScrollAnchor(chapterIndex: 5, relativePos: 0.3);
      expect(a.chapterIndex, 5);
      expect(a.relativePos, 0.3);
      expect(a.toString(), contains('ch: 5'));
    });
  });

  group('correctionFromRaw', () {
    test('章顶对齐视口顶（relativePos=0.0）：无偏移 → null', () {
      const ScrollAnchor anchor =
          ScrollAnchor(chapterIndex: 0, relativePos: 0.0);
      final double? correction = anchor.correctionFromRaw(
        newViewportTop: 100,
        newChapterTop: 100, // 章顶 = 视口顶
        newChapterHeight: 500,
      );
      expect(correction, isNull); // 偏移 ≤ 1px
    });

    test('章顶对齐视口顶：偏移 10px → correction = 10', () {
      const ScrollAnchor anchor =
          ScrollAnchor(chapterIndex: 0, relativePos: 0.0);
      final double? correction = anchor.correctionFromRaw(
        newViewportTop: 100,
        newChapterTop: 110, // 章顶比视口顶低 10px
        newChapterHeight: 500,
      );
      expect(correction, 10.0);
    });

    test('视口顶在章 30% 处（relativePos=0.3）', () {
      const ScrollAnchor anchor =
          ScrollAnchor(chapterIndex: 2, relativePos: 0.3);
      // 目标：章顶 + 0.3 × 章高 = 视口顶
      // 即：章顶 = 视口顶 - 0.3 × 章高 = 100 - 150 = -50
      final double? correction = anchor.correctionFromRaw(
        newViewportTop: 100,
        newChapterTop: -50, // 正确位置
        newChapterHeight: 500,
      );
      expect(correction, isNull); // 偏移 ≤ 1px
    });

    test('视口顶在章 30% 处：章偏了 20px', () {
      const ScrollAnchor anchor =
          ScrollAnchor(chapterIndex: 2, relativePos: 0.3);
      // 目标章顶 = 100 - 0.3 × 500 = -50
      // 实际章顶 = -30（比目标高 20px）
      final double? correction = anchor.correctionFromRaw(
        newViewportTop: 100,
        newChapterTop: -30,
        newChapterHeight: 500,
      );
      expect(correction, 20.0);
    });

    test('章高为 0 → null（容错）', () {
      const ScrollAnchor anchor =
          ScrollAnchor(chapterIndex: 0, relativePos: 0.5);
      final double? correction = anchor.correctionFromRaw(
        newViewportTop: 100,
        newChapterTop: 100,
        newChapterHeight: 0,
      );
      expect(correction, isNull);
    });

    test('偏移 ≤ 1px → null（不校正微小抖动）', () {
      const ScrollAnchor anchor =
          ScrollAnchor(chapterIndex: 0, relativePos: 0.5);
      // 目标章顶 = 100 - 0.5 × 200 = 0
      // 实际章顶 = 0.5（差 0.5px）
      final double? correction = anchor.correctionFromRaw(
        newViewportTop: 100,
        newChapterTop: 0.5,
        newChapterHeight: 200,
      );
      expect(correction, isNull);
    });

    test('TYP-02 验收场景：字号 18→30 后章高变大，章顶相对视口偏移', () {
      // 模拟：设置变更前，视口顶在第 12 章的 40% 处。
      const ScrollAnchor anchor =
          ScrollAnchor(chapterIndex: 11, relativePos: 0.4);

      // 设置变更后：章高从 500 变成 800（字号 18→30，行高增大），
      // 章顶从视口顶上方 200px 变成上方 320px（因为前面章也变高了）。
      // 目标：章顶应保持在 视口顶 - 0.4 × 800 = 100 - 320 = -220
      // 实际：章顶 = -320（前面章变高把它推上去了）
      final double? correction = anchor.correctionFromRaw(
        newViewportTop: 100,
        newChapterTop: -320,
        newChapterHeight: 800,
      );
      // 差值 = -320 - (-220) = -100 → 需要向下滚 100px
      expect(correction, -100.0);
    });
  });
}
