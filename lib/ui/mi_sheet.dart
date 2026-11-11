// mi_like_ui 底部弹窗（[MiBottomSheet]）的宿主侧入口：阅读页「目录 / 设置 /
// 更多」的弹出式容器（`RD-04` 收纳后的低频入口形态）。
//
// 为什么不直接用组件：[MiBottomSheet] 是**声明式**弹层（`show` 由宿主持有，
// 收起动画收口后回调 `onDismissed`），而本项目的弹层入口都是**命令式**
// （点一下弹出、点选项执行）。这里用一层透明路由把它接进 Navigator 体系：
// 弹层本体与滑入 / 滑出动画全归组件，路由只做两件事——让弹层盖满全屏
// （`opaque: false`），以及把「收起」翻译成「动画收口后摘除本路由」。
//
// 选中选项后的后续动作由**内容件自己**在 `close()` 之后立刻发起（不等收口）：
// 收口是弹簧滑出（~0.4s），等它播完再跳章 / 推面板等于白滞后一拍。为此
// [showMiSheet] 不返回结果（也不需要）——结果会随「路由被摘除」丢在半路。
//
// 与 glass_kit 弹层的分工：阅读页三格菜单 / 书签 / 搜索 / AI 面板等已全部
// 换本入口（mi_like 弹出式抽屉）；glass_kit 的 showSheet/showAlert 仅剩
// 契约测试直接调用（API 保留，页面零调用）。
import 'package:flutter/material.dart';

import 'mi_like_ui/mi_like_ui.dart';

/// 弹层内容构造器：[close] 收起弹层（播滑出动画后摘除路由）。
typedef MiSheetContentBuilder = Widget Function(
  BuildContext context,
  VoidCallback close,
);

/// 弹出 mi_like 底部抽屉（[MiBottomSheet]）。
///
/// · [title]：抽屉标题行（目录 / 设置 / 更多）；
/// · [maxHeightFactor]：内容最大高度占屏比（内容自撑列表时必须给——否则
///   抽屉会顶到可用高度上限，一条通天抽屉）；
/// · [scrollable]：内容为静态纵列（自撑 `Column`）时给 true——超出上限
///   由外层滚动兜底；内容自带滚动体（`ListView`）必须 false（滚动嵌套）。
void showMiSheet({
  required BuildContext context,
  required MiSheetContentBuilder builder,
  String? title,
  double? maxHeightFactor,
  bool scrollable = false,
}) {
  Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      // 弹层自绘遮罩（含点按收起），路由层不再铺 barrier。
      barrierColor: null,
      // 转场全在组件内（弹簧滑入 / 滑出），路由转场置零防双层动画。
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (BuildContext routeContext, _, _) => _MiSheetRoute(
        builder: builder,
        title: title,
        maxHeightFactor: maxHeightFactor,
        scrollable: scrollable,
      ),
    ),
  );
}

class _MiSheetRoute extends StatefulWidget {
  const _MiSheetRoute({
    required this.builder,
    this.title,
    this.maxHeightFactor,
    this.scrollable = false,
  });

  final MiSheetContentBuilder builder;
  final String? title;
  final double? maxHeightFactor;
  final bool scrollable;

  @override
  State<_MiSheetRoute> createState() => _MiSheetRouteState();
}

class _MiSheetRouteState extends State<_MiSheetRoute> {
  bool _show = true;
  bool _closing = false;

  /// 收起弹层：只翻 [MiBottomSheet.show]，动画收口由组件回调 `_removeRoute`。
  void _close() {
    if (_closing) return;
    _closing = true;
    setState(() => _show = false);
  }

  /// 收口后**按路由自身**摘除。⚠️ 不能用 `Navigator.pop`：选中项可能已经
  /// 把新路由（摘要 / 朗读设置）压在上面，pop 弹掉的是它而不是本抽屉。
  void _removeRoute() {
    if (!mounted) return;
    final ModalRoute<void>? route = ModalRoute.of<void>(context);
    final NavigatorState navigator = Navigator.of(context);
    if (route == null) {
      navigator.pop();
      return;
    }
    navigator.removeRoute(route);
  }

  @override
  Widget build(BuildContext context) {
    Widget content = widget.builder(context, _close);
    if (widget.maxHeightFactor != null) {
      content = ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight:
              MediaQuery.sizeOf(context).height * widget.maxHeightFactor!,
        ),
        child: content,
      );
    }
    if (widget.scrollable) {
      content = SingleChildScrollView(child: content);
    }
    // 硬件返回不走路由默认 pop（会瞬移抽屉），改走同一条收起动画。
    // 路由层在 [Scaffold] 之上：内容件（ListTile / ChoiceChip / Slider 等）
    // 都要求最近的 Material 祖先。
    //
    // 路由**自挂 [MiPopupHost]**（上游 `demo_app.dart` onGenerateRoute 同款，
    // 弹层包在路由内容里）：抽屉体注册到本宿主而非应用根宿主 —— 否则体画在
    // Navigator 之上，面板开着时 push 的页面（朗读设置 → 在线引擎配置）会被
    // 抽屉盖住；面板内投放的 snackbar 也随本路由定界（被上层路由盖住，
    // 与 Material Scaffold 同语义）。就近优先：本宿主压过应用根那层。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, void _) {
        if (!didPop) _close();
      },
      child: MiPopupHost(
        child: MiBottomSheet(
          show: _show,
          title: widget.title,
          onDismissRequest: _close,
          onDismissed: _removeRoute,
          // 墨水基座垫在**内容**侧（抽屉表面 DecoratedBox 之内）：ListTile 等
          // 把背景 / 墨溅画在最近 Material 上，垫在外面会被表面挡色并触发
          // 「ink may be invisible」断言；透明 Material 只补基座不叠底色。
          child: Material(type: MaterialType.transparency, child: content),
        ),
      ),
    );
  }
}
