// TTS 引擎抽象与段落可读性判定（`TTS-01`，M3-T06）。
//
// 分层：引擎只回答「一段话读完 / 被停掉 / 出错」三件事；推进策略（逐段、
// 跨章、纯标点跳过）全部在 `tts_controller.dart`——策略层可脱离平台在测试
// 里全量验证（PRD §9.2 按段落粒度）。
import '../reader/selection_overlay.dart' show plainParagraphText;

/// 一次 [TtsEngine.speak] 的结局。
enum TtsSpeakResult {
  /// 正常读完（controller 推进下一段）。
  done,

  /// 被 [TtsEngine.stop] 停掉（controller **不**推进——flutter_tts 的
  /// `stop()` 触发 `speak.onCancel` 而非 completion，源码实证）。
  cancelled,

  /// 引擎报错（controller 停止并上抛 onError）。
  error,
}

/// 系统 / 测试假引擎共用的最小契约（`TTS-01`）。
abstract class TtsEngine {
  /// 初始化并探测引擎可用性；`false` = 本机无可用语音引擎。
  ///
  /// PRD §15.3：flutter_tts 无 linux 实现 → Linux 上探测抛
  /// `MissingPluginException` → 这里返回 `false`，由 UI 层给中文提示
  /// 「本机未安装语音引擎」，**不得静默失败**。结果由实现缓存。
  Future<bool> init();

  /// 朗读一段纯文本；future 以结局完结（读完 / 停止 / 出错）。
  Future<TtsSpeakResult> speak(String text);

  /// 停止当前朗读；在途 [speak] 以 [TtsSpeakResult.cancelled] 完结。
  Future<void> stop();

  /// 语速 `0.0 ~ 1.0`（系统引擎口径；M3-T08 语速面板接线）。
  Future<void> setRate(double rate);
}

/// 段落是否值得朗读（`TTS-01` ③：纯标点 / 空白段被跳过）。
///
/// 先剥渲染标记（NUL 链接 / 锚点标记与 `<b>`/`<i>`，[plainParagraphText]），
/// 再查是否残留**可读字符**（字母 / 数字，含 CJK）：全角空格、纯标点、
/// 纯符号、纯标签段落一律跳过。
bool shouldSpeakParagraph(String raw) =>
    _readableChar.hasMatch(plainParagraphText(raw));

/// 可读字符：任意语言的字母与数字（`\p{L}` / `\p{N}`，含 CJK）。
final RegExp _readableChar = RegExp(r'[\p{L}\p{N}]', unicode: true);
