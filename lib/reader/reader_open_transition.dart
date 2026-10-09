// 开书转场：书架 → 阅读页的**整页「纸张滑入」**（2026-10-09 重做，据负责人给的参考动效）。
//
// ## 形态（对参考动效逐帧量化，见 docs/tech-usage.md §2.77）
//
// | 项 | 实测（参考动效 444×960 @24fps，共 105 帧） |
// |---|---|---|
// | 形态 | 阅读页作为**一整张纸从右侧平移**到左，铺满屏幕 |
// | 时长 | 11 帧 ≈ **460ms** |
// | 曲线 | **easeOutCubic**（半程已走 87.5%，后段只剩收尾） |
// | 圆角 | 全程恒定 **70px**（占屏宽 15.8%），**平移到位的那一帧**才收到 0 |
// | 高度 | 满高（纸顶 == 屏幕顶，盖住状态栏） |
// | 背景 | 书架**静止不动**（同位置像素零位移），被黑色遮罩按滑入进度压暗，终值 **54%** |
// | 纸上 | 直接是阅读页本体（正文就绪前显示它自己的加载态） |
//
// ## 为什么整体替换旧版
//
// 旧版（2026-10-06「封面卡居中 200×282 + 呼吸浮动 + 三层错峰淡出」）与新版**形态互斥**：
// 旧版要「遮罩盖住阅读页、封面卡当主角」，新版要「阅读页自己滑进来」——两者不能叠加。
// §2.69 那一版的动因（点书到正文上屏 335~509ms 的等待无法消除、只能藏起来）在新版里
// 由**滑入动作本身**承担：460ms 的滑入窗口与加载窗口基本等长。
//
// ## 旧的 `ReaderOpenTransition` 静态门闸已整体删除
//
// 旧版靠门闸等「阅读页首帧就绪 → 撤遮罩」，因为撤早了会在淡出过程里露出空白。
// 新版**没有遮罩要撤**：纸上就是阅读页本体，正文没就绪时用户看到的就是阅读页自己的
// 加载态，就绪即无缝变正文。等待是诚实的，不需要一个「何时撤」的信号——故门闸、
// 它的一次性语义与异常兜底路径全部删除，`ReaderPage` 侧的上报点一并删除。
//
// ## 与既有链路的关系
//
// · 路由仍是 [Navigator.push] + [PageRoute]，返回手势 / 预测性返回行为**完全不变**；
// · 阅读页内部逻辑**零改动**，本转场只在**上层**加位移与遮罩；
// · 转场期间下层路由（书架）依赖 `ModalRoute.opaque == false` 继续绘制——这正是
//   「书架静止可见、只被压暗」的实现基础（`ModalRoute` 在 forward / reverse 时把
//   overlay entry 的 `opaque` 置 false，动画 completed 后才恢复）。

import 'package:flutter/material.dart';

/// 纸张滑入时长：对齐参考动效的 11 帧 ≈ 460ms。
const Duration kReaderOpenDuration = Duration(milliseconds: 460);

/// 返回（纸张右移滑出）时长：比进入略快，收得干脆。
const Duration kReaderOpenReverseDuration = Duration(milliseconds: 320);

/// 纸张圆角半径：参考动效实测 70px（屏宽 444px 的 15.8%）。
const double kReaderPaperRadius = 70;

/// 背景书架被压暗的**终值** alpha：参考动效实测 0.54（白光 247 → 118）。
const double kReaderOpenScrimAlpha = 0.54;

/// 圆角收回的起点进度。
///
/// 参考动效里圆角是**一直保持 70px 直到平移到位**的：第 65 帧纸张左缘已贴屏幕左边
/// （x=2）而圆角仍是 72px，第 66 帧突变为 0。所以**不能**用「圆角随进度线性收」——
/// 那会让滑入中段的左上角圆弧一路变小，与参考动效不符。这里把收回压缩在进度最后
/// 1% 之内，观感即「落位瞬间收角」。
const double _kRadiusSettleFrom = 0.99;

/// 开书转场路由：阅读页作为一整张纸从右侧滑入铺满，书架静止在后被压暗。
class ReaderOpenRoute extends PageRoute<void> {
  /// 创建开书转场。
  ReaderOpenRoute({required this.builder});

  /// 阅读页构造器。
  final WidgetBuilder builder;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => kReaderOpenDuration;

  @override
  Duration get reverseTransitionDuration => kReaderOpenReverseDuration;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return builder(context);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 进入：阅读页**自己**平移进来，不再另加平台转场（两层动效会打架）。
    return _PaperSlideTransition(animation: animation, child: child);
  }
}

/// 转场本体：底层一块压在书架上的暗化层 + 上层一张从右平移进来的圆角纸。
class _PaperSlideTransition extends StatelessWidget {
  const _PaperSlideTransition({required this.animation, required this.child});

  /// 路由转场进度 0→1（0 = 纸张完全在屏幕右侧之外）。
  final Animation<double> animation;

  /// 阅读页本体（即那张「纸」）。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (BuildContext context, Widget? paper) {
        // 参考动效的位移曲线是 easeOutCubic：半程已走 87.5%。
        final double p = Curves.easeOutCubic.transform(animation.value);
        final double width = MediaQuery.sizeOf(context).width;
        // 圆角：全程 70，仅在落位的一瞬间收回（见 [_kRadiusSettleFrom]）。
        final double settle =
            ((p - _kRadiusSettleFrom) / (1 - _kRadiusSettleFrom)).clamp(0.0, 1.0);
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 背景：书架**不动**，只被压暗（alpha 随滑入进度线性增长到 54%）。
            //
            // 这里能盖住书架，靠的是 `buildTransitions` 的产物位于本路由的 overlay
            // entry（在下层路由之上）；而「能看到书架」靠的是转场期间 `ModalRoute`
            // 把本 entry 的 `opaque` 置为 false。
            ColoredBox(
              color: Colors.black.withValues(alpha: kReaderOpenScrimAlpha * p),
            ),
            // 纸张：整页平移 + 圆角。`Transform` 只影响绘制与命中测试，不触发布局。
            // `Stack` 默认 `Clip.hardEdge` ⇒ 纸张还停在屏幕右侧之外时天然不可见。
            Transform.translate(
              offset: Offset(width * (1 - p), 0),
              child: ClipRRect(
                borderRadius:
                    BorderRadius.circular(kReaderPaperRadius * (1 - settle)),
                child: paper,
              ),
            ),
          ],
        );
      },
    );
  }
}
