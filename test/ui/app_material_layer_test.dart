// `app.dart` 透明 Material 地基的回归测试（PRD §11.4「黄色双下划线」防护）。
//
// 背景：玻璃态组件库不提供 Material 祖先；`WidgetsApp` 会给其子树的裸文本兜一层
// fallback 文本样式——也就是黄底双下划线（`WidgetsApp._errorTextStyle`）。
// `MaterialApp.builder` 里那层 `Material(type: MaterialType.transparency)` 正是用来
// 把它替换成真实主题样式的**地基**。本测试防止该层被误删。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/app.dart';
import 'package:mreader/main.dart';
import 'package:mreader/settings/settings_store.dart';

void main() {
  testWidgets('app.dart 的透明 Material 地基仍在，首屏不命中黄底双下划线',
      (WidgetTester tester) async {
    // ⚠️ 测试体在 FakeAsync 区里运行，真实文件 IO 必须走**同步** API：
    // 换成 `await Directory.systemTemp.createTemp()` 会让测试体永久挂起
    // （真异步 future 的完成回调排进 fake microtask 队列后无人排空）→ 10 分钟超时。
    final Directory dir =
        Directory.systemTemp.createTempSync('mreader_ui_material_');
    addTearDown(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    await tester.pumpWidget(
      MReaderApp(settings: SettingsStore(dir), home: const HomePage()),
    );
    await tester.pump();

    // ① 透明 Material 层仍在（这是「地基」的直接证据）。
    final Iterable<Material> materials =
        tester.widgetList<Material>(find.byType(Material));
    expect(
      materials.any((Material m) => m.type == MaterialType.transparency),
      isTrue,
      reason: 'app.dart 的 Material(type: MaterialType.transparency) 地基被移除；'
          '玻璃库下无 Material 祖先的文本会渲染成黄底双下划线（PRD §11.4）。',
    );

    // ② 首屏内容的有效文本样式不命中 fallback（黄底双下划线）。
    final TextStyle effective =
        DefaultTextStyle.of(tester.element(find.byType(HomePage))).style;
    expect(
      effective.decoration,
      isNot(TextDecoration.underline),
      reason: '命中 fallback 文本样式 = 缺少 DefaultTextStyle / Material 祖先，'
          '正是 PRD §11.4 的黄底双下划线问题。',
    );
  });
}
