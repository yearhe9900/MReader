// 阅读页：把 spine 章节按顺序纵向铺开，滚到附近才解析该章正文。
import 'package:flutter/material.dart';

import '../epub/section_extractor.dart';
import '../model/epub_book.dart';
import 'reader_settings_bar.dart';

/// 纵向滚动连续阅读页。
///
/// 关键点：
/// - 用 [ListView.builder] 承载章节，Flutter 只会构建视口附近的项；
/// - 章节正文在 [_sectionAt] 里**首次可见时才解析**，并缓存，滚动时不再重复解析；
/// - 字号 / 行距只改 [ReaderSettings]，`setState` 后立即重排。
class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.book});

  final EpubBook book;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  ReaderSettings _settings = const ReaderSettings();

  /// 章节正文缓存：index -> 解析结果。
  final Map<int, ExtractedSection> _cache = <int, ExtractedSection>{};

  ExtractedSection _sectionAt(int index) {
    final ExtractedSection? cached = _cache[index];
    if (cached != null) return cached;

    ExtractedSection extracted;
    try {
      extracted = extractSection(widget.book.sections[index].rawBytes);
    } catch (error) {
      // 单章解析失败不能拖垮整本书，就地降级为一行提示。
      extracted = ExtractedSection(paragraphs: <String>['[本章解析失败] $error']);
    }
    _cache[index] = extracted;
    return extracted;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle bodyStyle = TextStyle(
      fontSize: _settings.fontSize,
      height: _settings.lineHeight,
    );
    final int total = widget.book.sections.length;
    final String subtitle = widget.book.subtitle;

    // 诊断信息：把书名栏做成「标题 + 章节数 + 首章字节数」，一眼就能看出
    // 是解析层没给出章节，还是渲染层没画出文字。
    final String firstBytes = total > 0
        ? '首章 ${widget.book.sections.first.rawBytes.length} 字节'
        : '无章节';
    final String debugInfo = '$total 章 · $firstBytes';

    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              widget.book.displayTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            Text(
              subtitle.isNotEmpty ? '$subtitle · $debugInfo' : debugInfo,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
      bottomNavigationBar: ReaderSettingsBar(
        settings: _settings,
        onChanged: (ReaderSettings value) {
          setState(() => _settings = value);
        },
      ),
      body: total == 0
          // 解析成功但 spine 里没有任何文本章节：必须显式告知，否则就是一片空白，
          // 既看不出是「解析失败」还是「渲染失败」，也没法定位。
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '这本书没有解析出任何可阅读的章节。\n\n'
                  '可能原因：spine 全部指向图片/字体等非文本资源，'
                  '或 OPF 的 manifest/spine 结构与解析器预期不符。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            )
          : ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: total,
        itemBuilder: (BuildContext context, int index) {
          final ExtractedSection section = _sectionAt(index);
          final String heading = section.title.isNotEmpty
              ? section.title
              : '第 ${index + 1} 节';

          return Padding(
            padding: const EdgeInsets.only(bottom: 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  heading,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                const Divider(height: 1),
                const SizedBox(height: 12),
                Text(
                  section.paragraphs.isEmpty
                      ? '（本章无可显示的文本内容）'
                      : section.paragraphs.join('\n\n'),
                  style: bodyStyle,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
