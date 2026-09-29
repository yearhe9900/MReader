// 无封面书籍的**默认封面**（`META-07` ② 的「默认占位图」，2026-09-29 拍板
// 「采用 anx 无封面书籍的默认封面」）。
//
// 视觉照抄 anx-reader 的默认封面（`widgets/bookshelf/book_cover.dart:45-123`，
// 即「封面文件不存在」那条 else 分支）：
//   · 底色 = `Colors.primaries[书名.hashCode % Colors.primaries.length].shade200`
//     （anx `:57-59`）——每本书按书名哈希拿一张**浅色**卡片（浅粉/浅青/浅黄…）；
//   · 文字色按底色亮度**自适应黑/白**（anx `:23-26` 的 `estimateBrightnessForColor`）；
//   · 顶部书名（最多 3 行，`:78-88`）+ 底部作者（`:92-100`），中间 `Spacer`；
//   · 右下角一颗**旋转 15°** 的书本水印（`:106-117`），色 = 文字色 10% 透明；
//   · 四个尺寸**全部与封面宽度成比例**（anx 用 `LayoutBuilder` 取
//     `constraints.maxWidth`，`:48-49`）：标题 = 宽 ×0.12、作者 = 宽 ×0.08、
//     水印 = 宽 ×0.8、内边距 = 宽 ×0.08 —— 故同一本书在书架（≈120 宽）与详情页
//     （120 宽）里大小一致，换列数也不会跳。
//
// 未采纳（anx 有、本项目不做；口径同上一批「封面投影/圆角」）：
//   · 封面的 `ClipRSuperellipse` 超椭圆裁剪 + `RoundedSuperellipseBorder` 描边；
//   · anx 的两个显示开关 `Prefs().showBookTitleOnDefaultCover` /
//     `…showAuthorOnDefaultCover`（`:62-63`）——本项目没有这两个设置项，恒显示。
//     **不采纳开关 ≠ 改变默认观感**：两者默认值都是 `true`
//     （`config/shared_preference_provider.dart:1133` / `:1142` 的 `?? true`），
//     所以「恒显示」= anx 未改设置时的默认表现（已核源码，2026-09-29）。
//
// 三处刻意的本工程处理：
//   · **10% 透明的水印不是「半透明内容层」**：它叠在**不透明**底色之上，`UI-04`
//     约束的是容器 / 背景，不是前景笔画，故红线不破（同 `shelfGradientBackground`
//     用 `alphaBlend` 合规的理由）。
//   · **自带裁切**：anx 的水印故意画出封面之外（`right: -padding*0.8`、
//     `bottom: -padding*0.5`），本组件用 `ClipRRect` 兜住，调用方不必再管；
//     圆角由 [radius] 传入（书架 = `kBookCoverRadius`，详情页沿用其自有值）。
//   · **底色画在子树内（`ColoredBox`），不用 `Ink`**：`Ink` 是**墨迹特性**，
//     由更上层的 `Material` 绘制，于是有两条像素级实证的坑（2026-09-29 修）：
//     ① 它**逃逸本组件的 `ClipRRect`**（裁切只作用于该 Material 的子**树**）⇒ 封面
//        是**方角**；② 它位于外层 `DecoratedBox` 的**投影填充之下**（`BoxShadow` 是
//        填充整个盒子的形状，`box_decoration.dart:448-470`）⇒ 整张封面被投影染上
//        一层 α0.39 的色（浅色 = 灰、深色 = 黑）⇒「太暗了」。
//     代价（如实登记）：`InkWell` 的水波纹/高亮画在墨迹层，因而**不再压在封面之上**，
//     只在透明的信息区可见——这正是 anx 的形态（其封面用 `Container(color:)` /
//     `Container(decoration: image)`，同样不在墨迹层）。
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 某本书的默认封面底色（anx `book_cover.dart:57-59`）。
///
/// ⚠️ 用 `String.hashCode`：Dart 的 `%` 是欧几里得取模，负数结果也非负，故无需
/// `abs()`（anx 同此写法）。**代价**：`String.hashCode` 只保证同一 SDK 版本内稳定，
/// 换 SDK 版本可能让同一本书换色（纯观感、无功能影响）。若哪天要求「跨版本稳定」，
/// 换成项目已有的确定性 FNV-1a（`lib/meta/synth_cover.dart` 的
/// `synthCoverCacheKey`）即可，一行。
Color defaultBookCoverColor(String title) =>
    Colors.primaries[title.hashCode % Colors.primaries.length].shade200;

/// 叠在 [defaultBookCoverColor] 之上的文字 / 水印色（anx `book_cover.dart:23-26`）。
///
/// 口径与 anx 一致：按底色亮度自适应，浅底给黑字、深底给白字。
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

  /// 圆角（本组件负责裁切）。缺省 8 = 书架封面的 `kBookCoverRadius`。
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: ColoredBox(color: background, child: content),
    );
  }
}
