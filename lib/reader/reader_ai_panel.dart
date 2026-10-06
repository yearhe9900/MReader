// 阅读页 AI 能力面板（`AI-04` ~ `AI-07` 的**分组收纳入口**）。
//
// ## 为什么需要这个面板（2026-10-06）
// 改前 AppBar 的 `actions` 平铺 9 个图标按钮（搜索/书签/前情回顾/AI 摘要/AI 问答/
// 人物与设定/外观/目录/全屏）。9 × 48dp = 432dp > 手机屏宽（实测 393dp 机型），
// 于是**书名与副标题被完全挤掉**（标题 `maxLines:1` + ellipsis 在 0 宽下什么都不剩），
// 按钮之间也彼此贴死。
//
// 划分依据：**同为「AI 增强」用途的 4 个入口归为一个分组**，收进本面板（一次点开、
// 面板内按行陈列）；`NAV-01` 要求「AppBar 目录按钮」，`CNT-06`/`TYP-06`/`TYP-03`/
// `TYP-09` 的入口是页面级操作，继续留在 AppBar 分组内。功能、文案、回调、Key 均
// 逐条保持原样，只是入口位置从「顶栏第 3~6 个图标」变为「顶栏单个 AI 分组 → 面板行」。
//
// 面板复用设置页的分组卡片组件（`SettingsGroupCard` / `SettingsTile`），与全局
// 设置页视觉一致；面板经 [GlassOverlays.showSheet] 弹出，跟随玻璃档位。
import 'package:flutter/material.dart';

import '../ui/glass_kit.dart';
import '../ui/settings_kit.dart';

/// 弹出阅读页 AI 面板。
///
/// 行按「先摘要后问答、再人物梳理、末位回顾」排列（= 原 AppBar 中的物理顺序），
/// [onRecap] 为 `null` 时不渲染该行（会话内已进入过回顾，见 `AI-05` ②）。
Future<void> showReaderAiPanel({
  required BuildContext context,
  required VoidCallback onSummary,
  required VoidCallback onAsk,
  required VoidCallback onEntities,
  VoidCallback? onRecap,
}) {
  return GlassOverlays.showSheet<void>(
    context: context,
    builder: (BuildContext sheetContext) => OpaqueContentSurface(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('AI 助手', style: Theme.of(sheetContext).textTheme.titleMedium),
              const SizedBox(height: 12),
              SettingsGroupCard(
                children: <Widget>[
                  SettingsTile(
                    key: const Key('reader-summary'),
                    icon: Icons.auto_awesome,
                    accent: SettingsAccents.purple,
                    title: 'AI 摘要',
                    subtitle: '生成当前章梗概，可重新生成',
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      onSummary();
                    },
                  ),
                  SettingsTile(
                    key: const Key('reader-ask'),
                    icon: Icons.question_mark,
                    accent: SettingsAccents.blue,
                    title: 'AI 问答',
                    subtitle: '基于原文检索作答，附可跳转引用',
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      onAsk();
                    },
                  ),
                  SettingsTile(
                    key: const Key('reader-entities'),
                    icon: Icons.people_alt_outlined,
                    accent: SettingsAccents.green,
                    title: '人物与设定',
                    subtitle: '人物关系与专有名词梳理',
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      onEntities();
                    },
                  ),
                  if (onRecap != null)
                    SettingsTile(
                      key: const Key('reader-recap'),
                      icon: Icons.history,
                      accent: SettingsAccents.orange,
                      title: '前情回顾',
                      subtitle: '基于上次读到位置的回顾',
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        onRecap();
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
