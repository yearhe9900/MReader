// `CNT-04c`：超链接跳转与返回的**纯逻辑**（不依赖 widget 树），供 `ReaderPage` 接线。
//
// 设计：
//   · [splitLinkHref] 把 href 拆成「文件路径 + fragment」——章内 `#id` / 跨文件
//     `path` / 跨文件带锚点 `path#id` 三种形态统一处理；
//   · [findChapterIndex] 由 href 反查章表——**不能按索引一一对应**（目录项数与
//     spine 项数可以不相等，同 `dart_epub_source._sectionFor` 的先例），
//     匹配键 = 百分号解码 + 小写（容忍 `fx03` 那类大小写不一致的脏书）；
//   · [findParagraphIndex] 扫描段落列表里的锚点标记 `\x00ID:xxx\x00`
//     （`CNT-04a` 抽取层写入），定位章内的锚点段；
//   · [LinkBackStack] 返回原位置：跳链接前压入 `ScrollAnchor.capture` 快照，
//     「返回」按钮弹栈恢复（后进先出）。
//
// 目标不存在一律**静默忽略**（返回 -1 / null，不压栈、不跳转、不抛异常）——验收③。
//
// ⚠️ 本文件不 import Flutter widget 树（只用 `ScrollAnchor` 纯数据类），
// 可直接用纯 Dart `test()` 断言（`test/reader/link_navigator_test.dart`）。
import '../epub/zip_paths.dart';
import '../model/chapter.dart';
import '../typography/anchor.dart';

/// 拆分链接 href 为「文件路径」与「fragment（不含 `#`）」。
///
/// - `#note1` → `(path: '', fragment: 'note1')`（章内锚点）；
/// - `ch2.xhtml#s` → `(path: 'ch2.xhtml', fragment: 's')`（跨文件带锚点）；
/// - `ch2.xhtml` → `(path: 'ch2.xhtml', fragment: '')`（跳目标章开头）。
///
/// 空串 / 无 `#` 时 fragment 恒为空串（不返回 null）。
({String path, String fragment}) splitLinkHref(String href) {
  final int hash = href.indexOf('#');
  if (hash < 0) return (path: href, fragment: '');
  return (path: href.substring(0, hash), fragment: href.substring(hash + 1));
}

/// href 的匹配键：百分号解码 + 转小写（与 `dart_epub_source._sectionFor` 同手法）。
String _matchKey(String href) => decodePercentPath(href).toLowerCase();

/// 由跨文件 [path]（[splitLinkHref] 的 path 部分）反查章索引；找不到返回 `-1`。
///
/// **不能按索引一一对应**：目录项数与 spine 项数可以不相等（目录常合并/拆分章节）。
/// 空 [path]（章内链接）返回 `-1`——「章内」由调用方落到当前章。
///
/// 匹配两级（2026-10-22）：**精确 href 优先**，其次按 `#` 前的**路径段**——
/// 章表里同文件多目录项的条目 href 带 `#<anchor>` 唯一化后缀（Rust 内核源的
/// 细粒度目录），链接目标是文件路径本身时落到该文件的第一个目录项。
int findChapterIndex(List<Chapter> chapters, String path) {
  if (path.isEmpty) return -1;
  final String target = _matchKey(path);
  int byPath = -1;
  for (int i = 0; i < chapters.length; i++) {
    final String key = _matchKey(chapters[i].href);
    if (key == target) return i;
    if (byPath < 0 &&
        _matchKey(splitLinkHref(chapters[i].href).path) == target) {
      byPath = i;
    }
  }
  return byPath;
}

/// 在段落列表里扫锚点标记 `\x00ID:$fragment\x00`（`CNT-04a` 写入），
/// 返回命中段落下标；找不到返回 `-1`。
///
/// 空 [fragment] 返回 `-1`。匹配两段形态：先按原样，未命中再按**百分号解码**形态
/// （容忍 href 里 `#fn%31` 这类编码 fragment 与裸 id 对应）。
int findParagraphIndex(List<String> paragraphs, String fragment) {
  if (fragment.isEmpty) return -1;
  final int exact = _scanIdMarker(paragraphs, fragment);
  if (exact >= 0) return exact;
  final String decoded = decodePercentPath(fragment);
  return decoded == fragment ? -1 : _scanIdMarker(paragraphs, decoded);
}

/// 扫描 `\x00ID:$id\x00` 标记（标记体完整匹配，避免前缀误命中）。
int _scanIdMarker(List<String> paragraphs, String id) {
  final String marker = '\x00ID:$id\x00';
  for (int i = 0; i < paragraphs.length; i++) {
    if (paragraphs[i].contains(marker)) return i;
  }
  return -1;
}

/// 返回原位置的锚点栈（验收②）：跳链接前压入原位置快照，「返回」按钮弹栈恢复。
///
/// 后进先出；栈空时 [pop] 返回 `null`（调用方静默忽略）。
/// 栈非空 ⇔ 显示浮动「返回」按钮。
class LinkBackStack {
  final List<ScrollAnchor> _entries = <ScrollAnchor>[];

  /// 栈内锚点数（`0` = 不显示「返回」按钮）。
  int get length => _entries.length;

  /// 是否为空。
  bool get isEmpty => _entries.isEmpty;

  /// 是否非空。
  bool get isNotEmpty => _entries.isNotEmpty;

  /// 压入一个位置快照（每次确定要跳转时调用一次）。
  void push(ScrollAnchor anchor) => _entries.add(anchor);

  /// 弹出最近压入的快照；栈空返回 `null`。
  ScrollAnchor? pop() => _entries.isEmpty ? null : _entries.removeLast();

  /// 清空（重新打开书籍时调用）。
  void clear() => _entries.clear();
}
