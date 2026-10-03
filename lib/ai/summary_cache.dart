// 摘要缓存（M3-T03：`AI-04` ②「二次进入直接命中缓存」+ `AI-05` 递进续做）。
//
// 形制与其它 store 同款（勿改）：进程内共享实例 + 监听回调，落盘经
// [JsonStore] → [AtomicFile]（`DATA-01` 原子写入）；实例在 `main()` 创建注入
// （目录 = PRD §10.3 `aiCache/`，全量备份按目录整体收）。
//
// 两级缓存（PRD §8.3「按 章 id + 内容 hash + 模型」；schedule:222
// 「缓存键必须能区分生成到第几章」）：
//   · 章级 [ChapterSummaryEntry]：键 = bookId + chapterHref + 内容 hash +
//     模型 + 目标长度——全书摘要的**逐章递进**就靠它续做（已生成的章直接跳过，
//     中断后重跑只补缺的章）；
//   · 合并级 [BookSummaryEntry]：键 = bookId + 模型 + 类型 + 范围起止章 +
//     [inputHash]（范围内各章内容 hash 串接再摘要）——正文或范围一变即失效。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../storage/atomic_file.dart';
import '../storage/json_store.dart';

/// 内容 hash（sha256 前 16 位十六进制；与 `LIB-05` 同口径）。
String summaryContentHash(String text) =>
    sha256.convert(utf8.encode(text)).toString().substring(0, 16);

/// 一条章级摘要（不可变值对象）。
class ChapterSummaryEntry {
  ChapterSummaryEntry({
    required this.bookId,
    required this.chapterHref,
    required this.contentHash,
    required this.model,
    required this.maxChars,
    required this.text,
    required this.updatedAt,
  });

  final String bookId;

  /// 章稳定身份（`Chapter.href`）。
  final String chapterHref;

  /// 章正文内容 hash（[summaryContentHash]）。
  final String contentHash;

  /// 生成用模型名（换模型即失效）。
  final String model;

  /// 目标字数（`AI-04`「可指定长度」：不同长度不同结果，进键）。
  final int maxChars;

  final String text;

  /// 生成时间（Unix 毫秒）。
  final int updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'bookId': bookId,
        'chapterHref': chapterHref,
        'contentHash': contentHash,
        'model': model,
        'maxChars': maxChars,
        'text': text,
        'updatedAt': updatedAt,
      };

  static ChapterSummaryEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? bookId = json['bookId'];
    final Object? chapterHref = json['chapterHref'];
    final Object? contentHash = json['contentHash'];
    final Object? model = json['model'];
    final Object? text = json['text'];
    if (bookId is! String ||
        bookId.isEmpty ||
        chapterHref is! String ||
        chapterHref.isEmpty ||
        contentHash is! String ||
        contentHash.isEmpty ||
        model is! String ||
        model.isEmpty ||
        text is! String ||
        text.isEmpty) {
      return null;
    }
    final Object? updatedAt = json['updatedAt'];
    return ChapterSummaryEntry(
      bookId: bookId,
      chapterHref: chapterHref,
      contentHash: contentHash,
      model: model,
      maxChars: json['maxChars'] is num
          ? (json['maxChars'] as num).toInt()
          : 200,
      text: text,
      updatedAt: updatedAt is num ? updatedAt.toInt() : 0,
    );
  }
}

/// 合并级摘要（全书摘要 / 前情回顾的成品；键含范围起止章）。
class BookSummaryEntry {
  BookSummaryEntry({
    required this.bookId,
    required this.model,
    required this.kind,
    required this.fromChapter,
    required this.uptoChapter,
    required this.inputHash,
    required this.text,
    required this.updatedAt,
  });

  final String bookId;
  final String model;

  /// `book` = 全书摘要；`recap` = 前情回顾。
  final String kind;

  /// 范围起止章（闭区间；全书 = 0..upto，前情回顾 = 近 N 章窗口）。
  final int fromChapter;
  final int uptoChapter;

  /// 范围内各章 [ChapterSummaryEntry.contentHash] 串接后的摘要——任一章正文
  /// 变化 → hash 变 → 缓存失效。
  final String inputHash;

  final String text;
  final int updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'bookId': bookId,
        'model': model,
        'kind': kind,
        'fromChapter': fromChapter,
        'uptoChapter': uptoChapter,
        'inputHash': inputHash,
        'text': text,
        'updatedAt': updatedAt,
      };

  static BookSummaryEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? bookId = json['bookId'];
    final Object? model = json['model'];
    final Object? kind = json['kind'];
    final Object? inputHash = json['inputHash'];
    final Object? text = json['text'];
    if (bookId is! String ||
        bookId.isEmpty ||
        model is! String ||
        model.isEmpty ||
        (kind != 'book' && kind != 'recap') ||
        inputHash is! String ||
        text is! String ||
        text.isEmpty) {
      return null;
    }
    return BookSummaryEntry(
      bookId: bookId,
      model: model,
      kind: kind as String,
      fromChapter: json['fromChapter'] is num
          ? (json['fromChapter'] as num).toInt()
          : 0,
      uptoChapter: json['uptoChapter'] is num
          ? (json['uptoChapter'] as num).toInt()
          : 0,
      inputHash: inputHash,
      text: text,
      updatedAt: json['updatedAt'] is num
          ? (json['updatedAt'] as num).toInt()
          : 0,
    );
  }
}

/// 摘要缓存存储（进程内共享，显式注入）。
class SummaryCache {
  SummaryCache(Directory dir)
      : _store = JsonStore(
          AtomicFile(
            '${dir.path}${Platform.pathSeparator}summary.json',
          ),
        );

  final JsonStore _store;
  List<ChapterSummaryEntry> _chapters = <ChapterSummaryEntry>[];
  List<BookSummaryEntry> _books = <BookSummaryEntry>[];
  bool _loaded = false;
  final List<void Function()> _listeners = <void Function()>[];

  /// 全部章级摘要快照（只读）。
  List<ChapterSummaryEntry> get chapterEntries =>
      List<ChapterSummaryEntry>.unmodifiable(_chapters);

  /// 全部合并级摘要快照（只读）。
  List<BookSummaryEntry> get bookEntries =>
      List<BookSummaryEntry>.unmodifiable(_books);

  /// 是否已完成一次加载。
  bool get isLoaded => _loaded;

  /// 从磁盘加载；文件缺失或损坏回退空表（坏条目逐条跳过）。
  Future<void> load() async {
    final Object? json = await _store.read();
    final List<ChapterSummaryEntry> chapters = <ChapterSummaryEntry>[];
    final List<BookSummaryEntry> books = <BookSummaryEntry>[];
    if (json is Map) {
      final Object? rawChapters = json['chapters'];
      if (rawChapters is List) {
        for (final Object? item in rawChapters) {
          final ChapterSummaryEntry? e = ChapterSummaryEntry.fromJson(item);
          if (e != null) chapters.add(e);
        }
      }
      final Object? rawBooks = json['books'];
      if (rawBooks is List) {
        for (final Object? item in rawBooks) {
          final BookSummaryEntry? e = BookSummaryEntry.fromJson(item);
          if (e != null) books.add(e);
        }
      }
    }
    _chapters = chapters;
    _books = books;
    _loaded = true;
    _notify();
  }

  /// 查章级摘要（键任一不匹配 → miss，含范围/长度/模型差异）。
  ChapterSummaryEntry? findChapter({
    required String bookId,
    required String chapterHref,
    required String contentHash,
    required String model,
    required int maxChars,
  }) {
    for (final ChapterSummaryEntry e in _chapters) {
      if (e.bookId == bookId &&
          e.chapterHref == chapterHref &&
          e.contentHash == contentHash &&
          e.model == model &&
          e.maxChars == maxChars) {
        return e;
      }
    }
    return null;
  }

  /// 写入 / 覆盖一条章级摘要（同键覆盖，语义幂等）。
  Future<void> putChapter(ChapterSummaryEntry entry) {
    final List<ChapterSummaryEntry> next = List<ChapterSummaryEntry>.of(_chapters);
    final int i = next.indexWhere(
      (ChapterSummaryEntry e) =>
          e.bookId == entry.bookId &&
          e.chapterHref == entry.chapterHref &&
          e.contentHash == entry.contentHash &&
          e.model == entry.model &&
          e.maxChars == entry.maxChars,
    );
    if (i >= 0) {
      next[i] = entry;
    } else {
      next.add(entry);
    }
    return _update(next, _books);
  }

  /// 查合并级摘要（键 = bookId + 模型 + 类型 + 起止章 + inputHash）。
  BookSummaryEntry? findBook({
    required String bookId,
    required String model,
    required String kind,
    required int fromChapter,
    required int uptoChapter,
    required String inputHash,
  }) {
    for (final BookSummaryEntry e in _books) {
      if (e.bookId == bookId &&
          e.model == model &&
          e.kind == kind &&
          e.fromChapter == fromChapter &&
          e.uptoChapter == uptoChapter &&
          e.inputHash == inputHash) {
        return e;
      }
    }
    return null;
  }

  /// 写入 / 覆盖一条合并级摘要（同键覆盖）。
  Future<void> putBook(BookSummaryEntry entry) {
    final List<BookSummaryEntry> next = List<BookSummaryEntry>.of(_books);
    final int i = next.indexWhere(
      (BookSummaryEntry e) =>
          e.bookId == entry.bookId &&
          e.model == entry.model &&
          e.kind == entry.kind &&
          e.fromChapter == entry.fromChapter &&
          e.uptoChapter == entry.uptoChapter &&
          e.inputHash == entry.inputHash,
    );
    if (i >= 0) {
      next[i] = entry;
    } else {
      next.add(entry);
    }
    return _update(_chapters, next);
  }

  /// 删除某书的全部摘要缓存（书架删书连带，`LIB-06` 同款）。
  Future<void> removeBook(String bookId) {
    final List<ChapterSummaryEntry> chapters =
        List<ChapterSummaryEntry>.of(_chapters)
          ..removeWhere((ChapterSummaryEntry e) => e.bookId == bookId);
    final List<BookSummaryEntry> books = List<BookSummaryEntry>.of(_books)
      ..removeWhere((BookSummaryEntry e) => e.bookId == bookId);
    if (chapters.length == _chapters.length && books.length == _books.length) {
      return Future<void>.value();
    }
    return _update(chapters, books);
  }

  /// 订阅变更。
  void addListener(void Function() listener) => _listeners.add(listener);

  /// 退订变更。
  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// 更新内存 → 通知 → 原子落盘。
  Future<void> _update(
    List<ChapterSummaryEntry> chapters,
    List<BookSummaryEntry> books,
  ) async {
    _chapters = chapters;
    _books = books;
    _notify();
    await _store.write(<String, Object?>{
      'chapters': <Object?>[for (final ChapterSummaryEntry e in _chapters) e.toJson()],
      'books': <Object?>[for (final BookSummaryEntry e in _books) e.toJson()],
    });
  }

  /// 通知所有监听者（遍历副本，容忍回调内订阅 / 退订）。
  void _notify() {
    for (final void Function() listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}
