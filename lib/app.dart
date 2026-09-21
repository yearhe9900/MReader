// 应用根组件（M1-T01 骨架）。
//
// 由 main() 在完成平台初始化后构造并注入 [settings]；
// `home` 由调用方提供（当前是 M0 验证台，M1-T03 后换成书架页）。
//
// 注意：本批**不做玻璃视觉**（由 M1-T08 负责），lib/theme/ 目录本批不建；
// 这里只保证主题三态接线正确、且 `MaterialApp` 下不出现黄色双下划线文本。
import 'package:flutter/material.dart';

import 'settings/settings_store.dart';

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
  ThemeMode get _themeMode {
    switch (widget.settings.settings.themeMode) {
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
      case AppThemeMode.system:
        return ThemeMode.system;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MReader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      themeMode: _themeMode,
      // 玻璃态组件库（M1-T08 接入）自身不提供 Material 祖先，缺省时其下的
      // 文本会渲染成黄色双下划线（PRD §11.4 已知限制）；这里统一补一层透明
      // Material。属于必须先接好的地基，不等到 M1-T08。
      builder: (BuildContext context, Widget? child) {
        return Material(
          type: MaterialType.transparency,
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: widget.home ?? const SizedBox.shrink(),
    );
  }
}
