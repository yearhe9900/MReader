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
}
