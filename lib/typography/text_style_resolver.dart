// 字号 / 行距 / 字体 → TextStyle 的单一出口（`TYP-01` ~ `TYP-04`）：收敛 reader 侧
// 散落的 `TextStyle(fontSize: ..., height: ...)` 构造。纯函数，不依赖 IO。
import 'package:flutter/material.dart';

import 'reader_settings.dart';

/// 从 [settings] 产出正文 [TextStyle]。[theme] 预留（当前未使用）：未来按主题取
/// letter-spacing / word-spacing 时在本函数内扩展，避免改调用方。
TextStyle resolveTextStyle(ReaderSettings settings, {required ThemeData theme}) {
  return TextStyle(
    fontSize: settings.fontSize,
    height: settings.lineHeight,
    fontFamily: settings.fontFamily,
  );
}
