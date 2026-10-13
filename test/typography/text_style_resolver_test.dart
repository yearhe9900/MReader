// resolveTextStyle 单测（`TYP-01`）。
//
// 纯 Dart `test()`（非 `testWidgets`）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/typography/reader_settings.dart';
import 'package:mreader/typography/text_style_resolver.dart';

void main() {
  final ThemeData lightTheme = ThemeData.light();

  group('resolveTextStyle（TYP-01 字号/行距/字体）', () {
    test('默认设置', () {
      const ReaderSettings s = ReaderSettings();
      final TextStyle style = resolveTextStyle(s, theme: lightTheme);
      expect(style.fontSize, 20);
      expect(style.height, 1.6);
      expect(style.fontFamily, isNull);
    });

    test('字号 12', () {
      const ReaderSettings s = ReaderSettings(fontSize: 12);
      final TextStyle style = resolveTextStyle(s, theme: lightTheme);
      expect(style.fontSize, 12);
    });

    test('字号 36', () {
      const ReaderSettings s = ReaderSettings(fontSize: 36);
      final TextStyle style = resolveTextStyle(s, theme: lightTheme);
      expect(style.fontSize, 36);
    });

    test('行距 1.0', () {
      const ReaderSettings s = ReaderSettings(lineHeight: 1.0);
      final TextStyle style = resolveTextStyle(s, theme: lightTheme);
      expect(style.height, 1.0);
    });

    test('行距 2.6', () {
      const ReaderSettings s = ReaderSettings(lineHeight: 2.6);
      final TextStyle style = resolveTextStyle(s, theme: lightTheme);
      expect(style.height, 2.6);
    });

    test('字体 serif', () {
      const ReaderSettings s = ReaderSettings(fontFamily: 'serif');
      final TextStyle style = resolveTextStyle(s, theme: lightTheme);
      expect(style.fontFamily, 'serif');
    });

    test('字体 sans-serif', () {
      const ReaderSettings s = ReaderSettings(fontFamily: 'sans-serif');
      final TextStyle style = resolveTextStyle(s, theme: lightTheme);
      expect(style.fontFamily, 'sans-serif');
    });

    test('字体 null（系统默认）', () {
      const ReaderSettings s = ReaderSettings();
      final TextStyle style = resolveTextStyle(s, theme: lightTheme);
      expect(style.fontFamily, isNull);
    });
  });
}
