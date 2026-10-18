// 应用根组件（M1-T01 骨架）。
//
// 由 main() 在完成平台初始化后构造并注入 [settings]；
// `home` 由调用方提供（当前是 M0 验证台，M1-T03 后换成书架页）。
//
// 注意：本批**不做玻璃视觉**（由 M1-T08 负责），lib/theme/ 目录本批不建；
// 这里只保证主题三态接线正确、且 `MaterialApp` 下不出现黄色双下划线文本。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'settings/settings_store.dart';
import 'theme/app_theme.dart';
import 'ui/glass_scope.dart';

/// 应用根组件。
class MReaderApp extends StatefulWidget {
  const MReaderApp({super.key, required this.settings, this.home});

  /// 设置服务（显式注入，非全局单例）。
  final SettingsStore settings;

  /// 首屏；缺省时占位（真正的书架页在 M1-T03 接入）。
  final Widget? home;

  @override
  State<MReaderApp> createState() => _MReaderAppState();
}

class _MReaderAppState extends State<MReaderApp> {
  @override
  void initState() {
    super.initState();
    widget.settings.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 把持久化的主题三态映射为 Flutter 的 [ThemeMode]（`TYP-03`）。
  ///
  /// 映射本身在 `lib/theme/app_theme.dart`（纯函数，便于单测）——`UI-01` ② 的有效亮度
  /// 解析同处一地，避免「一处主题两处口径」。
  ThemeMode get _themeMode => resolveThemeMode(widget.settings.settings.themeMode);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MReader',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _themeMode,
      // 玻璃态组件库（M1-T08 接入）自身不提供 Material 祖先，缺省时其下的
      // 文本会渲染成黄色双下划线（PRD §11.4 已知限制）；这里统一补一层透明
      // Material。属于必须先接好的地基，不等到 M1-T08。
      // `GlassScopeProvider`（M2b-T07 档位生效接线）包在 Material 之下、
      // 路由树之上：全路由（含弹层 Overlay）共享生效档位，切档整树跟档。
      builder: (BuildContext context, Widget? child) {
        // `UI-08` edge-to-edge（2026-10-19 上游平板模式批）：状态栏 / 手势条
        // 透明化，让状态栏背后是**页面自己的底色 / 顶栏磨砂**，系统不再加那层
        // 灰压色（`main.dart` 的 `setEnabledSystemUIMode(edgeToEdge)` 已把内容
        // 铺到状态栏下面，这里配套把两条栏的底色与图标亮度交还给应用）。
        //
        // 挂在 `builder`（全路由之上）：导航 / 弹层 / 覆盖层都吃同一份样式，
        // 不随路由变化抖动。亮度取 `GlassScope.brightnessOf`——与玻璃控件、
        // 导航栏标签墨色**同一出处**（`UI-01` ②：跟应用主题三态，含 system 档
        // 解析 platformBrightness），避免「一处主题两处口径」。
        // 图标翻转口径与上游 `demo_app.dart` 的 `AnnotatedRegion` 逐字一致。
        final bool light =
            GlassScope.brightnessOf(context) != Brightness.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness:
                light ? Brightness.dark : Brightness.light,
            statusBarBrightness: light ? Brightness.light : Brightness.dark,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarDividerColor: Colors.transparent,
            systemNavigationBarIconBrightness:
                light ? Brightness.dark : Brightness.light,
            systemNavigationBarContrastEnforced: false,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: GlassScopeProvider(
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        );
      },
      home: widget.home ?? const SizedBox.shrink(),
    );
  }
}
