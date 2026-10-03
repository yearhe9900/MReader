// 划词选区设施（M3-T02：`AI-02` 翻译 / `AI-03` 释义的选区底座）。
//
// **同时是 `TTS-02` 朗读高亮跟随的前置**（任务书明确要求按可复用写）：
// 段落 key 定位（[paragraphKey] / [findParagraphAt]）与选区值对象
// （[ParaSelection]，渲染文本空间 UTF-16 偏移）对 TTS 高亮同样适用。
//
// 为什么自建而不用 `SelectionArea`：分页模式同一段落在相邻页**两处实例化**
// （ClipRect 各自裁切），原生选区无法跨实例；选区高亮走 `InlineParagraph`
// 的 span 内着色（随页 Transform 动画天然同步），本文件只负责「命中 → 值」。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 段落 key 前缀（`para\u0001`）。`ValueKey<String>` 值形如
/// `para\u0001{paraIndex}\u0001{chapterHref}`——paraIndex 在前（href 可含冒号 /
/// 斜杠，split 后取第 2 段，不会歧义）。
const String kParagraphKeyPrefix = 'para\u0001';

/// 段落定位 key：挂到 [InlineParagraph] 上，供 [findParagraphAt] 命中。
///
/// 跨页同段的两处实例同 key 不同父，不冲突（key 只需在兄弟间唯一）。
ValueKey<String> paragraphKey(String chapterHref, int paraIndex) =>
    ValueKey<String>('$kParagraphKeyPrefix$paraIndex\u0001$chapterHref');

/// 解析段落 key；非段落 key 返回 null。
({int paraIndex, String href})? parseParagraphKey(Key? key) {
  if (key is! ValueKey<String>) return null;
  final String value = key.value;
  if (!value.startsWith(kParagraphKeyPrefix)) return null;
  final List<String> parts = value.split('\u0001');
  if (parts.length != 3) return null;
  final int? paraIndex = int.tryParse(parts[1]);
  if (paraIndex == null) return null;
  return (paraIndex: paraIndex, href: parts[2]);
}

/// 一次划词选区（值对象，渲染文本空间——含首行缩进 2 字符的偏移口径）。
///
/// [start]/[end] 是 `RenderParagraph` 文本空间的 UTF-16 偏移，直接喂给
/// [InlineParagraph.selection] 着色；[text] 是剔除首尾空白后的选文快照，
/// 供面板展示 / 发给 AI / 存生词本。
class ParaSelection {
  const ParaSelection({
    required this.chapterHref,
    required this.paraIndex,
    required this.start,
    required this.end,
    required this.text,
  });

  /// 所在章 href（选区身份——`PagedChapterView` 只有 href，无 chapterIndex）。
  final String chapterHref;

  /// 章内段落下标。
  final int paraIndex;

  /// 起始偏移（渲染文本空间，含）。
  final int start;

  /// 结束偏移（渲染文本空间，不含）。
  final int end;

  /// 选中文本快照（trim 后；发 AI / 存生词本用）。
  final String text;

  bool get isEmpty => end <= start || text.isEmpty;
}

/// 一次段落命中（[findParagraphAt] 的返回）。
class ParagraphHit {
  const ParagraphHit({
    required this.render,
    required this.href,
    required this.paraIndex,
  });

  /// 命中的段落渲染对象（词边界 / 选区盒 / 坐标换算都在它上面做）。
  final RenderParagraph render;

  /// 段落所在章 href。
  final String href;

  /// 章内段落下标。
  final int paraIndex;
}

/// 从 [root] 子树里找「全局坐标 [globalPosition] 落在其绘制范围内」的段落。
///
/// 语义：递归优先深度优先，遇到带段落 key 且几何包含命中的元素即返回。
/// 分页模式同段双实例的两份几何对齐（渲染契约保证），命中任一份算出的
/// TextPosition 相同，故「第一个命中」即正确答案。
///
/// 找不到（点在标题 / 图片 / 空白上）返回 null——由调用方清选区。
ParagraphHit? findParagraphAt(BuildContext root, Offset globalPosition) {
  if (root is! Element) return null;
  return _searchParagraph(root, globalPosition);
}

ParagraphHit? _searchParagraph(Element element, Offset global) {
  final ({int paraIndex, String href})? parsed =
      parseParagraphKey(element.widget.key);
  if (parsed != null) {
    final RenderObject? render = element.renderObject;
    if (render is RenderParagraph) {
      final Rect rect = render.localToGlobal(Offset.zero) & render.size;
      if (rect.contains(global)) {
        return ParagraphHit(
          render: render,
          href: parsed.href,
          paraIndex: parsed.paraIndex,
        );
      }
    }
  }
  ParagraphHit? hit;
  element.visitChildren((Element child) {
    if (hit != null) return;
    hit = _searchParagraph(child, global);
  });
  return hit;
}

/// 从 [root] 子树里按段落 key 精确找渲染盒（`TTS-02` 可视性判定用）。
///
/// 与 [findParagraphAt] 同款 DFS，但按 key 匹配而非几何命中——「段落 X 现在
/// 渲染在哪」是跟随滚动要回答的问题（几何探测需要先知道点在哪，拿不到）。
/// 未构建（懒构建列表滚出窗外）→ null（调用方按不可见处理）；`Offstage`
/// 下仍照常 layout（RenderOffstage 只不绘制），翻页态照样可测。
/// 分页同段双实例取**先命中**的一份——两份几何对齐（渲染契约），任一份
/// 都能给出正确的可见性结论。
RenderBox? findParagraphBox(
  BuildContext root,
  String chapterHref,
  int paraIndex,
) {
  if (root is! Element) return null;
  return _searchBox(root, paragraphKey(chapterHref, paraIndex));
}

RenderBox? _searchBox(Element element, ValueKey<String> target) {
  if (element.widget.key == target) {
    final RenderObject? render = element.renderObject;
    if (render is RenderBox && render.hasSize) return render;
    return null;
  }
  RenderBox? found;
  element.visitChildren((Element child) {
    if (found != null) return;
    found = _searchBox(child, target);
  });
  return found;
}

/// 词边界归一（纯函数，可单测）：把 `getWordBoundary` 的结果修整成
/// 「不含首尾空白、ASCII 词整体、CJK 至少一个字」的可用选区。
///
/// 输入可能来自引擎词边界（空 range / 全空白 / 带两侧空格）；[tappedOffset]
/// 是点按处偏移——range 无效时从它右先左后找最近非空白字符兜底。
/// 全文皆空白返回 `(0, 0)`（空选区）。
({int start, int end}) normalizeWordRange(
  String text,
  int start,
  int end,
  int tappedOffset,
) {
  int s = start.clamp(0, text.length);
  int e = end.clamp(0, text.length);
  if (s > e) {
    final int t = s;
    s = e;
    e = t;
  }
  bool isWs(int i) => text[i].trim().isEmpty;
  while (s < e && isWs(s)) {
    s++;
  }
  while (e > s && isWs(e - 1)) {
    e--;
  }
  if (s >= e) {
    // 空 / 纯空白 range：从点按位右先左后找最近非空白字符。
    final int t = tappedOffset.clamp(0, text.length);
    int found = -1;
    for (int i = t; i < text.length; i++) {
      if (!isWs(i)) {
        found = i;
        break;
      }
    }
    if (found < 0) {
      for (int i = t - 1; i >= 0; i--) {
        if (!isWs(i)) {
          found = i;
          break;
        }
      }
    }
    if (found < 0) return (start: 0, end: 0);
    s = found;
    e = found + 1;
  }
  // ASCII 词双向扩展（点在词中间时拿到整词）；非 ASCII（CJK 等）保持原范围。
  bool isAsciiWord(int i) {
    final int c = text.codeUnitAt(i);
    return (c >= 0x30 && c <= 0x39) || // 0-9
        (c >= 0x41 && c <= 0x5A) || // A-Z
        (c >= 0x61 && c <= 0x7A) || // a-z
        c == 0x5F; // _
  }
  if (s < text.length && isAsciiWord(s)) {
    while (s > 0 && isAsciiWord(s - 1)) {
      s--;
    }
  }
  if (e > 0 && isAsciiWord(e - 1)) {
    while (e < text.length && isAsciiWord(e)) {
      e++;
    }
  }
  return (start: s, end: e);
}

/// 段落原文 → 纯文本（发 AI / 上下文用）：吞掉 NUL 标记（IMG/A/ID）与
/// `<b>`/`<i>` 白名单标签，只留可见文字。
String plainParagraphText(String raw) {
  if (!raw.contains('\x00')) return _stripInlineTags(raw);
  final List<String> parts = raw.split('\x00');
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < parts.length; i++) {
    if (i.isEven) out.write(parts[i]); // 偶数段 = 可见文本
  }
  return _stripInlineTags(out.toString());
}

String _stripInlineTags(String text) =>
    text.replaceAll(RegExp(r'</?[bi]>'), '');

/// 划词操作条（长按选区后浮在选区上方/下方）。
///
/// 形制：不透明圆角 Material（`UI-04` 正文区不透明——浮层瞬态控件同口径，
/// 不用玻璃）。动作 = 翻译 / 释义 / 关闭（清选区）。
class SelectionActionBar extends StatelessWidget {
  const SelectionActionBar({
    super.key,
    required this.onTranslate,
    required this.onExplain,
    required this.onClear,
  });

  /// 打开翻译面板。
  final VoidCallback onTranslate;

  /// 打开释义面板。
  final VoidCallback onExplain;

  /// 清除选区。
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      elevation: 4,
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextButton(
            onPressed: onTranslate,
            child: const Text('翻译'),
          ),
          TextButton(
            onPressed: onExplain,
            child: const Text('释义'),
          ),
          SizedBox(
            width: 36,
            height: 36,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 18,
              tooltip: '取消选择',
              icon: const Icon(Icons.close),
              onPressed: onClear,
            ),
          ),
        ],
      ),
    );
  }
}
