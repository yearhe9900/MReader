// legado 书源（BookSource）数据模型。
//
// 字段名与「阅读」(legado) 导出的 JSON 键**一一对应**，对照参考实现：
//   legado_flutter-2026/lib/data/models/book_source.dart      （书源主体）
//   legado_flutter-2026/lib/data/models/book_source_rule.dart （5 个规则组）
//
// 本文件**不依赖 Flutter**，只是数据结构，便于单测与在正式工程里复用。
//
// 与参考实现的三处刻意差异，都是被真实书源逼出来的：
//   1. 目录规则组「付费」字段：老源写 `isPay`、新源写 `isVip` —— 两个键都认。
//      （本次实测的 `shenshi.json` 用的就是旧的 `isPay`。）
//   2. **未知字段不丢弃**，沉到 `extra` 里。真实源会带 `ruleContent.title`
//      这类参考实现没建模的键，直接丢掉会在「编辑书源再导出」时损坏源。
//   3. 不引 json_annotation / build_runner —— 为 25 个字段上代码生成不划算，
//      手写 fromJson 反而更好读、更好 debug。
import 'dart:convert';

/// 书源类型，对应 legado 的 `bookSourceType`。
enum BookSourceType {
  /// 0：文本小说。
  text(0, '文本'),

  /// 1：有声书。
  audio(1, '有声'),

  /// 2：图片（漫画）。
  image(2, '漫画'),

  /// 3：文件。
  file(3, '文件');

  const BookSourceType(this.code, this.label);

  /// legado 里的数值编码。
  final int code;

  /// 中文显示名。
  final String label;

  /// 由 legado 数值取枚举。未知值退回 [BookSourceType.text]，与 legado 的默认值一致。
  ///
  /// 与其它脏数据一样宽松处理：`"2"` 这种字符串编码也认 —— 导出工具写出字符串
  /// 编码的书源并不罕见。
  static BookSourceType fromCode(Object? code) {
    int? value;
    if (code is int) {
      value = code;
    } else if (code is num) {
      value = code.toInt();
    } else if (code is String) {
      value = int.tryParse(code.trim());
    }
    if (value != null) {
      for (final BookSourceType type in values) {
        if (type.code == value) return type;
      }
    }
    return BookSourceType.text;
  }
}

// ---------------------------------------------------------------------------
// 脏数据读取工具
// ---------------------------------------------------------------------------
//
// 真实书源不是干净的 API 响应：`"enabled": "true"`、`"customOrder": null`、
// 数值写成字符串都真实存在。任一处强转失败就会让**整条书源**解析失败，
// 所以这里全部走宽松读取 + 显式默认值。

String _asString(Object? value) {
  if (value is String) return value;
  if (value == null) return '';
  return value.toString();
}

/// 空字符串归一化为 `null`（legado 里「未配置」就是空串）。
String? _asOptionalString(Object? value) {
  final String text = _asString(value);
  return text.isEmpty ? null : text;
}

int _asInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

bool _asBool(Object? value, {required bool fallback}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final String normalized = value.trim().toLowerCase();
    if (normalized == 'true') return true;
    if (normalized == 'false') return false;
  }
  return fallback;
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map) {
    return value.map(
      (Object? key, Object? val) => MapEntry<String, dynamic>(key.toString(), val),
    );
  }
  return const <String, dynamic>{};
}

/// 挑出 [known] 之外的键原样保留，避免「解析一次丢一片」。
Map<String, dynamic> _extrasOf(Map<String, dynamic> json, Set<String> known) {
  final Map<String, dynamic> extras = <String, dynamic>{};
  for (final MapEntry<String, dynamic> entry in json.entries) {
    if (!known.contains(entry.key)) extras[entry.key] = entry.value;
  }
  return extras;
}

// ---------------------------------------------------------------------------
// 规则组统一视图
// ---------------------------------------------------------------------------

/// 规则组里的一个字段。
///
/// [name] 是 legado 的原始键名（如 `chapterList`），直接展示便于对着源码排查。
class SourceRuleField {
  const SourceRuleField({required this.name, required this.value});

  /// legado 字段名。
  final String name;

  /// 规则串原文（可能为空 = 未配置）。
  final String value;

  /// 是否已配置（legado 用空串表示未配置）。
  bool get isConfigured => value.trim().isNotEmpty;
}

/// 规则组的只读视图。
///
/// 有了它，UI 不必为 5 个规则类各写一遍渲染：拿到 [fields] 直接遍历即可。
class SourceRuleGroup {
  const SourceRuleGroup({
    required this.key,
    required this.label,
    required this.fields,
    this.extras = const <String, dynamic>{},
  });

  /// legado 的规则组键名，如 `ruleSearch`。
  final String key;

  /// 中文显示名，如「搜索」。
  final String label;

  /// 该组全部字段（含未配置的，顺序与 legado 编辑页一致）。
  final List<SourceRuleField> fields;

  /// 参考实现没建模、但源里真实存在的键。
  final Map<String, dynamic> extras;

  /// 已配置的字段数，用于「3/10 已配置」这类摘要。
  int get configuredCount =>
      fields.where((SourceRuleField field) => field.isConfigured).length;

  /// 是否整组都没配（legado 里很常见，比如纯发现源没有搜索规则）。
  bool get isEmpty => configuredCount == 0;
}

// ---------------------------------------------------------------------------
// 5 个规则组
// ---------------------------------------------------------------------------

/// 搜索规则组，对应 `ruleSearch`。
class SearchRule {
  const SearchRule({
    this.bookList,
    this.name,
    this.author,
    this.kind,
    this.wordCount,
    this.lastChapter,
    this.intro,
    this.coverUrl,
    this.bookUrl,
    this.checkKeyWord,
    this.extras = const <String, dynamic>{},
  });

  /// 搜索结果列表规则（返回元素集合，后续字段规则逐个作用其上）。
  final String? bookList;

  /// 书名。
  final String? name;

  /// 作者。
  final String? author;

  /// 分类。
  final String? kind;

  /// 字数。
  final String? wordCount;

  /// 最新章节。
  final String? lastChapter;

  /// 简介。
  final String? intro;

  /// 封面地址。
  final String? coverUrl;

  /// 详情页地址。
  final String? bookUrl;

  /// 校验关键字：搜索结果书名不含它就被丢弃（legado 用来剔除自家站内广告位）。
  final String? checkKeyWord;

  /// 未建模的原始键。
  final Map<String, dynamic> extras;

  static const Set<String> _known = <String>{
    'bookList', 'name', 'author', 'kind', 'wordCount',
    'lastChapter', 'intro', 'coverUrl', 'bookUrl', 'checkKeyWord',
  };

  factory SearchRule.fromJson(Map<String, dynamic> json) => SearchRule(
        bookList: _asOptionalString(json['bookList']),
        name: _asOptionalString(json['name']),
        author: _asOptionalString(json['author']),
        kind: _asOptionalString(json['kind']),
        wordCount: _asOptionalString(json['wordCount']),
        lastChapter: _asOptionalString(json['lastChapter']),
        intro: _asOptionalString(json['intro']),
        coverUrl: _asOptionalString(json['coverUrl']),
        bookUrl: _asOptionalString(json['bookUrl']),
        checkKeyWord: _asOptionalString(json['checkKeyWord']),
        extras: _extrasOf(json, _known),
      );

  /// 该组全部字段（按 legado 编辑页顺序）。
  List<SourceRuleField> get fields => <SourceRuleField>[
        SourceRuleField(name: 'bookList', value: bookList ?? ''),
        SourceRuleField(name: 'name', value: name ?? ''),
        SourceRuleField(name: 'author', value: author ?? ''),
        SourceRuleField(name: 'kind', value: kind ?? ''),
        SourceRuleField(name: 'wordCount', value: wordCount ?? ''),
        SourceRuleField(name: 'lastChapter', value: lastChapter ?? ''),
        SourceRuleField(name: 'intro', value: intro ?? ''),
        SourceRuleField(name: 'coverUrl', value: coverUrl ?? ''),
        SourceRuleField(name: 'bookUrl', value: bookUrl ?? ''),
        SourceRuleField(name: 'checkKeyWord', value: checkKeyWord ?? ''),
      ];

  /// 序列化，键名与 legado 一致（空值不写出，与 legado 导出行为一致）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        ...extras,
        if (bookList != null) 'bookList': bookList,
        if (name != null) 'name': name,
        if (author != null) 'author': author,
        if (kind != null) 'kind': kind,
        if (wordCount != null) 'wordCount': wordCount,
        if (lastChapter != null) 'lastChapter': lastChapter,
        if (intro != null) 'intro': intro,
        if (coverUrl != null) 'coverUrl': coverUrl,
        if (bookUrl != null) 'bookUrl': bookUrl,
        if (checkKeyWord != null) 'checkKeyWord': checkKeyWord,
      };
}

/// 详情页规则组，对应 `ruleBookInfo`。
class BookInfoRule {
  const BookInfoRule({
    this.init,
    this.name,
    this.author,
    this.kind,
    this.wordCount,
    this.lastChapter,
    this.intro,
    this.coverUrl,
    this.tocUrl,
    this.canReName,
    this.extras = const <String, dynamic>{},
  });

  /// 初始化规则：详情页解析前执行，可用 JS 预取数据并写入变量。
  final String? init;

  /// 书名。
  final String? name;

  /// 作者。
  final String? author;

  /// 分类。
  final String? kind;

  /// 字数。
  final String? wordCount;

  /// 最新章节。
  final String? lastChapter;

  /// 简介。
  final String? intro;

  /// 封面地址。
  final String? coverUrl;

  /// 目录页地址（为空则用详情页地址）。
  final String? tocUrl;

  /// 是否允许重命名。
  final String? canReName;

  /// 未建模的原始键。
  final Map<String, dynamic> extras;

  static const Set<String> _known = <String>{
    'init', 'name', 'author', 'kind', 'wordCount',
    'lastChapter', 'intro', 'coverUrl', 'tocUrl', 'canReName',
  };

  factory BookInfoRule.fromJson(Map<String, dynamic> json) => BookInfoRule(
        init: _asOptionalString(json['init']),
        name: _asOptionalString(json['name']),
        author: _asOptionalString(json['author']),
        kind: _asOptionalString(json['kind']),
        wordCount: _asOptionalString(json['wordCount']),
        lastChapter: _asOptionalString(json['lastChapter']),
        intro: _asOptionalString(json['intro']),
        coverUrl: _asOptionalString(json['coverUrl']),
        tocUrl: _asOptionalString(json['tocUrl']),
        canReName: _asOptionalString(json['canReName']),
        extras: _extrasOf(json, _known),
      );

  /// 该组全部字段（按 legado 编辑页顺序）。
  List<SourceRuleField> get fields => <SourceRuleField>[
        SourceRuleField(name: 'init', value: init ?? ''),
        SourceRuleField(name: 'name', value: name ?? ''),
        SourceRuleField(name: 'author', value: author ?? ''),
        SourceRuleField(name: 'kind', value: kind ?? ''),
        SourceRuleField(name: 'wordCount', value: wordCount ?? ''),
        SourceRuleField(name: 'lastChapter', value: lastChapter ?? ''),
        SourceRuleField(name: 'intro', value: intro ?? ''),
        SourceRuleField(name: 'coverUrl', value: coverUrl ?? ''),
        SourceRuleField(name: 'tocUrl', value: tocUrl ?? ''),
        SourceRuleField(name: 'canReName', value: canReName ?? ''),
      ];

  Map<String, dynamic> toJson() => <String, dynamic>{
        ...extras,
        if (init != null) 'init': init,
        if (name != null) 'name': name,
        if (author != null) 'author': author,
        if (kind != null) 'kind': kind,
        if (wordCount != null) 'wordCount': wordCount,
        if (lastChapter != null) 'lastChapter': lastChapter,
        if (intro != null) 'intro': intro,
        if (coverUrl != null) 'coverUrl': coverUrl,
        if (tocUrl != null) 'tocUrl': tocUrl,
        if (canReName != null) 'canReName': canReName,
      };
}

/// 目录规则组，对应 `ruleToc`。
class TocRule {
  const TocRule({
    this.preUpdateJs,
    this.chapterList,
    this.chapterName,
    this.chapterUrl,
    this.isVip,
    this.isVolume,
    this.updateTime,
    this.nextTocUrl,
    this.formatJs,
    this.extras = const <String, dynamic>{},
  });

  /// 解析目录前执行的 JS（常用来把相对地址补全、设置请求头）。
  final String? preUpdateJs;

  /// 章节列表规则。
  final String? chapterList;

  /// 章节名。
  final String? chapterName;

  /// 章节地址。
  final String? chapterUrl;

  /// 是否 VIP 章节。
  ///
  /// 注意：**同时承接 `isVip` 与老键名 `isPay`**（见 [TocRule.fromJson]）。
  final String? isVip;

  /// 是否卷名。
  final String? isVolume;

  /// 更新时间。
  final String? updateTime;

  /// 下一页目录地址（支持多页目录）。
  final String? nextTocUrl;

  /// 格式化章节标题的 JS。
  final String? formatJs;

  /// 未建模的原始键。
  final Map<String, dynamic> extras;

  static const Set<String> _known = <String>{
    'preUpdateJs', 'chapterList', 'chapterName', 'chapterUrl',
    'isVip', 'isPay', 'isVolume', 'updateTime', 'nextTocUrl', 'formatJs',
  };

  factory TocRule.fromJson(Map<String, dynamic> json) => TocRule(
        preUpdateJs: _asOptionalString(json['preUpdateJs']),
        chapterList: _asOptionalString(json['chapterList']),
        chapterName: _asOptionalString(json['chapterName']),
        chapterUrl: _asOptionalString(json['chapterUrl']),
        // legado 早期版本用 `isPay`，后来改名 `isVip`。老源仍在流通，
        // 只认 `isVip` 会把老源的付费标记整条丢掉。
        isVip: _asOptionalString(json['isVip']) ?? _asOptionalString(json['isPay']),
        isVolume: _asOptionalString(json['isVolume']),
        updateTime: _asOptionalString(json['updateTime']),
        nextTocUrl: _asOptionalString(json['nextTocUrl']),
        formatJs: _asOptionalString(json['formatJs']),
        extras: _extrasOf(json, _known),
      );

  /// 该组全部字段（按 legado 编辑页顺序）。
  List<SourceRuleField> get fields => <SourceRuleField>[
        SourceRuleField(name: 'preUpdateJs', value: preUpdateJs ?? ''),
        SourceRuleField(name: 'chapterList', value: chapterList ?? ''),
        SourceRuleField(name: 'chapterName', value: chapterName ?? ''),
        SourceRuleField(name: 'chapterUrl', value: chapterUrl ?? ''),
        SourceRuleField(name: 'isVip', value: isVip ?? ''),
        SourceRuleField(name: 'isVolume', value: isVolume ?? ''),
        SourceRuleField(name: 'updateTime', value: updateTime ?? ''),
        SourceRuleField(name: 'nextTocUrl', value: nextTocUrl ?? ''),
        SourceRuleField(name: 'formatJs', value: formatJs ?? ''),
      ];

  Map<String, dynamic> toJson() => <String, dynamic>{
        ...extras,
        if (preUpdateJs != null) 'preUpdateJs': preUpdateJs,
        if (chapterList != null) 'chapterList': chapterList,
        if (chapterName != null) 'chapterName': chapterName,
        if (chapterUrl != null) 'chapterUrl': chapterUrl,
        // 写回统一用新键名 `isVip`，避免同一份数据出现两种键。
        if (isVip != null) 'isVip': isVip,
        if (isVolume != null) 'isVolume': isVolume,
        if (updateTime != null) 'updateTime': updateTime,
        if (nextTocUrl != null) 'nextTocUrl': nextTocUrl,
        if (formatJs != null) 'formatJs': formatJs,
      };
}

/// 正文规则组，对应 `ruleContent`。
class ContentRule {
  const ContentRule({
    this.content,
    this.nextContentUrl,
    this.webJs,
    this.sourceRegex,
    this.replaceRegex,
    this.imageStyle,
    this.imageDecode,
    this.extras = const <String, dynamic>{},
  });

  /// 正文规则。
  final String? content;

  /// 下一页正文地址（长文分页）。
  final String? nextContentUrl;

  /// 正文页需要 WebView 加载时执行的 JS。
  final String? webJs;

  /// 正文源码正则（只在源码模式下生效）。
  final String? sourceRegex;

  /// 正文替换规则（在所有分页合并后统一应用）。
  final String? replaceRegex;

  /// 图片样式。
  final String? imageStyle;

  /// 图片解密 JS。
  final String? imageDecode;

  /// 未建模的原始键（实测源里出现过 `title`）。
  final Map<String, dynamic> extras;

  static const Set<String> _known = <String>{
    'content', 'nextContentUrl', 'webJs', 'sourceRegex',
    'replaceRegex', 'imageStyle', 'imageDecode',
  };

  factory ContentRule.fromJson(Map<String, dynamic> json) => ContentRule(
        content: _asOptionalString(json['content']),
        nextContentUrl: _asOptionalString(json['nextContentUrl']),
        webJs: _asOptionalString(json['webJs']),
        sourceRegex: _asOptionalString(json['sourceRegex']),
        replaceRegex: _asOptionalString(json['replaceRegex']),
        imageStyle: _asOptionalString(json['imageStyle']),
        imageDecode: _asOptionalString(json['imageDecode']),
        extras: _extrasOf(json, _known),
      );

  /// 该组全部字段（按 legado 编辑页顺序）。
  List<SourceRuleField> get fields => <SourceRuleField>[
        SourceRuleField(name: 'content', value: content ?? ''),
        SourceRuleField(name: 'nextContentUrl', value: nextContentUrl ?? ''),
        SourceRuleField(name: 'webJs', value: webJs ?? ''),
        SourceRuleField(name: 'sourceRegex', value: sourceRegex ?? ''),
        SourceRuleField(name: 'replaceRegex', value: replaceRegex ?? ''),
        SourceRuleField(name: 'imageStyle', value: imageStyle ?? ''),
        SourceRuleField(name: 'imageDecode', value: imageDecode ?? ''),
      ];

  Map<String, dynamic> toJson() => <String, dynamic>{
        ...extras,
        if (content != null) 'content': content,
        if (nextContentUrl != null) 'nextContentUrl': nextContentUrl,
        if (webJs != null) 'webJs': webJs,
        if (sourceRegex != null) 'sourceRegex': sourceRegex,
        if (replaceRegex != null) 'replaceRegex': replaceRegex,
        if (imageStyle != null) 'imageStyle': imageStyle,
        if (imageDecode != null) 'imageDecode': imageDecode,
      };
}

/// 发现规则组，对应 `ruleExplore`。
class ExploreRule {
  const ExploreRule({
    this.bookList,
    this.name,
    this.author,
    this.kind,
    this.wordCount,
    this.lastChapter,
    this.intro,
    this.coverUrl,
    this.bookUrl,
    this.extras = const <String, dynamic>{},
  });

  /// 发现页书籍列表规则。
  final String? bookList;

  /// 书名。
  final String? name;

  /// 作者。
  final String? author;

  /// 分类。
  final String? kind;

  /// 字数。
  final String? wordCount;

  /// 最新章节。
  final String? lastChapter;

  /// 简介。
  final String? intro;

  /// 封面地址。
  final String? coverUrl;

  /// 详情页地址。
  final String? bookUrl;

  /// 未建模的原始键。
  final Map<String, dynamic> extras;

  static const Set<String> _known = <String>{
    'bookList', 'name', 'author', 'kind', 'wordCount',
    'lastChapter', 'intro', 'coverUrl', 'bookUrl',
  };

  factory ExploreRule.fromJson(Map<String, dynamic> json) => ExploreRule(
        bookList: _asOptionalString(json['bookList']),
        name: _asOptionalString(json['name']),
        author: _asOptionalString(json['author']),
        kind: _asOptionalString(json['kind']),
        wordCount: _asOptionalString(json['wordCount']),
        lastChapter: _asOptionalString(json['lastChapter']),
        intro: _asOptionalString(json['intro']),
        coverUrl: _asOptionalString(json['coverUrl']),
        bookUrl: _asOptionalString(json['bookUrl']),
        extras: _extrasOf(json, _known),
      );

  /// 该组全部字段（按 legado 编辑页顺序）。
  List<SourceRuleField> get fields => <SourceRuleField>[
        SourceRuleField(name: 'bookList', value: bookList ?? ''),
        SourceRuleField(name: 'name', value: name ?? ''),
        SourceRuleField(name: 'author', value: author ?? ''),
        SourceRuleField(name: 'kind', value: kind ?? ''),
        SourceRuleField(name: 'wordCount', value: wordCount ?? ''),
        SourceRuleField(name: 'lastChapter', value: lastChapter ?? ''),
        SourceRuleField(name: 'intro', value: intro ?? ''),
        SourceRuleField(name: 'coverUrl', value: coverUrl ?? ''),
        SourceRuleField(name: 'bookUrl', value: bookUrl ?? ''),
      ];

  Map<String, dynamic> toJson() => <String, dynamic>{
        ...extras,
        if (bookList != null) 'bookList': bookList,
        if (name != null) 'name': name,
        if (author != null) 'author': author,
        if (kind != null) 'kind': kind,
        if (wordCount != null) 'wordCount': wordCount,
        if (lastChapter != null) 'lastChapter': lastChapter,
        if (intro != null) 'intro': intro,
        if (coverUrl != null) 'coverUrl': coverUrl,
        if (bookUrl != null) 'bookUrl': bookUrl,
      };
}

// ---------------------------------------------------------------------------
// 书源主体
// ---------------------------------------------------------------------------

/// 一条书源。
class BookSource {
  const BookSource({
    required this.bookSourceUrl,
    this.bookSourceName = '',
    this.bookSourceGroup,
    this.bookSourceType = BookSourceType.text,
    this.bookUrlPattern,
    this.customOrder = 0,
    this.enabled = true,
    this.enabledExplore = true,
    this.jsLib,
    this.enabledCookieJar = true,
    this.concurrentRate,
    this.header,
    this.loginUrl,
    this.loginUi,
    this.loginCheckJs,
    this.coverDecodeJs,
    this.bookSourceComment,
    this.variableComment,
    this.lastUpdateTime = 0,
    this.respondTime = 180000,
    this.weight = 0,
    this.exploreUrl,
    this.exploreScreen,
    this.ruleExplore,
    this.searchUrl,
    this.ruleSearch,
    this.ruleBookInfo,
    this.ruleToc,
    this.ruleContent,
    this.extras = const <String, dynamic>{},
  });

  /// 书源地址（必填，唯一标识），含 `http`/`https`。
  final String bookSourceUrl;

  /// 书源名称。
  final String bookSourceName;

  /// 分组，legado 里是逗号分隔的字符串。
  final String? bookSourceGroup;

  /// 书源类型。
  final BookSourceType bookSourceType;

  /// 详情页 URL 正则，用于把一个 URL 反查成书源。
  final String? bookUrlPattern;

  /// 手动排序编号。
  final int customOrder;

  /// 是否启用。
  final bool enabled;

  /// 是否启用「发现」。
  final bool enabledExplore;

  /// 公共 JS 库：里面定义的函数可在该源的所有 JS 规则里直接调用。
  final String? jsLib;

  /// 是否自动保存 cookie。
  final bool enabledCookieJar;

  /// 并发率，格式 `<并发数>/<间隔毫秒>`，如 `6/1200`。
  final String? concurrentRate;

  /// 请求头（可以是 JSON 字面量，也可以是返回 JSON 的 JS）。
  final String? header;

  /// 登录地址（也可以是 JS 函数体）。
  final String? loginUrl;

  /// 登录界面描述（一个宽松的 JS 对象字面量数组，**不是合法 JSON**）。
  final String? loginUi;

  /// 登录检测 JS。
  final String? loginCheckJs;

  /// 封面解密 JS。
  final String? coverDecodeJs;

  /// 备注。
  final String? bookSourceComment;

  /// 自定义变量说明。
  final String? variableComment;

  /// 最后更新时间（毫秒时间戳）。
  final int lastUpdateTime;

  /// 超时（毫秒）。
  final int respondTime;

  /// 智能排序权重。
  final int weight;

  /// 发现页地址模板。
  final String? exploreUrl;

  /// 发现筛选规则。
  final String? exploreScreen;

  /// 发现规则组。
  final ExploreRule? ruleExplore;

  /// 搜索地址模板。
  final String? searchUrl;

  /// 搜索规则组。
  final SearchRule? ruleSearch;

  /// 详情规则组。
  final BookInfoRule? ruleBookInfo;

  /// 目录规则组。
  final TocRule? ruleToc;

  /// 正文规则组。
  final ContentRule? ruleContent;

  /// 未建模的原始键。
  final Map<String, dynamic> extras;

  static const Set<String> _known = <String>{
    'bookSourceUrl', 'bookSourceName', 'bookSourceGroup', 'bookSourceType',
    'bookUrlPattern', 'customOrder', 'enabled', 'enabledExplore', 'jsLib',
    'enabledCookieJar', 'concurrentRate', 'header', 'loginUrl', 'loginUi',
    'loginCheckJs', 'coverDecodeJs', 'bookSourceComment', 'variableComment',
    'lastUpdateTime', 'respondTime', 'weight', 'exploreUrl', 'exploreScreen',
    'ruleExplore', 'searchUrl', 'ruleSearch', 'ruleBookInfo', 'ruleToc',
    'ruleContent',
  };

  factory BookSource.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> explore = _asMap(json['ruleExplore']);
    final Map<String, dynamic> search = _asMap(json['ruleSearch']);
    final Map<String, dynamic> bookInfo = _asMap(json['ruleBookInfo']);
    final Map<String, dynamic> toc = _asMap(json['ruleToc']);
    final Map<String, dynamic> content = _asMap(json['ruleContent']);

    return BookSource(
      bookSourceUrl: _asString(json['bookSourceUrl']).trim(),
      bookSourceName: _asString(json['bookSourceName']).trim(),
      bookSourceGroup: _asOptionalString(json['bookSourceGroup']),
      bookSourceType: BookSourceType.fromCode(json['bookSourceType']),
      bookUrlPattern: _asOptionalString(json['bookUrlPattern']),
      customOrder: _asInt(json['customOrder']),
      // 这两个开关的 legado 默认值是 true，只有显式写 false 才关。
      enabled: _asBool(json['enabled'], fallback: true),
      enabledExplore: _asBool(json['enabledExplore'], fallback: true),
      jsLib: _asOptionalString(json['jsLib']),
      enabledCookieJar: _asBool(json['enabledCookieJar'], fallback: true),
      concurrentRate: _asOptionalString(json['concurrentRate']),
      header: _asOptionalString(json['header']),
      loginUrl: _asOptionalString(json['loginUrl']),
      loginUi: _asOptionalString(json['loginUi']),
      loginCheckJs: _asOptionalString(json['loginCheckJs']),
      coverDecodeJs: _asOptionalString(json['coverDecodeJs']),
      bookSourceComment: _asOptionalString(json['bookSourceComment']),
      variableComment: _asOptionalString(json['variableComment']),
      lastUpdateTime: _asInt(json['lastUpdateTime']),
      respondTime: _asInt(json['respondTime'], fallback: 180000),
      weight: _asInt(json['weight']),
      exploreUrl: _asOptionalString(json['exploreUrl']),
      exploreScreen: _asOptionalString(json['exploreScreen']),
      ruleExplore: explore.isEmpty ? null : ExploreRule.fromJson(explore),
      searchUrl: _asOptionalString(json['searchUrl']),
      ruleSearch: search.isEmpty ? null : SearchRule.fromJson(search),
      ruleBookInfo: bookInfo.isEmpty ? null : BookInfoRule.fromJson(bookInfo),
      ruleToc: toc.isEmpty ? null : TocRule.fromJson(toc),
      ruleContent: content.isEmpty ? null : ContentRule.fromJson(content),
      extras: _extrasOf(json, _known),
    );
  }

  /// 显示名：名称 → 主机名 → 地址原文 → 占位。
  ///
  /// 真实源里名称缺失并不罕见，用主机名兜底比显示空字符串有用得多。
  String get displayName {
    if (bookSourceName.isNotEmpty) return bookSourceName;
    final String h = host;
    if (h.isNotEmpty) return h;
    if (bookSourceUrl.isNotEmpty) return bookSourceUrl;
    return '未命名书源';
  }

  /// 书源地址的主机名（人类可读形式）。
  ///
  /// 真实书源会挂**中文域名**（本次的 `shenshi.json` 就是
  /// `https://绅士漫画.luoyacheng.ip-ddns.com`）。两个坑：
  ///   1. `Uri.parse` 对 IDN 主机不报错，但会做**百分号编码** ——
  ///      `uri.host` 拿到的是 `%E7%BB%85%E5%A3%AB...`，直接用会显示成一串乱码，
  ///      所以这里 decode 回可读形式。
  ///   2. `Uri` 万一抛异常，再补一层正则兜底。
  ///
  /// 注意：这个 getter 只用于**显示**。真正发请求时请用 [bookSourceUrl] 原文，
  /// 不要拿它去拼 URL（百分号编码过的主机不是合法的 HTTP Host）。
  String get host {
    if (bookSourceUrl.isEmpty) return '';
    try {
      final Uri? uri = Uri.tryParse(bookSourceUrl);
      final String h = uri?.host ?? '';
      if (h.isNotEmpty) return Uri.decodeComponent(h);
    } on FormatException {
      // 落到正则兜底
    } on ArgumentError {
      // decodeComponent 遇到非法转义时抛出，同样兜底
    }
    final RegExpMatch? match =
        RegExp(r'^[a-zA-Z][\w+.-]*://([^/?#]+)').firstMatch(bookSourceUrl);
    return match?.group(1) ?? '';
  }

  /// 5 个规则组的统一视图，顺序与 legado 编辑页一致。
  List<SourceRuleGroup> get ruleGroups => <SourceRuleGroup>[
        if (ruleSearch != null)
          SourceRuleGroup(
            key: 'ruleSearch',
            label: '搜索',
            fields: ruleSearch!.fields,
            extras: ruleSearch!.extras,
          ),
        if (ruleBookInfo != null)
          SourceRuleGroup(
            key: 'ruleBookInfo',
            label: '详情',
            fields: ruleBookInfo!.fields,
            extras: ruleBookInfo!.extras,
          ),
        if (ruleToc != null)
          SourceRuleGroup(
            key: 'ruleToc',
            label: '目录',
            fields: ruleToc!.fields,
            extras: ruleToc!.extras,
          ),
        if (ruleContent != null)
          SourceRuleGroup(
            key: 'ruleContent',
            label: '正文',
            fields: ruleContent!.fields,
            extras: ruleContent!.extras,
          ),
        if (ruleExplore != null)
          SourceRuleGroup(
            key: 'ruleExplore',
            label: '发现',
            fields: ruleExplore!.fields,
            extras: ruleExplore!.extras,
          ),
      ];

  /// 分组列表（legado 的分组是逗号分隔字符串，元素可能带表情且前后有空格）。
  List<String> get groups {
    final String raw = bookSourceGroup ?? '';
    if (raw.trim().isEmpty) return const <String>[];
    return raw
        .split(',')
        .map((String g) => g.trim())
        .where((String g) => g.isNotEmpty)
        .toList(growable: false);
  }

  /// 并发率解析结果，形如 `(6, 1200)`；未配置或格式非法时为 `null`。
  (int, int)? get parsedConcurrentRate {
    final String raw = (concurrentRate ?? '').trim();
    if (raw.isEmpty) return null;
    final List<String> parts = raw.split('/');
    if (parts.length != 2) return null;
    final int? concurrency = int.tryParse(parts[0].trim());
    final int? interval = int.tryParse(parts[1].trim());
    if (concurrency == null || interval == null) return null;
    return (concurrency, interval);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        ...extras,
        'bookSourceUrl': bookSourceUrl,
        'bookSourceName': bookSourceName,
        if (bookSourceGroup != null) 'bookSourceGroup': bookSourceGroup,
        'bookSourceType': bookSourceType.code,
        if (bookUrlPattern != null) 'bookUrlPattern': bookUrlPattern,
        'customOrder': customOrder,
        'enabled': enabled,
        'enabledExplore': enabledExplore,
        if (jsLib != null) 'jsLib': jsLib,
        'enabledCookieJar': enabledCookieJar,
        if (concurrentRate != null) 'concurrentRate': concurrentRate,
        if (header != null) 'header': header,
        if (loginUrl != null) 'loginUrl': loginUrl,
        if (loginUi != null) 'loginUi': loginUi,
        if (loginCheckJs != null) 'loginCheckJs': loginCheckJs,
        if (coverDecodeJs != null) 'coverDecodeJs': coverDecodeJs,
        if (bookSourceComment != null) 'bookSourceComment': bookSourceComment,
        if (variableComment != null) 'variableComment': variableComment,
        'lastUpdateTime': lastUpdateTime,
        'respondTime': respondTime,
        'weight': weight,
        if (exploreUrl != null) 'exploreUrl': exploreUrl,
        if (exploreScreen != null) 'exploreScreen': exploreScreen,
        if (ruleExplore != null) 'ruleExplore': ruleExplore!.toJson(),
        if (searchUrl != null) 'searchUrl': searchUrl,
        if (ruleSearch != null) 'ruleSearch': ruleSearch!.toJson(),
        if (ruleBookInfo != null) 'ruleBookInfo': ruleBookInfo!.toJson(),
        if (ruleToc != null) 'ruleToc': ruleToc!.toJson(),
        if (ruleContent != null) 'ruleContent': ruleContent!.toJson(),
      };

  /// 转成 legado 可导入的 JSON 文本（`toJson` 的字符串形式）。
  String toJsonString() => jsonEncode(<Map<String, dynamic>>[toJson()]);
}
