// 字号 / 行距 / 字体 → TextStyle 的单一出口（`TYP-01` ~ `TYP-04`）。
//
// reader_page 的 3 处 `TextStyle(fontSize: ..., height: ...)` 统一改为调此函数，
// 避免散落的重复构造。纯函数，不依赖 IO。
import 'package:flutter/material.dart';

import 'reader_settings.dart';

/// 从 [settings] 产出正文 [TextStyle]。
///
/// [theme] 预留为参数（当前未使用；未来如需按主题取 letter-spacing / word-spacing
/// 等可在本函数内扩展，避免改调用方）。
TextStyle resolveTextStyle(ReaderSettings settings, {required ThemeData theme}) {
  return TextStyle(
    fontSize: settings.fontSize,
    height: settings.lineHeight,
    fontFamily: settings.fontFamily,
  );
}
