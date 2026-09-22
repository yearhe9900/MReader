// ReaderSettings 单测（`TYP-01` ~ `TYP-04`）。
//
// 纯 Dart `test()`，不依赖 Flutter / 不依赖 `testWidgets`。
// 本项目已两次实证 `testWidgets` 测试体内 `await` 真异步 IO 会挂死。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/settings/settings_store.dart';
import 'package:mreader/typography/reader_settings.dart';

void main() {
  group('ReaderSettings 默认值', () {
    test('默认值符合 TYP-01', () {
      const ReaderSettings s = ReaderSettings();
      expect(s.fontSize, 18);
      expect(s.lineHeight, 1.6);
      expect(s.fontFamily, isNull);
      expect(s.themeMode, AppThemeMode.system);
      expect(s.pageMargin, PageMargin.normal);
    });
  });

  group('ReaderSettings 取值范围', () {
    test('字号常量', () {
      expect(ReaderSettings.minFontSize, 12);
      expect(ReaderSettings.maxFontSize, 36);
      expect(ReaderSettings.fontStep, 1);
    });

    test('行距常量', () {
      expect(ReaderSettings.minLineHeight, 1.0);
      expect(ReaderSettings.maxLineHeight, 2.6);
    });
  });

  group('ReaderSettings.copyWith', () {
    test('只改 fontSize', () {
      const ReaderSettings s = ReaderSettings();
      final ReaderSettings s2 = s.copyWith(fontSize: 24);
      expect(s2.fontSize, 24);
      expect(s2.lineHeight, 1.6);
      expect(s2.fontFamily, isNull);
      expect(s2.themeMode, AppThemeMode.system);
      expect(s2.pageMargin, PageMargin.normal);
    });

    test('只改 lineHeight', () {
      const ReaderSettings s = ReaderSettings();
      final ReaderSettings s2 = s.copyWith(lineHeight: 2.0);
      expect(s2.lineHeight, 2.0);
      expect(s2.fontSize, 18);
    });

    test('只改 fontFamily', () {
      const ReaderSettings s = ReaderSettings();
      final ReaderSettings s2 = s.copyWith(fontFamily: 'serif');
      expect(s2.fontFamily, 'serif');
    });

    test('只改 themeMode', () {
      const ReaderSettings s = ReaderSettings();
      final ReaderSettings s2 = s.copyWith(themeMode: AppThemeMode.dark);
      expect(s2.themeMode, AppThemeMode.dark);
    });

    test('只改 pageMargin', () {
      const ReaderSettings s = ReaderSettings();
      final ReaderSettings s2 = s.copyWith(pageMargin: PageMargin.wide);
      expect(s2.pageMargin, PageMargin.wide);
    });
  });

  group('ReaderSettings 相等性', () {
    test('默认值相等', () {
      const ReaderSettings a = ReaderSettings();
      const ReaderSettings b = ReaderSettings();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('不同 fontSize 不相等', () {
      const ReaderSettings a = ReaderSettings();
      const ReaderSettings b = ReaderSettings(fontSize: 24);
      expect(a, isNot(equals(b)));
    });

    test('不同 fontFamily 不相等', () {
      const ReaderSettings a = ReaderSettings();
      const ReaderSettings b = ReaderSettings(fontFamily: 'serif');
      expect(a, isNot(equals(b)));
    });
  });

  group('PageMargin 档位', () {
    test('narrow = 12', () => expect(PageMargin.narrow.horizontal, 12));
    test('normal = 16', () => expect(PageMargin.normal.horizontal, 16));
    test('wide = 24', () => expect(PageMargin.wide.horizontal, 24));
  });
}
