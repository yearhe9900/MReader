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
}
