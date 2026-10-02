// `TYP-07` / `TYP-08`：阅读外观面板——字体族选择 + 应用内亮度遮罩 + 预设背景色。
//
// 验收映射：
//   · `TYP-07` ①「可切换并立即生效」——点字体族 chip 即 [onChanged] 全量回传
//     新 [ReadingPrefs]，正文样式随 rebuild 立即切换（不内嵌字体文件，
//     由平台族名 + `reader_fonts.dart` 回退链解析，验收②③）；
//   · `TYP-08` ①「亮度实时生效且保留」——滑块**拖动中**即回传（实时），
//     由调用方即时落盘（保留）；②③ 的色板语义见 `reading_background.dart`。
//
// 本面板只做 UI；状态与持久化都在 `ReaderPage`（值对象不可变，整份回传）。
import 'package:flutter/material.dart';

import '../typography/reader_settings.dart';
import 'reading_background.dart';
import 'reading_prefs.dart';

/// 翻页方式的展示标签（面板专用文案）。
extension ReaderPageModeLabel on ReaderPageMode {
  String get label => switch (this) {
        ReaderPageMode.scroll => '滚动',
        ReaderPageMode.slide => '滑动',
        ReaderPageMode.cover => '覆盖',
        ReaderPageMode.none => '无动画',
      };
}

/// 阅读外观面板（字体 / 亮度 / 背景色）。
class ReadingAppearanceSheet extends StatefulWidget {
  const ReadingAppearanceSheet({
    super.key,
    required this.prefs,
    required this.onChanged,
  });

  /// 当前阅读偏好。
  final ReadingPrefs prefs;

  /// 每次调整**立即**回传整份新偏好（实时生效；持久化由调用方负责）。
  final ValueChanged<ReadingPrefs> onChanged;

  @override
  State<ReadingAppearanceSheet> createState() => _ReadingAppearanceSheetState();
}

class _ReadingAppearanceSheetState extends State<ReadingAppearanceSheet> {
  late ReadingPrefs _prefs = widget.prefs;

  /// 生成一份排版设置（显式构造而非 `copyWith`——[ReaderSettings.copyWith] 的
  /// 「fontFamily 传 null = 重置」语义会把未传入的字体族清掉，这里必须全字段可控）。
  ReaderSettings _settingsWith({required String? fontFamily}) {
    final ReaderSettings current = _prefs.settings;
    return ReaderSettings(
      fontSize: current.fontSize,
      lineHeight: current.lineHeight,
      fontFamily: fontFamily,
      themeMode: current.themeMode,
      pageMargin: current.pageMargin,
    );
  }

  /// 更新偏好并立即回传（实时生效）。
  void _emit(ReadingPrefs next) {
    setState(() => _prefs = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('外观', style: theme.textTheme.titleMedium),
            const SizedBox(height: 16),
            Text('字体', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            // `TYP-07`：系统可用字体族选择（系统默认 / 衬线 / 无衬线）。
            Wrap(
              spacing: 8,
              children: <Widget>[
                ChoiceChip(
                  key: const Key('font-default'),
                  label: const Text('系统默认'),
                  selected: _prefs.settings.fontFamily == null,
                  onSelected: (_) => _emit(_prefs.copyWith(
                    settings: _settingsWith(fontFamily: null),
                  )),
                ),
                ChoiceChip(
                  key: const Key('font-serif'),
                  label: const Text('衬线'),
                  selected: _prefs.settings.fontFamily == 'serif',
                  onSelected: (_) => _emit(_prefs.copyWith(
                    settings: _settingsWith(fontFamily: 'serif'),
                  )),
                ),
                ChoiceChip(
                  key: const Key('font-sans'),
                  label: const Text('无衬线'),
                  selected: _prefs.settings.fontFamily == 'sans-serif',
                  onSelected: (_) => _emit(_prefs.copyWith(
                    settings: _settingsWith(fontFamily: 'sans-serif'),
                  )),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text('翻页方式', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            // `M-PAGE T05-d`：模式切换由用户可选（选型拍板①③）。
            Wrap(
              spacing: 8,
              children: <Widget>[
                for (final ReaderPageMode mode in ReaderPageMode.values)
                  ChoiceChip(
                    key: Key('pageMode-${mode.name}'),
                    label: Text(mode.label),
                    selected: _prefs.pageMode == mode,
                    onSelected: (_) => _emit(_prefs.copyWith(pageMode: mode)),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text('亮度', style: theme.textTheme.labelLarge),
            Row(
              children: <Widget>[
                const Icon(Icons.brightness_low, size: 20),
                Expanded(
                  child: Slider(
                    key: const Key('brightness-slider'),
                    value: _prefs.brightness.clamp(
                      ReadingPrefs.minBrightness,
                      ReadingPrefs.maxBrightness,
                    ),
                    min: ReadingPrefs.minBrightness,
                    max: ReadingPrefs.maxBrightness,
                    divisions: 16,
                    label: '${(_prefs.brightness * 100).round()}%',
                    // 拖动中即回传：`TYP-08` ①「亮度实时生效」。
                    onChanged: (double value) =>
                        _emit(_prefs.copyWith(brightness: value)),
                  ),
                ),
                const Icon(Icons.brightness_high, size: 20),
              ],
            ),
            const SizedBox(height: 8),
            Text('背景色', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            // `TYP-08`：预设背景色（白 / 米黄 / 灰 / 纯黑）。
            Wrap(
              spacing: 8,
              children: <Widget>[
                for (final ReaderBackground background
                    in ReaderBackground.values)
                  ChoiceChip(
                    key: Key('background-${background.name}'),
                    selected: _prefs.background == background,
                    avatar: CircleAvatar(backgroundColor: background.dayColor),
                    label: Text(background.label),
                    onSelected: (_) =>
                        _emit(_prefs.copyWith(background: background)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
