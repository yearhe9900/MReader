// `META-08` / `META-09`：封面**大图查看**与**本地选图**（薄 widget 层）。
//
// `PERF-02`：封面字节**不常驻内存**——大图每次 `readFull` 现读，看完即弃；
// 选图走已有 `file_picker`（`type: FileType.image`，`withData: true` 取字节），
// **不引入任何新依赖**。
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../meta/cover_store.dart';
import '../model/book_meta.dart';
import 'glass_kit.dart';

/// 从本地图片选一张作为封面（`META-09`）：返回图片字节；取消 / 空文件 → `null`。
///
/// 落盘与旧封面清理（`META-06 ①`）由调用方经
/// [`CoverStore.replaceWithUserPick`] 完成，本函数只负责「拿到字节」。
Future<Uint8List?> pickCoverBytes() async {
  final FilePickerResult? result = await FilePicker.platform.pickFiles(
    type: FileType.image,
    withData: true,
  );
  if (result == null || result.files.isEmpty) return null;
  final Uint8List? bytes = result.files.first.bytes;
  if (bytes == null || bytes.isEmpty) return null;
  return bytes;
}

/// 点封面看大图（`META-08 ①`）：`readFull` **现读后展示**（`PERF-02`）。
///
/// 玻璃弹窗（`UI-03`，[GlassOverlays.showAlert]）+ `InteractiveViewer`；barrier
/// 可关（tap 外关闭）。非 [StoredCover]（无封面 / 合成封面）与字节缺失时**静默返回**。
Future<void> showCoverFullScreen(
  BuildContext context,
  CoverStore coverStore,
  CoverRef ref,
) async {
  if (ref is! StoredCover) return;
  final Uint8List? bytes = await coverStore.readFull(ref);
  if (bytes == null || bytes.isEmpty) return;
  if (!context.mounted) return;
  final Size size = MediaQuery.sizeOf(context);
  await GlassOverlays.showAlert<void>(
    context: context,
    // 纯看图：只留一个「关闭」（库断言 1–3 个动作，空列表 debug 下直接 AssertionError）。
    actions: <GlassDialogAction>[
      GlassDialogAction(
        label: '关闭',
        onPressed: () => Navigator.pop(context),
      ),
    ],
    barrierDismissible: true,
    // 放开到整屏宽，内容自行收边（卡片 padding 20 × 2 + 页边 16 × 2 ≈ 72）。
    maxWidth: size.width,
    content: SizedBox(
      width: size.width - 72,
      height: size.height * 0.8,
      child: InteractiveViewer(
        child: Image.memory(bytes, fit: BoxFit.contain),
      ),
    ),
  );
}
