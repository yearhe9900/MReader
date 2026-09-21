// 错误文案的**完整性**测试（`RD-05` / `RUST-04 ②` 唯一来源的护栏）。
//
// 目的：防止将来新增 `FormatErrorCode` 却忘记补文案——那会在运行时 `!` 断言崩溃。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/error_messages.dart';

/// 是否是中文文案（至少含一个 CJK 统一表意文字）。
bool _hasCjk(String text) =>
    RegExp(r'[\u4e00-\u9fff]').hasMatch(text);

void main() {
  group('kFormatErrorMessages', () {
    test('覆盖 FormatErrorCode 的全部枚举值', () {
      for (final FormatErrorCode code in FormatErrorCode.values) {
        expect(
          kFormatErrorMessages.containsKey(code),
          isTrue,
          reason: '缺少文案：$code（新增枚举必须同步补文案）',
        );
      }
      expect(
        kFormatErrorMessages.length,
        FormatErrorCode.values.length,
        reason: '文案表不应有多余键（枚举被删时文案也要删）',
      );
    });

    test('每条文案非空、含中文、且不像调试信息', () {
      for (final MapEntry<FormatErrorCode, String> entry
          in kFormatErrorMessages.entries) {
        final String message = entry.value;
        expect(message.trim(), isNotEmpty, reason: '${entry.key} 文案为空');
        expect(_hasCjk(message), isTrue, reason: '${entry.key} 文案不是中文');
        expect(message.trim(), message, reason: '${entry.key} 文案首尾不应有空白');
        expect(
          message.contains('Exception') || message.contains('null'),
          isFalse,
          reason: '${entry.key} 是面向用户的文案，不应出现调试术语',
        );
      }
    });

    test('MReaderFormatException.message 只取自文案表', () {
      for (final FormatErrorCode code in FormatErrorCode.values) {
        final MReaderFormatException error = MReaderFormatException(code);
        expect(error.message, kFormatErrorMessages[code]);
        expect(error.toString(), error.message, reason: '无 detail 时不追加括号');
      }
    });

    test('detail 只影响 toString，不影响面向用户的 message', () {
      const MReaderFormatException error = MReaderFormatException(
        FormatErrorCode.corruptFile,
        detail: 'OEBPS/content.opf',
      );
      expect(error.message, kFormatErrorMessages[FormatErrorCode.corruptFile]);
      expect(error.toString(), contains('OEBPS/content.opf'));
    });

    test('RUST-04 ② 口径：错误码与文案一一对应（无重复口径）', () {
      final Set<String> distinct = kFormatErrorMessages.values.toSet();
      expect(
        distinct.length,
        kFormatErrorMessages.length,
        reason: '不同错误码不应共用同一句话，否则用户无法区分原因',
      );
    });
  });
}
