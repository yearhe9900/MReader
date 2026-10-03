// 划词释义（M3-T02：`AI-03` ①「释义返回且结合上下文」）。
//
// 与 [translateSelection] 同形制：提示词纯函数 + 复用 [AiClient.chatStream]
// 底座。语境义优先——`AI-03` 验收①明确要求「结合上下文」，故非最保守模式
// 下把前后段落一并给出；最保守模式只发词本身。
import 'ai_client.dart';
import 'provider_config.dart';

/// 释义系统提示词：语境义优先、简体中文、简洁分点。
const String kExplainSystemPrompt =
    '你是阅读助手。请结合上下文解释用户选中的词语或短语在文中的含义，'
    '语境义优先。用简体中文简洁输出：先给基本义，再给文中的语境义'
    '（如有用法或例句可附一句）。只输出解释内容。';

/// 组装释义对话消息（纯函数）。
List<AiMessage> explainMessages({
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
  user.writeln('词语：');
  user.writeln(text);
  if (after != null && after.isNotEmpty) {
    user.writeln();
    user.writeln('后文：');
    user.writeln(after);
  }
  return <AiMessage>[
    const AiMessage('system', kExplainSystemPrompt),
    AiMessage('user', user.toString()),
  ];
}

/// 发起一次流式释义（句柄可 cancel；错误经 stream.onError 分类抛出）。
AiCall explainSelection({
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
    messages: explainMessages(text: text, before: before, after: after),
  );
}
