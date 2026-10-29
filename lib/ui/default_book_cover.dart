// 无封面书籍的**默认封面**（`META-07` ② 的「默认占位图」）。
//
// 视觉照抄 anx-reader 的默认封面（`widgets/bookshelf/book_cover.dart:45-123`）：
//   · 底色 = `Colors.primaries[书名.hashCode % length].shade200`——每本书按书名
//     哈希拿一张**浅色**卡片；文字色按底色亮度**自适应黑/白**；
//   · 顶部书名（最多 3 行）+ 底部作者 + 中间 `Spacer`；右下角一颗**旋转 15°** 的
//     书本水印（文字色 10% 透明，负偏移故意探出封面、由外层裁切）；
//   · 四个尺寸**全部与封面宽度成比例**（标题 ×0.12 / 作者 ×0.08 / 水印 ×0.8 /
//     内边距 ×0.08）——同一本书在书架与详情页大小一致，换列数也不会跳。
//
// 未采纳（anx 有、本项目不做）：封面超椭圆裁剪 + 描边；anx 的两个显示开关
// （本项目无这两个设置项，恒显示）。**不采纳开关 ≠ 改变默认观感**：两开关默认
// 都是 `true`，「恒显示」即 anx 未改设置时的默认表现。
//
// 三处刻意的本工程处理：
//   · **10% 透明的水印不是「半透明内容层」**：它叠在**不透明**底色之上，`UI-04`
//     约束的是容器 / 背景，不是前景笔画，故红线不破；
//   · **自带裁切**：anx 的水印故意画出封面之外，本组件用 `ClipPath`
//     （[MiSquircleClipper]，与书卡外框同一 Squircle 裁形）兜住，
//     调用方不必再管；圆角由 [radius] 传入；
//   · **底色画在子树内（`ColoredBox`），不用 `Ink`**：`Ink` 是墨迹特性、由更上层
//     的 `Material` 绘制——会**逃逸本组件的 `ClipPath`**（封面变方角），且位于
//     外层投影画笔的**底下**被染暗（「太暗了」）。代价：`InkWell`
//     水波纹不再压在封面之上、只在透明信息区可见（同 anx 的非墨迹层形态）。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'mi_like_ui/mi_like_ui.dart' show MiSquircleClipper;

/// 某本书的默认封面底色（anx `book_cover.dart:57-59`）。
///
/// ⚠️ 用 `String.hashCode`：Dart 的 `%` 是欧几里得取模，负数结果也非负，故无需
/// `abs()`（anx 同此写法）。**代价**：`String.hashCode` 只保证同一 SDK 版本内稳定，
/// 换 SDK 版本可能让同一本书换色（纯观感）；要跨版本稳定换 `lib/meta/synth_cover.dart`
/// 的确定性 FNV-1a（`synthCoverCacheKey`）即可。
Color defaultBookCoverColor(String title) =>
    Colors.primaries[title.hashCode % Colors.primaries.length].shade200;

/// 叠在 [defaultBookCoverColor] 之上的文字 / 水印色（anx `book_cover.dart:23-26`）：
/// 按底色亮度自适应，浅底给黑字、深底给白字。
Color defaultBookCoverInk(Color background) =>
    ThemeData.estimateBrightnessForColor(background) == Brightness.dark
    ? Colors.white
    : Colors.black;

/// 无封面书籍的默认封面（见文件头注；视觉口径逐条对映 anx 出处）。
class DefaultBookCover extends StatelessWidget {
  /// 创建默认封面。
  const DefaultBookCover({
    super.key,
    required this.title,
    required this.author,
    this.radius = 8,
  });

  /// 书名（anx 画在顶部，最多 3 行）。
  final String title;

  /// 作者（anx 画在底部，单行）。为空时该行不占可见空间（anx 亦画空串）。
  final String author;

  /// 圆角（本组件负责裁切）。缺省 8 是本组件的既有默认（详情页等处直接用）；
  /// 书架书卡显式传 `kBookCoverRadius`（= Mi 圆角 20），不依赖本默认值。
  final double radius;

  @override
  Widget build(BuildContext context) {
    final Color background = defaultBookCoverColor(title);
    final Color ink = defaultBookCoverInk(background);
    final Widget content = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // anx 的四个尺寸全部按**封面宽度**算（`book_cover.dart:48-55`）。
        final double width = constraints.maxWidth;
        final double titleFontSize = width * 0.12;
        final double authorFontSize = width * 0.08;
        final double iconSize = width * 0.8;
        final double padding = width * 0.08;

        return Stack(
          children: <Widget>[
            Padding(
              padding: EdgeInsets.all(padding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    // 书名缺失时给一个可见信号（本项目既有行为；anx 会画空串）。
                    title.isEmpty ? '?' : title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: titleFontSize,
                      fontWeight: FontWeight.bold,
                      color: ink,
                      height: 1.2,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: authorFontSize,
                      fontWeight: FontWeight.w300,
                      color: ink,
                    ),
                  ),
                ],
              ),
            ),
            // 水印：右下角、旋转 15°、文字色 10% 透明；故意负偏移让它探出封面
            // （由外层 `ClipRRect` 裁成「压在角上的半本书」——anx 的原始观感）。
            Positioned(
              right: -padding * 0.8,
              bottom: -padding * 0.5,
              child: Transform.rotate(
                angle: 15 * math.pi / 180,
                child: Icon(
                  Icons.book,
                  size: iconSize,
                  color: ink.withValues(alpha: 0.1),
                ),
              ),
            ),
          ],
        );
      },
    );

    // 底色画在**子树内**（`ColoredBox`，不用 `Ink`）：理由见文件头注第 ③ 条
    // ——`Ink` 会被外层 `ClipRRect` 漏裁（方角）且被外框投影填充染色（变暗）。
    // 不依赖 `Material` 祖先，故书架书卡与详情页都可直接用。
    return ClipPath(
      // Squircle 裁形（与书卡外框 `kBookCoverRadius` 同半径同画法，
      // 缩略图异步到位前后不跳变；水印故意探出封面的部分由此兜住）。
      clipper: MiSquircleClipper(radius),
      child: ColoredBox(color: background, child: content),
    );
  }
}
