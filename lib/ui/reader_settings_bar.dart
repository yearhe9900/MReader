// 阅读设置值对象 + 底部控制条。
//
// 之所以单独拆一个文件：字号 / 行距是整个 demo 的**验证重点**——它证明
// 纯 Flutter 侧排版参数完全可控、且能实时生效。
import 'package:flutter/material.dart';

/// 阅读设置。字号单位是逻辑像素，行距是倍数（Flutter 的 `TextStyle.height`）。
class ReaderSettings {
  const ReaderSettings({this.fontSize = 18, this.lineHeight = 1.6});

  final double fontSize;
  final double lineHeight;

  ReaderSettings copyWith({double? fontSize, double? lineHeight}) {
    return ReaderSettings(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
    );
  }
}

/// 底部控制条：A- / A+ 调字号，滑块调行距。改动通过 [onChanged] 立即回传。
class ReaderSettingsBar extends StatelessWidget {
  const ReaderSettingsBar({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  final ReaderSettings settings;
  final ValueChanged<ReaderSettings> onChanged;

  static const double _minFontSize = 12;
  static const double _maxFontSize = 36;
  static const double _fontStep = 1;

  static const double _minLineHeight = 1.0;
  static const double _maxLineHeight = 2.6;
  static const int _lineHeightDivisions = 16;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool canShrink = settings.fontSize > _minFontSize;
    final bool canGrow = settings.fontSize < _maxFontSize;

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
                              fontSize: (settings.fontSize - _fontStep)
                                  .clamp(_minFontSize, _maxFontSize),
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
                              fontSize: (settings.fontSize + _fontStep)
                                  .clamp(_minFontSize, _maxFontSize),
                            ),
                          )
                      : null,
                ),
                const SizedBox(width: 8),
                const Icon(Icons.format_line_spacing, size: 20),
                Expanded(
                  child: Slider(
                    value: settings.lineHeight
                        .clamp(_minLineHeight, _maxLineHeight),
                    min: _minLineHeight,
                    max: _maxLineHeight,
                    divisions: _lineHeightDivisions,
                    label: settings.lineHeight.toStringAsFixed(1),
                    onChanged: (double value) =>
                        onChanged(settings.copyWith(lineHeight: value)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
