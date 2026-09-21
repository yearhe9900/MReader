// 阅读页：把章节按顺序纵向铺开，滚动到附近才解析该章正文。
//
// 本页**只依赖 [BookSource] 抽象**（`RD-01`）：EPUB / TXT / 将来的其它格式都走同一套
// 接口——章节结构来自 `chapters()`，正文来自 `content(i)`，两者都是异步的。
import 'dart:async';

import 'package:flutter/material.dart';

import '../format/book_source.dart';
import 'reader_settings_bar.dart';

/// 纵向滚动连续阅读页。
///
/// 关键点：
/// - 用 [ListView.builder] 承载章节，Flutter 只会构建视口附近的项；
/// - `content(i)` 的 [Future] 按 index **去重缓存**（见 [_contentFutureAt]）：滚动重排时
///   复用同一个 Future，不会重复解析，也不会让 [FutureBuilder] 反复重回 waiting；
/// - 字号 / 行距只改 [ReaderSettings]，`setState` 后立即重排。
class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.source});

  /// 书籍内容来源（`BookSource` 抽象，EPUB / TXT 通用）。
  ///
  /// 生命周期：**由本页持有**，在 [State.dispose] 时释放（关闭阅读页即释放书籍资源）。
  final BookSource source;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  ReaderSettings _settings = const ReaderSettings();

  BookMeta? _meta;
  List<Chapter>? _chapters;
  Object? _error;

  /// 章正文 Future 缓存：index -> Future（**同一 Future 复用**，天然去重）。
  final Map<int, Future<ChapterContent>> _contentFutures =
      <int, Future<ChapterContent>>{};

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    // 关闭阅读页即释放书籍资源（解析中间态 / 缓存不再需要）。
    unawaited(widget.source.dispose());
    super.dispose();
  }

  /// 异步取元数据 + 章节表（`load()` / `chapters()`）；失败就地降级为错误态。
  Future<void> _open() async {
    try {
      final BookMeta meta = await widget.source.load();
      final List<Chapter> chapters = await widget.source.chapters();
      if (!mounted) return;
      setState(() {
        _meta = meta;
        _chapters = chapters;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  /// 取（或惰性构造）第 [index] 章正文的 [Future]。
  ///
  /// 同一 index 永远返回**同一个 Future**：`ListView.builder` 的 itemBuilder 可能在滚动 /
  /// `setState` 时被反复调用，若每次新建 Future 会重复解析并让 [FutureBuilder] 反复重回
  /// waiting。单章失败就地降级为一行提示，不拖垮整本书。
  Future<ChapterContent> _contentFutureAt(int index) {
    return _contentFutures.putIfAbsent(index, () async {
      try {
        return await widget.source.content(index);
      } catch (error) {
        return ChapterContent.paragraphs(<String>['[本章解析失败] $error']);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle bodyStyle = TextStyle(
      fontSize: _settings.fontSize,
      height: _settings.lineHeight,
    );

    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            Text(
              _subtitle,
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
      body: _buildBody(theme, bodyStyle),
    );
  }

  /// 标题栏主标题：元数据标题，取不到时给一个中性占位。
  String get _title {
    final BookMeta? meta = _meta;
    if (meta != null && meta.title.isNotEmpty) return meta.title;
    return '阅读';
  }

  /// 标题栏副标题：作者（若有）+ 诊断信息。
  ///
  /// 诊断信息做成「`N 章 · <implId>`」——**与格式无关**：一眼看出解析层给了几章、
  /// 走的是哪个实现（`dart-epub` / `dart-txt`），EPUB / TXT 通用。
  String get _subtitle {
    final List<Chapter>? chapters = _chapters;
    final String debug =
        chapters == null ? '载入中…' : '${chapters.length} 章 · ${widget.source.implId}';
    final BookMeta? meta = _meta;
    final String author = meta?.author ?? '';
    return author.isNotEmpty ? '$author · $debug' : debug;
  }

  Widget _buildBody(ThemeData theme, TextStyle bodyStyle) {
    final Object? error = _error;
    if (error != null) {
      // 打开 / 解析失败：给出可读提示（格式错误的 `message` 已中文化）。
      final String message = error is MReaderFormatException
          ? error.message
          : '打开失败：$error';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      );
    }

    final List<Chapter>? chapters = _chapters;
    if (chapters == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final int total = chapters.length;
    if (total == 0) {
      // 解析成功但没有任何章节：必须显式告知，否则就是一片空白，
      // 既看不出是「解析失败」还是「渲染失败」，也没法定位。
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '这本书没有解析出任何可阅读的章节。\n\n'
            '可能原因：源文件没有可识别的章节结构，'
            '或内容为空 / 全部为非文本资源。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: total,
      itemBuilder: (BuildContext context, int index) {
        final Chapter chapter = chapters[index];
        final String heading =
            chapter.title.isNotEmpty ? chapter.title : '第 ${index + 1} 节';

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
              FutureBuilder<ChapterContent>(
                future: _contentFutureAt(index),
                builder: (
                  BuildContext context,
                  AsyncSnapshot<ChapterContent> snapshot,
                ) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return Text('载入中…', style: bodyStyle);
                  }
                  final List<String> paragraphs =
                      snapshot.data?.paragraphList ?? const <String>[];
                  return Text(
                    paragraphs.isEmpty
                        ? '（本章无可显示的文本内容）'
                        : paragraphs.join('\n\n'),
                    style: bodyStyle,
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
