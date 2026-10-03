// 章节摘要 / 全书摘要 / 前情回顾的提示词与流式调用（M3-T03：`AI-04`/`AI-05`）。
//
// 形制与 [explainSelection] 同款：提示词纯函数 + 复用 [AiClient.chatStream]
// 底座。三个功能共用一套「梗概」语言约束，差异只在 user 消息的组装：
//   · 章节摘要（`AI-04`）：单章全文 → ≤maxChars 字梗概；
//   · 全书摘要（`AI-05` ①）：各章梗概列表 → 合并成全书摘要（分章节递进后合成）；
//   · 前情回顾（`AI-05` ②）：近 N 章梗概 + 上次读到位置 → 面向「回来继续读」的回顾。
import 'ai_client.dart';
import 'provider_config.dart';

/// 章节梗概系统提示词（`AI-04` ①：200 字内覆盖主要情节）。
const String kSummarizeSystemPrompt =
    '你是阅读助手。请为给定章节生成简体中文梗概：覆盖主要情节与关键转折，'
    '客观陈述，不逐句复述、不加标题列表、不发表评论。'
    '严格控制在要求的字数以内，直接输出梗概正文。';

/// 合并（各章梗概 → 全书摘要 / 前情回顾）系统提示词。
const String kMergeSummarySystemPrompt =
    '你是阅读助手。下面给出一本书若干章节的依次梗概，请合并成一段连贯的'
    '简体中文摘要：按章节顺序串联主线，保留关键情节与人物动向，'
    '不逐条罗列、不加标题列表、不发表评论。严格控制在要求的字数以内，'
    '直接输出正文。';

/// 单块（超长章节分块）片段梗概系统提示词。
const String kSummaryChunkSystemPrompt =
    '你是阅读助手。请为给定文本片段生成简体中文梗概：只保留主要情节与'
    '关键信息，客观陈述，不加标题列表。直接输出梗概正文。';

/// 默认目标长度（字；`AI-04` ① 验收基线「200 字内」）。
const int kSummaryDefaultChars = 200;

/// 超长章分块阈值（字符数；PRD §8.3「超长则分块递进」）。
const int kSummaryChunkChars = 6000;

/// 组装章节摘要消息（纯函数）。
///
/// [maxChars] 为目标字数（`AI-04`「可指定长度」）；[title] 为章标题（有则带上，
/// 帮助模型定位，不改变输出格式要求）。
List<AiMessage> summarizeMessages({
  required String text,
  int maxChars = kSummaryDefaultChars,
  String? title,
}) {
  final StringBuffer user = StringBuffer();
  user.writeln('目标长度：不超过 $maxChars 字。');
  if (title != null && title.isNotEmpty) {
    user.writeln('章节标题：$title');
  }
  user.writeln('章节正文：');
  user.write(text);
  return <AiMessage>[
    const AiMessage('system', kSummarizeSystemPrompt),
    AiMessage('user', user.toString()),
  ];
}

/// 组装「合并成全书摘要 / 前情回顾」消息（纯函数）。
///
/// [parts] 为按章节顺序的梗概片段（每项 "标题：梗概" 或纯梗概）；
/// [maxChars] 合并后的目标字数；[instruction] 追加的任务说明
/// （前情回顾传「上次读到第 X 章」等背景，全书摘要传 null）。
List<AiMessage> mergeSummaryMessages({
  required List<String> parts,
  int maxChars = 800,
  String? instruction,
}) {
  final StringBuffer user = StringBuffer();
  user.writeln('目标长度：不超过 $maxChars 字。');
  if (instruction != null && instruction.isNotEmpty) {
    user.writeln(instruction);
    user.writeln();
  }
  user.writeln('各章梗概（按章节顺序）：');
  for (int i = 0; i < parts.length; i++) {
    user.writeln('${i + 1}. ${parts[i]}');
  }
  return <AiMessage>[
    const AiMessage('system', kMergeSummarySystemPrompt),
    AiMessage('user', user.toString()),
  ];
}

/// 组装超长章单块片段梗概消息（纯函数）。
List<AiMessage> summaryChunkMessages({
  required String text,
  int chunkChars = kSummaryChunkChars,
}) {
  return <AiMessage>[
    const AiMessage('system', kSummaryChunkSystemPrompt),
    AiMessage('user', '片段长度上限 $chunkChars 字。\n$text'),
  ];
}

/// 发起一次流式章节摘要（句柄可 cancel；错误经 stream.onError 分类抛出）。
AiCall summarizeChapter({
  required AiClient client,
  required AiProviderConfig config,
  required String apiKey,
  required String text,
  int maxChars = kSummaryDefaultChars,
  String? title,
}) {
  return client.chatStream(
    config: config,
    apiKey: apiKey,
    messages: summarizeMessages(text: text, maxChars: maxChars, title: title),
  );
}

/// 发起一次流式合并（各章梗概 → 全书摘要 / 前情回顾）。
AiCall mergeSummaries({
  required AiClient client,
  required AiProviderConfig config,
  required String apiKey,
  required List<String> parts,
  int maxChars = 800,
  String? instruction,
}) {
  return client.chatStream(
    config: config,
    apiKey: apiKey,
    messages: mergeSummaryMessages(
      parts: parts,
      maxChars: maxChars,
      instruction: instruction,
    ),
  );
}
