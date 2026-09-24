// `TYP-07`：逻辑字体族（系统默认 / 衬线 / 无衬线）的**跨平台回退链**。
//
// 不内嵌字体文件（`TYP-07` 验收③：`pubspec.yaml` 无 `fonts:` 段）——一切由
// 平台字体解析。`'serif'` / `'sans-serif'` 是逻辑族名：Android 直接可解析
// （Noto Serif / Noto Sans）；Windows 的 DirectWrite **不认**通用族名，
// 会整族回落默认无衬线——于是这里给 [TextStyle.fontFamilyFallback] 挂一条
// 回退链：拉丁字形回落 Times New Roman / Segoe UI，中日韩字形回落
// 宋体 / 微软雅黑 / 思源系列（按序尝试，未安装的族自动跳过），
// 保证「Windows 与 Android 均可切换并立即生效」且**中文无豆腐块**（验收①②）。

/// 按逻辑字体族给出回退链；系统默认（`null`）不加回退（走引擎默认回退）。
List<String>? readerFontFallback(String? fontFamily) {
  switch (fontFamily) {
    case 'serif':
      return const <String>[
        'Times New Roman',
        'Georgia',
        'Noto Serif CJK SC',
        'Source Han Serif SC',
        'Songti SC',
        'SimSun',
      ];
    case 'sans-serif':
      return const <String>[
        'Segoe UI',
        'Microsoft YaHei UI',
        'Noto Sans CJK SC',
        'Source Han Sans SC',
        'PingFang SC',
      ];
    default:
      return null;
  }
}
