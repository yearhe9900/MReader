// MReader 底栏标签图标（书架 / 笔记），按 mi_like_ui 图标集的同款口径手绘。
//
// 文件组织学习参考项目：导航 logo 全部收在一个 `nav_icons.dart` 里。本文件承载
// MReader 自有 logo、不进移植树；与移植树 `mi_like_ui/src/icons/logo.dart`
// （上游原件）是两份文件。
//
// 「书架」「笔记」参考项目没有对应图形，按其**同款风格**新画：
//   ① 归一化坐标系 100 单位高、横向按墨迹宽高比自然延伸（`_fit` 口径一致）；
//   ② 实心（filled）剪影、圆角、少量挖空细节（`PathOperation.difference`）；
//   ③ `*IconPainter` 命名、`shouldRepaint` 只看 `color`。
//
// ⚠️ 这两个 painter 不塞进移植树 `mi_like_ui/`：该树保持与上游**逐字节一致**
// （`diff -r` 零差异）。`_fit` 因此是本文件的私有副本（同口径）。
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 与移植树 `logo.dart` 的 `_fit` 同款：把 100 单位高的归一化坐标系
/// 等比映射进 [size]，并让墨迹水平中心落在盒中心。
void _fit(Canvas canvas, Size size, double inkCenterX) {
  final s = size.height / 100;
  canvas.save();
  canvas.translate(size.width / 2 - inkCenterX * s, 0);
  canvas.scale(s);
}

/// 书架 —— 一摞书（两本平放 + 一本斜靠在顶上）。墨迹 bbox：x 2..98（中心 50）、
/// y ≈1.8..94。三个实心圆角块、无挖空（参考项目同为纯实心多块剪影）。
class ShelfBooksIconPainter extends CustomPainter {
  ShelfBooksIconPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    _fit(canvas, size, 50);
    final p = Paint()..color = color;

    // 顶层：斜靠的书（-14°，绕自身中心转）。
    canvas.save();
    canvas.translate(55, 20);
    canvas.rotate(-14 * math.pi / 180);
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(-31, -11, 62, 22), const Radius.circular(8)),
      p,
    );
    canvas.restore();

    // 中层：平放的书（稍窄，向左收）。
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(12, 42, 78, 24), const Radius.circular(9)),
      p,
    );
    // 底层：平放的书（最宽）。
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(2, 70, 96, 24), const Radius.circular(9)),
      p,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ShelfBooksIconPainter old) => old.color != color;
}

/// 笔记 —— 切角便签（右上角折角剪影）+ 两条挖空「字行」。墨迹 bbox：x 14..86、
/// y 2..98；挖空细节与参考项目（挖眼/嘴、xor 星）同手法。
class NotesIconPainter extends CustomPainter {
  NotesIconPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    _fit(canvas, size, 50);
    final p = Paint()..color = color;

    // 便签本体：圆角矩形，右上角切出折角（28×28 直角三角形整体挖掉）。
    final body = Path()
      ..addRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(14, 2, 72, 96), const Radius.circular(20)),
      );
    final cornerCut = Path()
      ..moveTo(58, 2)
      ..lineTo(86, 2)
      ..lineTo(86, 30)
      ..close();
    var note = Path.combine(PathOperation.difference, body, cornerCut);

    // 两条「字行」挖空（上长下短，读作正文）。
    final lines = Path()
      ..addRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(28, 44, 44, 11), const Radius.circular(5.5)),
      )
      ..addRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(28, 66, 30, 11), const Radius.circular(5.5)),
      );
    note = Path.combine(PathOperation.difference, note, lines);
    canvas.drawPath(note, p);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant NotesIconPainter old) => old.color != color;
}
