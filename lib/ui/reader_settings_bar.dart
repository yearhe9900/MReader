// 阅读设置控制条（`TYP-01` ~ `TYP-03`）。
//
// 从 `lib/typography/reader_settings_bar.dart` 提取并扩展：字号 / 行距 / 页边距 / 主题。
// [ReaderSettings] 已移至 `lib/typography/reader_settings.dart`，此处只做 UI。
import 'package:flutter/material.dart';

import '../settings/settings_store.dart';
import '../typography/reader_settings.dart';

/// 底部控制条：A- / A+ 调字号，滑块调行距，页边距 / 主题切换。
///
/// 改动通过 [onChanged] 立即回传。
class ReaderSettingsBar extends StatelessWidget {
  const ReaderSettingsBar({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  final ReaderSettings settings;
  final ValueChanged<ReaderSettings> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool canShrink = settings.fontSize > ReaderSettings.minFontSize;
    final bool canGrow = settings.fontSize < ReaderSettings.maxFontSize;

    return Material(
      elevation: 8,
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: SizedBox(
          // 显式钉死高度：避免 Slider/Expanded 在异常约束下把 bottomNavigationBar
          // 撑高，进而把 Scaffold 的 appBar/body 挤掉（表现为「只剩底部一条」）。
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: <Widget>[
                IconButton(
                  tooltip: '减小字号',
                  icon: const Icon(Icons.text_decrease),
                  onPressed: canShrink
                      ? () => onChanged(
                            settings.copyWith(
                              fontSize: (settings.fontSize -
                                      ReaderSettings.fontStep)
                                  .clamp(
                                ReaderSettings.minFontSize,
                                ReaderSettings.maxFontSize,
                              ),
                            ),
                          )
                      : null,
                ),
                SizedBox(
                  width: 32,
                  child: Text(
                    settings.fontSize.toStringAsFixed(0),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                IconButton(
                  tooltip: '增大字号',
                  icon: const Icon(Icons.text_increase),
                  onPressed: canGrow
                      ? () => onChanged(
                            settings.copyWith(
                              fontSize: (settings.fontSize +
                                      ReaderSettings.fontStep)
                                  .clamp(
                                ReaderSettings.minFontSize,
                                ReaderSettings.maxFontSize,
                              ),
                            ),
                          )
                      : null,
                ),
                const SizedBox(width: 8),
                const Icon(Icons.format_line_spacing, size: 20),
                Expanded(
                  child: Slider(
                    value: settings.lineHeight
                        .clamp(ReaderSettings.minLineHeight,
                            ReaderSettings.maxLineHeight),
                    min: ReaderSettings.minLineHeight,
                    max: ReaderSettings.maxLineHeight,
                    divisions: 16,
                    label: settings.lineHeight.toStringAsFixed(1),
                    onChanged: (double value) =>
                        onChanged(settings.copyWith(lineHeight: value)),
                  ),
                ),
                // 页边距三档切换（TYP-01）
                _buildMarginToggle(context),
                const SizedBox(width: 4),
                // 主题三态切换（TYP-03）
                _buildThemeToggle(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 页边距三档：narrow → normal → wide → narrow …
  Widget _buildMarginToggle(BuildContext context) {
    final IconData icon;
    final String tooltip;
    switch (settings.pageMargin) {
      case PageMargin.narrow:
        icon = Icons.format_align_left;
        tooltip = '窄边距（点击切换）';
      case PageMargin.normal:
        icon = Icons.format_align_center;
        tooltip = '正常边距（点击切换）';
      case PageMargin.wide:
        icon = Icons.format_align_right;
        tooltip = '宽边距（点击切换）';
    }
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 20),
      onPressed: () {
        final PageMargin next;
        switch (settings.pageMargin) {
          case PageMargin.narrow:
            next = PageMargin.normal;
          case PageMargin.normal:
            next = PageMargin.wide;
          case PageMargin.wide:
            next = PageMargin.narrow;
        }
        onChanged(settings.copyWith(pageMargin: next));
      },
    );
  }

  /// 主题三态：system → light → dark → system …
  Widget _buildThemeToggle(BuildContext context) {
    final IconData icon;
    final String tooltip;
    switch (settings.themeMode) {
      case AppThemeMode.system:
        icon = Icons.brightness_auto;
        tooltip = '跟随系统（点击切换）';
      case AppThemeMode.light:
        icon = Icons.light_mode;
        tooltip = '日间（点击切换）';
      case AppThemeMode.dark:
        icon = Icons.dark_mode;
        tooltip = '夜间（点击切换）';
    }
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 20),
      onPressed: () {
        final AppThemeMode next;
        switch (settings.themeMode) {
          case AppThemeMode.system:
            next = AppThemeMode.light;
          case AppThemeMode.light:
            next = AppThemeMode.dark;
          case AppThemeMode.dark:
            next = AppThemeMode.system;
        }
        onChanged(settings.copyWith(themeMode: next));
      },
    );
  }
}
