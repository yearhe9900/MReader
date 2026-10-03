// `TTS-02` ①②③ 判定面（M3-T06）：跟随策略开关 + 段落「足够可见」纯函数。
//
// 期望值全部硬编码字面量（契约纪律）；矩形口径 = 逻辑像素坐标。
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/highlight_follow.dart';

void main() {
  group('HighlightFollow 跟随策略（TTS-02 ③）', () {
    test('默认跟随；手动滚动暂停；reset 恢复', () {
      final HighlightFollow follow = HighlightFollow();
      expect(follow.shouldFollow, isTrue);

      follow.noteManualScroll();
      expect(follow.shouldFollow, isFalse);
      follow.noteManualScroll(); // 重复记账幂等
      expect(follow.shouldFollow, isFalse);

      follow.reset(); // 重新开读 → 恢复
      expect(follow.shouldFollow, isTrue);
    });
  });

  group('isParagraphVisible 足够可见（TTS-02 ②）', () {
    const Rect viewport = Rect.fromLTWH(0, 0, 400, 800);

    test('完全在屏 → 可见', () {
      const Rect para = Rect.fromLTWH(20, 300, 360, 80);
      expect(isParagraphVisible(para, viewport), isTrue);
    });

    test('露一半（判据边界 = 50%）→ 可见', () {
      // 段高 80，下缘恰在视口底：露出 40 = 80 × 0.5 → 边界含等号。
      const Rect para = Rect.fromLTWH(20, 760, 360, 80);
      expect(isParagraphVisible(para, viewport), isTrue);
    });

    test('露 30% → 不可见（需滚动）', () {
      const Rect para = Rect.fromLTWH(20, 776, 360, 80); // 露 24 = 30%
      expect(isParagraphVisible(para, viewport), isFalse);
    });

    test('完全在视口下方 → 不可见', () {
      const Rect para = Rect.fromLTWH(20, 800, 360, 80);
      expect(isParagraphVisible(para, viewport), isFalse);
    });

    test('完全在视口上方 → 不可见', () {
      const Rect para = Rect.fromLTWH(20, -80, 360, 80);
      expect(isParagraphVisible(para, viewport), isFalse);
    });

    test('超长段占满整屏 → 可见（判据取 min(段高, 视口高)）', () {
      const Rect para = Rect.fromLTWH(20, -500, 360, 2000);
      expect(isParagraphVisible(para, viewport), isTrue); // 露 800 ≥ 400
    });

    test('超长段仅露一小截 → 不可见', () {
      // 段高 2000，视口高 800 → 门槛 400；只露 100 → 不可见。
      const Rect para = Rect.fromLTWH(20, 700, 360, 2000);
      expect(isParagraphVisible(para, viewport), isFalse);
    });

    test('自定义 ratio=1.0：整段全露才算可见', () {
      const Rect halfOut = Rect.fromLTWH(20, 760, 360, 80); // 露 40/80
      expect(isParagraphVisible(halfOut, viewport), isTrue); // 默认 0.5 通过
      expect(
        isParagraphVisible(halfOut, viewport, ratio: 1.0),
        isFalse, // 需 80 ≥ 80 → 露 40 不足
      );
      const Rect full = Rect.fromLTWH(20, 300, 360, 80);
      expect(isParagraphVisible(full, viewport, ratio: 1.0), isTrue);
    });
  });
}
