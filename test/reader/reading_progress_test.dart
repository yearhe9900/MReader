// `RD-04`：阅读进度值对象单测（纯 Dart，用 `test()` 而非 `testWidgets()`）。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/reading_progress.dart';

ReadingProgress _sample({
  String bookId = 'abc123',
  String chapterHref = 'txt:10247',
  int chapterIndex = 3,
  double chapterPos = 0.42,
  int updatedAt = 1700000000000,
}) {
  return ReadingProgress(
    bookId: bookId,
    chapterHref: chapterHref,
    chapterIndex: chapterIndex,
    chapterPos: chapterPos,
    updatedAt: updatedAt,
  );
}

void main() {
  group('ReadingProgress', () {
    test('toJson / fromJson round-trip 保真', () {
      final ReadingProgress original = _sample();
      final ReadingProgress? restored = ReadingProgress.fromJson(original.toJson());
      expect(restored, isNotNull);
      expect(restored, original);
      expect(restored!.bookId, 'abc123');
      expect(restored.chapterHref, 'txt:10247');
      expect(restored.chapterIndex, 3);
      expect(restored.chapterPos, closeTo(0.42, 1e-9));
      expect(restored.updatedAt, 1700000000000);
    });

    test('构造时 chapterPos clamp 到 0~1', () {
      expect(_sample(chapterPos: -0.5).chapterPos, 0.0);
      expect(_sample(chapterPos: 0.0).chapterPos, 0.0);
      expect(_sample(chapterPos: 1.0).chapterPos, 1.0);
      expect(_sample(chapterPos: 2.5).chapterPos, 1.0);
    });

    test('fromJson 非 Map → null', () {
      expect(ReadingProgress.fromJson(null), isNull);
      expect(ReadingProgress.fromJson('not a map'), isNull);
      expect(ReadingProgress.fromJson(<Object>[]), isNull);
      expect(ReadingProgress.fromJson(42), isNull);
    });

    test('fromJson 缺字段 → null', () {
      expect(ReadingProgress.fromJson(<String, Object?>{'bookId': 'b'}), isNull);
      expect(
        ReadingProgress.fromJson(<String, Object?>{
          'bookId': 'b',
          'chapterHref': 'h',
          'chapterIndex': 0,
          'chapterPos': 0.0,
          // updatedAt 缺失
        }),
        isNull,
      );
    });

    test('fromJson 类型错误 → null', () {
      expect(
        ReadingProgress.fromJson(<String, Object?>{
          'bookId': 123, // 应为 String
          'chapterHref': 'h',
          'chapterIndex': 0,
          'chapterPos': 0.0,
          'updatedAt': 0,
        }),
        isNull,
      );
      expect(
        ReadingProgress.fromJson(<String, Object?>{
          'bookId': 'b',
          'chapterHref': 'h',
          'chapterIndex': 'not a number',
          'chapterPos': 0.0,
          'updatedAt': 0,
        }),
        isNull,
      );
    });

    test('fromJson num 兜底：int 型 chapterPos / chapterIndex 可接受', () {
      final ReadingProgress? p = ReadingProgress.fromJson(<String, Object?>{
        'bookId': 'b',
        'chapterHref': 'h',
        'chapterIndex': 1, // int
        'chapterPos': 1, // int，应为 double
        'updatedAt': 5,
      });
      expect(p, isNotNull);
      expect(p!.chapterIndex, 1);
      expect(p.chapterPos, 1.0);
    });

    test('fromJson chapterPos 越界被 clamp', () {
      final ReadingProgress? p = ReadingProgress.fromJson(<String, Object?>{
        'bookId': 'b',
        'chapterHref': 'h',
        'chapterIndex': 1,
        'chapterPos': 9.9,
        'updatedAt': 5,
      });
      expect(p, isNotNull);
      expect(p!.chapterPos, 1.0);
    });

    test('copyWith 只改指定字段', () {
      final ReadingProgress p = _sample();
      final ReadingProgress q = p.copyWith(chapterIndex: 2, chapterPos: 0.9);
      expect(q.bookId, p.bookId);
      expect(q.chapterHref, p.chapterHref);
      expect(q.chapterIndex, 2);
      expect(q.chapterPos, closeTo(0.9, 1e-9));
      expect(q.updatedAt, p.updatedAt);
    });

    test('相等性按值（含 hashCode）', () {
      expect(_sample(), _sample());
      expect(_sample().hashCode, _sample().hashCode);
      expect(_sample(chapterPos: 0.1), isNot(_sample(chapterPos: 0.2)));
      expect(_sample(chapterHref: 'h1'), isNot(_sample(chapterHref: 'h2')));
    });

    test('localHint round-trip 保真；缺省时不写入该键', () {
      final ReadingProgress withHint = ReadingProgress(
        bookId: 'b',
        chapterHref: 'h',
        chapterIndex: 0,
        chapterPos: 0.3,
        updatedAt: 9,
        localHint: const LocalLayoutHint(
          scrollOffset: 12345.6,
          fontSize: 18,
          lineHeight: 1.6,
          viewportWidth: 411.4,
          viewportHeight: 866,
        ),
      );
      expect(withHint.toJson().containsKey('localHint'), isTrue);
      final ReadingProgress? restored = ReadingProgress.fromJson(withHint.toJson());
      expect(restored, withHint);
      expect(restored!.localHint!.scrollOffset, closeTo(12345.6, 1e-9));

      final ReadingProgress withoutHint = _sample();
      expect(withoutHint.toJson().containsKey('localHint'), isFalse);
      expect(ReadingProgress.fromJson(withoutHint.toJson())!.localHint, isNull);
    });

    test('localHint 非法（非 Map / 缺字段 / 类型错）→ 置 null，不拖垮整条进度', () {
      ReadingProgress? parse(Object? hint) =>
          ReadingProgress.fromJson(<String, Object?>{
            'bookId': 'b',
            'chapterHref': 'h',
            'chapterIndex': 0,
            'chapterPos': 0.5,
            'updatedAt': 1,
            'localHint': hint,
          });
      expect(parse('not a map')!.localHint, isNull);
      expect(parse(<String, Object?>{'scrollOffset': 1.0})!.localHint, isNull);
      expect(
        parse(<String, Object?>{
          'scrollOffset': 'x', // 应为 num
          'fontSize': 18,
          'lineHeight': 1.6,
          'viewportWidth': 400,
          'viewportHeight': 800,
        })!.localHint,
        isNull,
      );
    });

    test('hasSameSemantics 忽略 localHint', () {
      final ReadingProgress a = _sample();
      final ReadingProgress b = a.copyWith(
        localHint: const LocalLayoutHint(
          scrollOffset: 5,
          fontSize: 18,
          lineHeight: 1.6,
          viewportWidth: 1,
          viewportHeight: 1,
        ),
      );
      expect(a == b, isFalse);
      expect(a.hasSameSemantics(b), isTrue);
    });

    test('LocalLayoutHint.matches 按签名容差判等', () {
      const LocalLayoutHint hint = LocalLayoutHint(
        scrollOffset: 100,
        fontSize: 18,
        lineHeight: 1.6,
        viewportWidth: 411.4,
        viewportHeight: 866,
      );
      expect(
        hint.matches(
          fontSize: 18,
          lineHeight: 1.6,
          viewportWidth: 411.4,
          viewportHeight: 866,
        ),
        isTrue,
      );
      expect(
        hint.matches(
          fontSize: 20,
          lineHeight: 1.6,
          viewportWidth: 411.4,
          viewportHeight: 866,
        ),
        isFalse,
      );
      expect(
        hint.matches(
          fontSize: 18,
          lineHeight: 1.6,
          viewportWidth: 500,
          viewportHeight: 866,
        ),
        isFalse,
      );
    });
  });

  // 进度漂移修复（#36）的纯函数核心：探章逻辑从 widget 树里抽出来，
  // 用纯 `test()` 断言（本项目已两次实证 `testWidgets` + 真异步 IO 会挂死）。
  group('detectChapterAt（RC3/RC4 探章纯函数）', () {
    ChapterBlockSnapshot block(
      int index,
      double top,
      double height, {
      bool real = true,
    }) {
      return ChapterBlockSnapshot(
        index: index,
        top: top,
        height: height,
        reallyLoaded: real,
      );
    }

    test('空输入 → null（一个章块都没布局，完全无法确定）', () {
      expect(detectChapterAt(const <ChapterBlockSnapshot>[]), isNull);
    });

    test('覆盖规则：取真正覆盖视口顶的章块，而非「顶在上方」里最靠下者', () {
      // ch0 全在视口上方、ch1 覆盖视口顶 0.5、ch2 在视口下方 → 唯一覆盖者 ch1。
      final ({int chapterIndex, double? chapterPos})? hit =
          detectChapterAt(<ChapterBlockSnapshot>[
        block(0, -800, 300),
        block(1, -100, 500),
        block(2, 400, 500),
      ]);
      expect(hit, isNotNull);
      expect(hit!.chapterIndex, 1);
      // chapterPos = -top / height = 100 / 500。
      expect(hit.chapterPos, closeTo(0.2, 1e-9));
    });

    test('RC3：占位高章盖住视口顶 → 章可知、chapterPos 为 null（不采样）', () {
      final ({int chapterIndex, double? chapterPos})? hit =
          detectChapterAt(<ChapterBlockSnapshot>[
        block(0, -3000, 500),
        block(1, -100, 480, real: false), // 占位块，覆盖视口顶
        block(2, 380, 500),
      ]);
      expect(hit, isNotNull);
      expect(hit!.chapterIndex, 1);
      expect(hit.chapterPos, isNull);
    });

    test('RC3 守卫：占位章覆盖时不得由邻近真实章顶替（章级误判）', () {
      // 真实 ch0 全在视口上方——旧「最大 top≤0」规则会选它并把 pos clamp 成 1.0，
      // 把垃圾值写进 chapterPos；新规则必须报「占位、不可采样」。
      final ({int chapterIndex, double? chapterPos})? hit =
          detectChapterAt(<ChapterBlockSnapshot>[
        block(0, -5000, 480),
        block(1, -100, 480, real: false),
      ]);
      expect(hit, isNotNull);
      expect(hit!.chapterIndex, 1);
      expect(hit.chapterPos, isNull);
    });

    test('RC4 回落：视口顶在章间间隙 → 取最近真实章，不再把全在上方者 clamp 成 1.0', () {
      // 无块覆盖 0.5（ch0 底 -500、ch1 顶 +200）。
      // 旧规则会选 ch0（top≤0.5 里最靠下）算出 pos=clamp(800/300)=1.0——错章错位。
      final ({int chapterIndex, double? chapterPos})? hit =
          detectChapterAt(<ChapterBlockSnapshot>[
        block(0, -800, 300),
        block(1, 200, 500),
      ]);
      expect(hit, isNotNull);
      expect(hit!.chapterIndex, 1); // 距离 200 < 500.5，离视口顶更近
      expect(hit.chapterPos, 0.0); // 视口顶在其上方内边距里 → 章首
    });

    test('RC4 回落：视口顶在列表底部 → 最后真实章 pos=1.0；全是占位 → null', () {
      final ({int chapterIndex, double? chapterPos})? atEnd =
          detectChapterAt(<ChapterBlockSnapshot>[block(0, -600, 500)]);
      expect(atEnd, isNotNull);
      expect(atEnd!.chapterIndex, 0);
      expect(atEnd.chapterPos, 1.0);

      // 没有任何真实章可回落：占位 + 底部 / 占位 + 顶部内边距 → 都是 null。
      expect(
        detectChapterAt(<ChapterBlockSnapshot>[block(0, -600, 500, real: false)]),
        isNull,
      );
      expect(
        detectChapterAt(<ChapterBlockSnapshot>[block(0, 50, 480, real: false)]),
        isNull,
      );
    });

    test('视口顶与章顶齐平（容差内）→ pos clamp 到 0', () {
      final ({int chapterIndex, double? chapterPos})? hit =
          detectChapterAt(<ChapterBlockSnapshot>[
        block(0, 0.4, 500),
        block(1, 500.4, 500),
      ]);
      expect(hit, isNotNull);
      expect(hit!.chapterIndex, 0);
      expect(hit.chapterPos, 0.0);
    });
  });

  // M-PAGE T03：字符偏移比例换算 + 全书进度字数加权（选型 §6 拍板②）。
  group('chapterPos 字符偏移比例换算（§0）', () {
    test('chapterPosOfCharOffset：offset/total，clamp 0..1', () {
      expect(chapterPosOfCharOffset(0, 400), 0.0);
      expect(chapterPosOfCharOffset(100, 400), closeTo(0.25, 1e-9));
      expect(chapterPosOfCharOffset(400, 400), 1.0);
      expect(chapterPosOfCharOffset(500, 400), 1.0); // 越界 clamp
      expect(chapterPosOfCharOffset(-10, 400), 0.0);
    });

    test('chapterPosOfCharOffset：空章（total ≤ 0）→ 0.0，不抛异常', () {
      expect(chapterPosOfCharOffset(50, 0), 0.0);
      expect(chapterPosOfCharOffset(50, -1), 0.0);
      expect(chapterPosOfCharOffset(0, 0), 0.0);
    });

    test('charOffsetOfChapterPos：round-trip 与 clamp', () {
      expect(charOffsetOfChapterPos(0.25, 400), 100);
      expect(charOffsetOfChapterPos(0.0, 400), 0);
      expect(charOffsetOfChapterPos(1.0, 400), 400);
      expect(charOffsetOfChapterPos(1.7, 400), 400); // pos 越界 clamp
      expect(charOffsetOfChapterPos(-0.3, 400), 0);
      expect(charOffsetOfChapterPos(0.5, 0), 0); // 空章 → 0
      expect(charOffsetOfChapterPos(0.5, -5), 0);
    });

    test('charOffsetOfChapterPos 结果不越 [0, totalChars]', () {
      // 0.999 × 400 round 后 = 400，仍在界内；大 totalChars 不溢出。
      expect(charOffsetOfChapterPos(0.999, 400), 400);
      expect(charOffsetOfChapterPos(1.0, 1 << 40), 1 << 40);
    });

    test('互逆：chapterPos → offset → chapterPos 恒等（整数偏移）', () {
      for (final int offset in <int>[0, 1, 137, 250, 399, 400]) {
        final double pos = chapterPosOfCharOffset(offset, 400);
        expect(charOffsetOfChapterPos(pos, 400), offset);
      }
    });

    test('chapterPos 字段语义改文后 fromJson 宽容读取：几何比例值原样接受', () {
      // 旧版滚动视图写的几何比例（像素折算）与新语义同型同域——不标记不拒绝，
      // 首帧按比例估算落位，写回归一为字符偏移比例。
      final ReadingProgress? old = ReadingProgress.fromJson(<String, Object?>{
        'bookId': 'b',
        'chapterHref': 'h',
        'chapterIndex': 2,
        'chapterPos': 0.317, // 旧几何值
        'updatedAt': 42,
      });
      expect(old, isNotNull);
      expect(old!.chapterPos, closeTo(0.317, 1e-9));
      // JSON 字段名与格式不变（SYNC-02 不动）。
      expect(old.toJson()['chapterPos'], closeTo(0.317, 1e-9));
    });
  });

  group('overallReadingProgress：全书进度字数加权', () {
    test('权重可用 → 字数加权：前章字数 + pos × 本章字数', () {
      // 三章字数 [100, 300, 600]，Σ=1000。
      const List<int> w = <int>[100, 300, 600];
      expect(
        overallReadingProgress(
            chapterIndex: 0, chapterPos: 0.0, chapterCount: 3, chapterWeights: w),
        closeTo(0.0, 1e-9),
      );
      expect(
        overallReadingProgress(
            chapterIndex: 0, chapterPos: 0.5, chapterCount: 3, chapterWeights: w),
        closeTo(50 / 1000, 1e-9),
      );
      expect(
        overallReadingProgress(
            chapterIndex: 1, chapterPos: 0.5, chapterCount: 3, chapterWeights: w),
        closeTo((100 + 150) / 1000, 1e-9),
      );
      expect(
        overallReadingProgress(
            chapterIndex: 2, chapterPos: 1.0, chapterCount: 3, chapterWeights: w),
        closeTo(1.0, 1e-9),
      );
    });

    test('权重可用时大章主导进度（字数加权 ≠ 等权的判别）', () {
      // [10, 90]：第 0 章读完等权给 0.5、字数加权只给 0.1。
      const List<int> w = <int>[10, 90];
      final double weighted = overallReadingProgress(
          chapterIndex: 0, chapterPos: 1.0, chapterCount: 2, chapterWeights: w);
      expect(weighted, closeTo(0.1, 1e-9));
      final double equal = overallReadingProgress(
          chapterIndex: 0, chapterPos: 1.0, chapterCount: 2);
      expect(equal, closeTo(0.5, 1e-9));
    });

    test('权重 null → 等权退化，与迁移前公式逐位一致', () {
      // 迁移前：((index + pos) / count).clamp(0,1)。
      for (final (int i, double p) in <(int, double)>[
        (0, 0.0),
        (0, 0.42),
        (1, 1.0),
        (2, 0.5),
      ]) {
        expect(
          overallReadingProgress(
              chapterIndex: i, chapterPos: p, chapterCount: 3),
          ((i + p) / 3).clamp(0.0, 1.0),
        );
      }
    });

    test('权重长度不匹配 / 全 0（PDF 伪章）→ 等权退化', () {
      // 长度不匹配。
      expect(
        overallReadingProgress(
            chapterIndex: 1,
            chapterPos: 0.5,
            chapterCount: 3,
            chapterWeights: const <int>[10, 20]),
        closeTo(1.5 / 3, 1e-9),
      );
      // 全 0（图片页 / PDF 空文本伪章）→ 页数加权的退化形态 = 等权。
      expect(
        overallReadingProgress(
            chapterIndex: 1,
            chapterPos: 0.5,
            chapterCount: 3,
            chapterWeights: const <int>[0, 0, 0]),
        closeTo(1.5 / 3, 1e-9),
      );
      // 权重含负值按 0 计，Σ>0 仍走加权。
      expect(
        overallReadingProgress(
            chapterIndex: 1,
            chapterPos: 0.0,
            chapterCount: 2,
            chapterWeights: const <int>[100, -5]),
        closeTo(100 / 100, 1e-9),
      );
    });

    test('参数越界 clamp；chapterCount ≤ 0 → 0.0', () {
      const List<int> w = <int>[100, 100];
      expect(
        overallReadingProgress(
            chapterIndex: 7, chapterPos: 0.5, chapterCount: 2, chapterWeights: w),
        closeTo(1.5 / 2, 1e-9), // index clamp 到 1
      );
      expect(
        overallReadingProgress(
            chapterIndex: 0, chapterPos: 9.9, chapterCount: 2, chapterWeights: w),
        closeTo(100 / 200, 1e-9), // pos clamp 到 1 → 100/200
      );
      expect(
        overallReadingProgress(
            chapterIndex: -3, chapterPos: 0.5, chapterCount: 2, chapterWeights: w),
        closeTo(50 / 200, 1e-9), // index clamp 到 0
      );
      expect(overallReadingProgress(chapterIndex: 0, chapterPos: 0.5, chapterCount: 0),
          0.0);
      expect(overallReadingProgress(chapterIndex: 0, chapterPos: 0.5, chapterCount: -1),
          0.0);
    });
  });
}
