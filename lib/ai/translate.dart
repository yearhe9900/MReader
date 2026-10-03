// 划词翻译（M3-T02：`AI-02`）。
//
// 提示词组装是**纯函数**（可单测）；实际调用复用 [AiClient.chatStream] 底座
// 的流式 / 取消 / 并发闸（`AI-08`）。目标语言固定简体中文（`AI-02` 验收①
// 「选一段英文能出中文译文」——首版不做语言选择器）。
//
// **不做缓存**（`AI-08` 的「结果本地缓存」由 M3-T03 的 `summary_cache` 统一落）；
// 上下文范围（`AI-09` ①）由面板展示、由调用方决定传不传 [before]/[after]
// （最保守模式 `selectionOnly` 下两者皆 null）。
import 'ai_client.dart';
import 'provider_config.dart';

/// 翻译系统提示词：只输出译文，杜绝解释性前后缀。
const String kTranslateSystemPrompt =
    '你是专业的翻译引擎。把用户给出的「待翻译」文本翻译成简体中文。'
    '只输出译文本身，不要解释、不要标注、不要任何前后缀。'
    '若原文已是中文，给出自然流畅的中文润色即可。';

/// 组装翻译对话消息（纯函数）。
///
/// [before]/[after] 为选段的前后段落上下文（`AI-09` 非最保守模式才有）；
/// 两者皆 null 时只发送选中文本（最保守模式）。
List<AiMessage> translateMessages({
  required String text,
  String? before,
  String? after,
}) {
  final StringBuffer user = StringBuffer();
  if (before != null && before.isNotEmpty) {
    user.writeln('前文：');
    user.writeln(before);
    user.writeln();
  }
  user.writeln('待翻译：');
  user.writeln(text);
  if (after != null && after.isNotEmpty) {
    user.writeln();
    user.writeln('后文：');
    user.writeln(after);
  }
  return <AiMessage>[
    const AiMessage('system', kTranslateSystemPrompt),
    AiMessage('user', user.toString()),
  ];
}

/// 发起一次流式翻译（句柄可 cancel；错误经 stream.onError 分类抛出）。
AiCall translateSelection({
  required AiClient client,
  required AiProviderConfig config,
  required String apiKey,
  required String text,
  String? before,
  String? after,
}) {
  return client.chatStream(
    config: config,
    apiKey: apiKey,
    messages: translateMessages(text: text, before: before, after: after),
  );
}
