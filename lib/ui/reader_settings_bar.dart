// 阅读设置控制条（`TYP-01` ~ `TYP-03`）：字号 / 行距 / 页边距 / 主题。
// [ReaderSettings] 在 `lib/typography/reader_settings.dart`，此处只做 UI。
//
// 分组收纳：控件收进「排版」分组盒、按用途切三个子块（`字号` / `行距` / `版面`），
// 子块间用竖分隔线划界，行距子块给滑块 `Expanded` 独占剩余宽度（单行平铺时窄屏
// 滑块被压到不足 80dp 不可用）。功能、文案、回调不变。
//
// 本组件是**内容层**（非导航层）：底色由 [ReaderControlBar] 的 Material 提供，
// 故不自带 `Material` / `SafeArea`（嵌套两层 Material 会在底部多出一条阴影）。
import 'package:flutter/material.dart';

import '../settings/settings_store.dart';
import '../typography/reader_settings.dart';
import 'reader_control_chrome.dart';

/// 底部控制条中的排版分组：A- / A+ 调字号，滑块调行距，页边距 / 主题切换。
///
/// 改动通过 [onChanged] 立即回传。
class ReaderSettingsBar extends StatelessWidget {
  const ReaderSettingsBar({
    super.key,
    required this.settings,
    required this.onChanged,
    this.showLabel = true,
  });

  final ReaderSettings settings;
  final ValueChanged<ReaderSettings> onChanged;

  /// 是否显示「排版」组标题（窄屏由 [ReaderControlBar] 的 LayoutBuilder 关闭，
  /// 阈值见 [kReaderControlLabelMinWidth]）。
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final bool canShrink = settings.fontSize > ReaderSettings.minFontSize;
    final bool canGrow = settings.fontSize < ReaderSettings.maxFontSize;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        12,
        kReaderControlRowPadding,
        12,
        kReaderControlRowPadding + 2,
      ),
      child: ReaderControlGroup(
        label: showLabel ? '排版' : null,
        expand: true,
        // 宽度不够时把行距滑块**换行独占一行**（下方 [LayoutBuilder]）：固定内容
        // （字号 3 控件 + 版面 2 控件 + 2 条分隔线 + 内外边距）实测约 334dp，窄屏
        // 留给滑块不足 30dp（等于没有）。宁可多一行高度，也不把滑块压成不可用——
        // 这是「空间不足时优先保证层级清晰与内容不重叠」的直接落法。
        //
        // ⚠️ [LayoutBuilder] 必须包在 [Expanded] 里：它在 [ReaderControlGroup] 的
        // `Row` 中是**非 flex 子节点**，而 `Row` 给非 flex 子节点无界宽度 → builder
        // 拿到 `maxWidth: infinity`，里面的 `Spacer`/`Expanded` 直接触发
        // 「non-zero flex but incoming width constraints are unbounded」断言。
        children: <Widget>[
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) =>
                  _buildFontBlock(context, constraints, canShrink, canGrow),
            ),
          ),
        ],
      ),
    );
  }

  /// 排版组的内容：宽屏时同行三块（字号 / 行距 / 版面），极窄屏时行距换行独占。
  ///
  /// 横向预算（实测）：固定内容 ≈ 322dp，393dp 屏上留给滑块 ≈ 71dp（可用）；再给
  /// 「行距」套内盒（+12dp）或加文字组标题（+96dp）滑块就归零。故：**行距块不套
  /// 内盒**（由两侧分隔线界定，宽度天然自适应），字号/版面保留内盒。
  Widget _buildFontBlock(
    BuildContext context,
    BoxConstraints constraints,
    bool canShrink,
    bool canGrow,
  ) {
    // 极窄屏（< 340dp，实践中已极少）才换行：宁可多一行高度，也把滑块从
    // 「不足 20dp 不可用」救回来。
    final bool stack = constraints.maxWidth < 340;
    if (stack) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              _fontButtons(context, canShrink, canGrow),
              const Spacer(),
              _layoutButtons(context),
            ],
          ),
          const SizedBox(height: 2),
          // 换行后的滑块独占整行宽 → 有充分拖动空间。
          SizedBox(width: double.infinity, child: _lineHeightSlider(context)),
        ],
      );
    }
    return Row(
      children: <Widget>[
        _fontButtons(context, canShrink, canGrow),
        const ReaderControlVDivider(),
        Expanded(child: _lineHeightSlider(context)),
        const ReaderControlVDivider(),
        _layoutButtons(context),
      ],
    );
  }

  /// 子块「字号」：减号 / 数值 / 加号。
  ///
  /// **不套内盒**：三个控件本身就是一组，靠左右分隔线界定即可；套盒要多付 12~16dp
  /// 横向空间，直接决定行距滑块是不可用还是可用（见 [_buildFontBlock] 的横向预算）。
  Widget _fontButtons(BuildContext context, bool canShrink, bool canGrow) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ReaderControlIconButton(
          key: const Key('reader-setting-font-dec'),
          tooltip: '减小字号',
          icon: Icons.text_decrease,
          onPressed: canShrink
              ? () => onChanged(
                    settings.copyWith(
                      fontSize: (settings.fontSize - ReaderSettings.fontStep)
                          .clamp(
                        ReaderSettings.minFontSize,
                        ReaderSettings.maxFontSize,
                      ),
                    ),
                  )
              : null,
        ),
        SizedBox(
          width: 34,
          child: Text(
            settings.fontSize.toStringAsFixed(0),
            key: const Key('reader-setting-font-value'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        ReaderControlIconButton(
          key: const Key('reader-setting-font-inc'),
          tooltip: '增大字号',
          icon: Icons.text_increase,
          onPressed: canGrow
              ? () => onChanged(
                    settings.copyWith(
                      fontSize: (settings.fontSize + ReaderSettings.fontStep)
                          .clamp(
                        ReaderSettings.minFontSize,
                        ReaderSettings.maxFontSize,
                      ),
                    ),
                  )
              : null,
        ),
      ],
    );
  }

  /// 子块「行距」：图标作标签 + 滑块。
  ///
  /// **不套内盒**（与字号/版面不同）：横向预算已到底（见 [_buildFontBlock]），行距块
  /// 本身由左右两条分隔线界定、边界已足够清楚，省下的宽度全部给滑块。
  Widget _lineHeightSlider(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.only(left: 6),
          child: Icon(Icons.format_line_spacing, size: kReaderControlGlyph),
        ),
        Expanded(
          child: Slider(
            key: const Key('reader-setting-line-height'),
            value: settings.lineHeight.clamp(
                ReaderSettings.minLineHeight, ReaderSettings.maxLineHeight),
            min: ReaderSettings.minLineHeight,
            max: ReaderSettings.maxLineHeight,
            divisions: 16,
            label: settings.lineHeight.toStringAsFixed(1),
            onChanged: (double value) =>
                onChanged(settings.copyWith(lineHeight: value)),
          ),
        ),
      ],
    );
  }

  /// 子块「版面」：页边距三档（`TYP-01`）+ 主题三态（`TYP-03`）。
  ///
  /// **不套内盒**，理由同 [_fontButtons]。
  Widget _layoutButtons(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _buildMarginToggle(context),
        _buildThemeToggle(context),
      ],
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
    return ReaderControlIconButton(
      key: const Key('reader-setting-margin'),
      tooltip: tooltip,
      icon: icon,
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
    return ReaderControlIconButton(
      key: const Key('reader-setting-theme'),
      tooltip: tooltip,
      icon: icon,
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
