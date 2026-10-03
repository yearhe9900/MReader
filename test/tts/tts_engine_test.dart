// `TTS-01` ③：段落可读性纯函数（M3-T06）。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/tts/tts_engine.dart';

void main() {
  group('shouldSpeakParagraph（纯标点 / 空白段跳过）', () {
    test('正常中文段 → 可读', () {
      expect(shouldSpeakParagraph('他推开门，雨还在下。'), isTrue);
    });

    test('纯标点段 → 跳过', () {
      expect(shouldSpeakParagraph('。！？……——'), isFalse);
      expect(shouldSpeakParagraph('，、；：'), isFalse);
    });

    test('纯空白段 / 空串 → 跳过', () {
      expect(shouldSpeakParagraph('   \t '), isFalse);
      expect(shouldSpeakParagraph('　　'), isFalse); // 全角空格（首行缩进同款）
      expect(shouldSpeakParagraph(''), isFalse);
    });

    test('含链接标记但无可读文字（纯锚点）→ 跳过', () {
      expect(shouldSpeakParagraph('\x00ID:anchor\x00'), isFalse);
    });

    test('链接标记内有文字 → 可读（只取可见文本判定）', () {
      expect(shouldSpeakParagraph('\x00A:href#x\x00雨\x00A\x00'), isTrue);
    });

    test('仅标签无内容 → 跳过；标签包文字 → 可读', () {
      expect(shouldSpeakParagraph('<b></b><i></i>'), isFalse);
      expect(shouldSpeakParagraph('<b>加粗</b>'), isTrue);
    });

    test('数字 / 字母 → 可读', () {
      expect(shouldSpeakParagraph('12345'), isTrue);
      expect(shouldSpeakParagraph('hello'), isTrue);
      expect(shouldSpeakParagraph('第3章 chapter three'), isTrue);
    });
  });
}
