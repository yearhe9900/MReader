// `RD-04` / `NAV-01`：阅读页底部控制条。
//
// 组成：上/下一章 + 全书进度 + 排版设置（复用 [ReaderSettingsBar]）。
// 目录入口**统一放在 AppBar**（`NAV-01` 明确要求「AppBar 目录按钮」），故本控制条
// 不再重复放目录按钮，避免同一页出现两个功能相同的入口。
//
// ## 分组收纳（2026-10-06）
// 改前两行共 11 个控件平铺（`上一章/下一章/AI/朗读/朗读设置` + 进度文本 +
// `字号−/数值/字号+/行距图标/滑块/页边距/主题`），按钮 48dp 且无分组边界，窄屏上
// 彼此贴死、进度文本被挤到最右与滑块抢位。按「同一用途归一组」重排为三个带标题的
// 分组盒（`章节` / `朗读与 AI` / `排版`），组间留白 + 竖分隔线，尺寸统一到
// [kReaderControlButton]。功能、文案、回调、Key 全部不变，只改布局。
import 'package:flutter/material.dart';

import '../typography/reader_settings.dart';
import '../ui/reader_control_chrome.dart';
import '../ui/reader_settings_bar.dart';

/// 阅读页底部控制条。
class ReaderControlBar extends StatelessWidget {
  const ReaderControlBar({
    super.key,
    required this.settings,
    required this.onSettingsChanged,
    required this.chapterNumber,
    required this.chapterCount,
    required this.percent,
    required this.canGoPrev,
    required this.canGoNext,
    required this.onPrevChapter,
    required this.onNextChapter,
    this.onAi,
    this.onTts,
    this.ttsActive = false,
    this.onTtsSettings,
  });

  /// 当前排版设置（字号 / 行距）。
  final ReaderSettings settings;

  /// 排版设置变更回调。
  final ValueChanged<ReaderSettings> onSettingsChanged;

  /// 当前章序号（1 基）。
  final int chapterNumber;

  /// 总章数。
  final int chapterCount;

  /// 全书进度百分比（整数，0~100）。
  final int percent;

  /// 是否可回上一章（首章时为 false）。
  final bool canGoPrev;

  /// 是否可去下一章（末章时为 false）。
  final bool canGoNext;

  /// 回上一章。
  final VoidCallback onPrevChapter;

  /// 去下一章。
  final VoidCallback onNextChapter;

  /// AI 摘要入口（`TYP-05` 控制条含 AI 入口；`AI-04`/`AI-05`）。
  ///
  /// `null` = 摘要未启用（依赖未齐 / 全局开关关）→ 按钮不渲染。
  final VoidCallback? onAi;

  /// 朗读开关（`TTS-01`，M3-T06）：点一次从当前段开读，再点停止。
  final VoidCallback? onTts;

  /// 朗读进行中（按钮显示「停止」形态）。
  final bool ttsActive;

  /// 朗读设置入口（`TTS-04`/`TTS-05`：语速音色 / 定时停止；`M3-T08`）。
  ///
  /// `null` = 朗读设置未注入 → 按钮不渲染（同 [onAi] 降级口径）。
  final VoidCallback? onTtsSettings;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Material(
      elevation: 8,
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        // 用 LayoutBuilder 按**实际可用宽度**决定是否显示文字组标题：窄屏优先保证
        // 「层级清晰 + 内容不重叠」，标题让位给按钮与读数（阈值见
        // [kReaderControlLabelMinWidth] 的实测依据）。
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool showLabels =
                constraints.maxWidth >= kReaderControlLabelMinWidth;
            // 极窄屏让进度读数让位（阈值见 [kReaderControlProgressMinWidth]）：
            // 同一串文字仍由控制条正上方的 ReaderProgressIndicator 常驻显示。
            final bool showProgress =
                constraints.maxWidth >= kReaderControlProgressMinWidth;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // ── 第一行：章节组 + 朗读与 AI 组 ──
                // 两组各自成盒、互不贴死；进度读数进「章节」组成为该组的读数，
                // 不再孤零零漂在整行最右（改前它与滑块争夺同一段横向空间）。
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    12,
                    kReaderControlRowPadding,
                    12,
                    kReaderControlRowPadding,
                  ),
                  child: Row(
                    children: <Widget>[
                      Flexible(
                        child: ReaderControlGroup(
                          label: showLabels ? '章节' : null,
                          children: <Widget>[
                            ReaderControlIconButton(
                              key: const Key('reader-control-prev'),
                              tooltip: '上一章',
                              icon: Icons.skip_previous,
                              onPressed: canGoPrev ? onPrevChapter : null,
                            ),
                            ReaderControlIconButton(
                              key: const Key('reader-control-next'),
                              tooltip: '下一章',
                              icon: Icons.skip_next,
                              onPressed: canGoNext ? onNextChapter : null,
                            ),
                            // 读数用 Flexible + ellipsis：章节数越长（如 1152）
                            // 文本越宽，须能优雅截断而不是把整组撑爆。
                            if (showProgress)
                              Flexible(
                                child: Padding(
                                  padding:
                                      const EdgeInsets.only(left: 8, right: 4),
                                  child: Text(
                                    '第 $chapterNumber/$chapterCount 章 · $percent%',
                                    key: const Key('reader-control-progress'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (_hasAssistEntry) ...<Widget>[
                        const SizedBox(width: 8),
                        // 极窄屏（< kReaderControlProgressMinWidth）下第二组
                        // **不参与 flex**：两个 `Flexible` 互相挤到只剩 2px 会溢出
                        // （实测 340dp 溢出 2px、320dp 溢出 12px）。此时让它保持
                        // 自身宽度并换行独占，空间全给「章节」组。
                        if (showProgress)
                          Flexible(child: _buildAssistGroup(showLabels))
                        else
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: _buildAssistGroup(showLabels),
                          ),
                      ],
                    ],
                  ),
                ),
                const ReaderControlHDivider(),
                // ── 第二行：排版组（字号 / 行距 / 页边距 / 主题）──
                ReaderSettingsBar(
                  settings: settings,
                  onChanged: onSettingsChanged,
                  showLabel: showLabels,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 是否有「朗读与 AI」组的可用能力（三入口任一非 null）。
  bool get _hasAssistEntry =>
      onAi != null || onTts != null || onTtsSettings != null;

  /// 「朗读与 AI」分组盒（AI 摘要 / 朗读 / 朗读设置，按可用性出）。
  Widget _buildAssistGroup(bool showLabels) {
    return ReaderControlGroup(
      label: showLabels ? '朗读与 AI' : null,
      children: <Widget>[
        if (onAi != null)
          ReaderControlIconButton(
            key: const Key('reader-control-ai'),
            tooltip: 'AI 摘要',
            icon: Icons.auto_awesome,
            onPressed: onAi,
          ),
        if (onTts != null)
          ReaderControlIconButton(
            key: const Key('reader-control-tts'),
            tooltip: ttsActive ? '停止朗读' : '朗读',
            icon: ttsActive ? Icons.stop : Icons.play_arrow,
            onPressed: onTts,
          ),
        if (onTtsSettings != null)
          ReaderControlIconButton(
            key: const Key('reader-control-tts-settings'),
            tooltip: '朗读设置',
            icon: Icons.settings_voice,
            onPressed: onTtsSettings,
          ),
      ],
    );
  }
}
