// URL 规则（`searchUrl` / `exploreUrl` / 各 `bookUrl`）的结构化解析。
//
// 对照原始 legado 的 `AnalyzeUrl.kt`：
//   · 选项分隔     paramPattern = `\s*,\s*(?=\{)`          （AnalyzeUrl.kt:768）
//   · 页码模板     pagePattern  = `<(.*?)>`                 （AnalyzeUrl.kt:769）
//   · data URI     `^data:.*?;base64,(.*)`                  （AppPattern.kt:20）
//   · 占位符       `{{key}}` / `{{KEY}}` / `$keyword` / `${keyword}`
//                  `{{page}}` / `$page` / `${page}`
//   · 页码替换     `<a,b,c>` 取第 page 个，越界取最后一个    （AnalyzeUrl.kt:205-216）
//   · 选项字段     method / charset / headers / body / origin / retry /
//                  type / webView / webJs / dnsIp / js      （UrlOption，AnalyzeUrl.kt:781+）
//
// 本文件只做**静态解析**，不发请求、不跑 JS。
// 不依赖 Flutter。

import 'dart:convert';

/// URL 规则的类型。
enum UrlRuleKind {
  /// 空规则。
  empty('空', '未配置'),

  /// 纯静态 URL。
  staticUrl('url', '静态 URL'),

  /// 含 `{{...}}` 等占位符的模板。
  template('tpl', '模板'),

  /// 整段是 `@js:` / `<js>`。
  js('js', 'JS 生成'),

  /// `data:` 自定义协议（内容直接内嵌在规则里，不发网络请求）。
  dataUri('data', 'data URI'),

  /// 相对地址，需要与书源地址拼。
  relative('rel', '相对地址');

  const UrlRuleKind(this.code, this.label);

  /// 短标识。
  final String code;

  /// 中文说明。
  final String label;
}

/// URL 规则里的占位符。
class UrlPlaceholder {
  const UrlPlaceholder({required this.token, required this.label});

  /// 规则里的原文写法，如 `{{key}}`。
  final String token;

  /// 中文说明。
  final String label;

  /// legado 认的全部占位符写法（`AnalyzeUrl.analyze` 里逐个 replaceAll）。
  static const Map<String, String> known = <String, String>{
    '{{key}}': '搜索关键字（URL 编码后）',
    '{{KEY}}': '搜索关键字（不编码）',
    r'$keyword': '搜索关键字（URL 编码后）',
    r'${keyword}': '搜索关键字（URL 编码后）',
    '{{page}}': '页码',
    r'$page': '页码',
    r'${page}': '页码',
  };
}

/// `,{...}` 里的请求选项，字段与 legado 的 `UrlOption` 对齐。
class UrlRequestOption {
  const UrlRequestOption({
    this.method,
    this.charset,
    this.headers,
    this.body,
    this.origin,
    this.retry,
    this.type,
    this.useWebView,
    this.webJs,
    this.dnsIp,
    this.js,
    this.parsed = true,
    this.raw,
  });

  /// `GET` / `POST`。
  final String? method;

  /// 强制字符集。
  final String? charset;

  /// 请求头。
  final Map<String, dynamic>? headers;

  /// 请求体。
  final String? body;

  /// 源地址。
  final String? origin;

  /// 重试次数。
  final int? retry;

  /// 类型标记（源里常见 `'type':''` / `'ss'` 之类）。
  final String? type;

  /// 是否走 WebView。
  final bool? useWebView;

  /// WebView 里要执行的 JS。
  final String? webJs;

  /// 自定义域名 IP。
  final String? dnsIp;

  /// 解析完 URL 参数后要执行的 JS。
  final String? js;

  /// 选项 JSON 是否解析成功。
  final bool parsed;

  /// 选项原文（解析失败时保留，便于排查）。
  final String? raw;

  /// 逐字段读，容错（选项 JSON 常不规范）。
  factory UrlRequestOption.fromJson(Map<String, dynamic> json, {String? raw}) {
    return UrlRequestOption(
      method: _str(json['method']),
      charset: _str(json['charset']),
      headers: json['headers'] is Map
          ? (json['headers'] as Map).map(
              (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
            )
          : null,
      body: _str(json['body']),
      origin: _str(json['origin']),
      retry: json['retry'] is int ? json['retry'] as int : null,
      type: _str(json['type']),
      useWebView: json['webView'] is bool ? json['webView'] as bool : null,
      webJs: _str(json['webJs']),
      dnsIp: _str(json['dnsIp']),
      js: _str(json['js']),
      raw: raw,
    );
  }

  /// 解析失败的兜底：保留原文，字段全空。
  factory UrlRequestOption.unparsed(String raw) =>
      UrlRequestOption(parsed: false, raw: raw);

  static String? _str(Object? v) {
    if (v == null) return null;
    final String s = v.toString();
    return s.isEmpty ? null : s;
  }

  /// 是否用到了需要额外能力的选项。
  List<String> get specialNeeds => <String>[
        if (useWebView == true) 'WebView 加载',
        if ((webJs ?? '').isNotEmpty) 'WebView 内执行 JS',
        if ((js ?? '').isNotEmpty) '请求前执行 JS',
        if ((dnsIp ?? '').isNotEmpty) '自定义 DNS IP',
        if (charset != null) '强制字符集 ${charset!}',
        if ((method ?? 'GET').toUpperCase() == 'POST') 'POST 请求体',
      ];
}

/// 一条 URL 规则的解析结果。
class ParsedUrlRule {
  const ParsedUrlRule({
    required this.raw,
    required this.kind,
    this.template = '',
    this.options,
    this.pageValues = const <String>[],
    this.placeholders = const <UrlPlaceholder>[],
    this.jsCode,
    this.dataUriBase64,
    this.notes = const <String>[],
  });

  /// 规则原文。
  final String raw;

  /// 类型。
  final UrlRuleKind kind;

  /// 去掉选项后的 URL 模板。
  final String template;

  /// `,{...}` 里的请求选项。
  final UrlRequestOption? options;

  /// `<page,1,2,3>` 里的候选页码（非空即为页码模板）。
  final List<String> pageValues;

  /// 模板里用到的占位符。
  final List<UrlPlaceholder> placeholders;

  /// [UrlRuleKind.js] 时的 JS 代码。
  final String? jsCode;

  /// [UrlRuleKind.dataUri] 时内嵌的 base64 内容。
  final String? dataUriBase64;

  /// 解析时发现的可疑点。
  final List<String> notes;

  /// 是否依赖 JS。
  bool get usesJs => kind == UrlRuleKind.js;

  /// 是否需要 WebView。
  bool get needsWebView => options?.useWebView == true ||
      (options?.webJs ?? '').isNotEmpty;

  @override
  String toString() => 'ParsedUrlRule(${kind.code}, $template)';

  /// legado `AnalyzeUrl` 的选项分隔正则。
  static final RegExp _paramPattern = RegExp(r'\s*,\s*(?=\{)');

  /// legado `AppPattern.pagePattern`。
  static final RegExp _pagePattern = RegExp(r'<(.*?)>');

  /// legado `AppPattern.dataUriRegex`：`^data:.*?;base64,(.*)`。
  static final RegExp _dataUriPattern = RegExp(r'^data:.*?;base64,(.*)');

  /// 整段 JS 的判定（`@js:` / `<js>…</js>`）。
  static final RegExp _jsPattern = RegExp(
    r'^\s*(?:@js:([\w\W]*)|<js>([\w\W]*?)</js>)\s*$',
    caseSensitive: false,
  );

  /// 解析一条 URL 规则。
  static ParsedUrlRule parse(String rule) {
    final List<String> notes = <String>[];
    final String text = rule.trim();

    if (text.isEmpty) {
      return const ParsedUrlRule(raw: '', kind: UrlRuleKind.empty);
    }

    // ---- 整段 JS ----
    final RegExpMatch? jsMatch = _jsPattern.firstMatch(text);
    if (jsMatch != null) {
      final String jsCode = (jsMatch.group(1) ?? jsMatch.group(2) ?? '').trim();
      return ParsedUrlRule(
        raw: text,
        kind: UrlRuleKind.js,
        jsCode: jsCode,
        placeholders: _detectInjectedVars(jsCode),
        notes: const <String>['整条 URL 由 JS 生成，纯 Dart 侧无法静态求值'],
      );
    }

    // ---- 切出选项（`,{` 之前是 URL）----
    //
    // ⚠️ 只在**模板之外**找选项。legado 的 `AnalyzeUrl` 是先把 `@js:` / `{{}}`
    // 求值成真实 URL，再对结果切 `,{`（`replaceKeyPageJs` 在 `analyzeUrl` 之前）。
    // 所以 `{{`data:;base64,${..}},{'type':''}`}}` 里那个 `,{` 是 **JS 字符串的内容**，
    // 不是选项块 —— 静态解析时若照切会把模板撕成两半。
    String template = text;
    UrlRequestOption? options;
    final RegExpMatch? optMatch = _paramPattern.firstMatch(text);
    if (optMatch != null && !_insideTemplate(text, optMatch.start)) {
      template = text.substring(0, optMatch.start);
      final String optionStr = text.substring(optMatch.end);
      final Object? decoded = _tryDecodeOptions(optionStr);
      if (decoded is Map<String, dynamic>) {
        options = UrlRequestOption.fromJson(decoded, raw: optionStr);
      } else {
        options = UrlRequestOption.unparsed(optionStr);
        notes.add('URL 选项不是合法 JSON：legado 先按 GSONStrict 解析，失败后退到宽松解析'
            '（允许单引号与不加引号的键）。这里已尝试同样两段式，仍未成功');
      }
    } else if (optMatch != null) {
      notes.add('`{` 出现在 `{{...}}` 内部，静态阶段不当作请求选项 —— '
          '选项要在 JS 求值出真实 URL 之后才能确定');
    }

    // ---- 页码模板 `<page,1,2,3>` ----
    List<String> pageValues = const <String>[];
    final RegExpMatch? pageMatch = _pagePattern.firstMatch(template);
    if (pageMatch != null) {
      pageValues = (pageMatch.group(1) ?? '')
          .split(',')
          .map((String p) => p.trim())
          .where((String p) => p.isNotEmpty)
          .toList(growable: false);
      if (pageValues.length <= 1) {
        notes.add('页码模板 `<${pageMatch.group(1)}>` 里只有一项，翻页会永远取到同一个值');
      }
    }

    // ---- 占位符 ----
    final List<UrlPlaceholder> placeholders = <UrlPlaceholder>[
      for (final MapEntry<String, String> entry in UrlPlaceholder.known.entries)
        if (template.contains(entry.key))
          UrlPlaceholder(token: entry.key, label: entry.value),
    ];
    for (final RegExpMatch match
        in RegExp(r'\{\{([\w\W]*?)\}\}').allMatches(template)) {
      final String content = (match.group(1) ?? '').trim();
      if (content.isEmpty) continue;
      if (UrlPlaceholder.known.containsKey(match.group(0))) continue;
      // 整条规则本身就是一个 `{{...}}` 模板时不再重复提示
      if (match.group(0) == template.trim()) continue;
      notes.add('模板里有未识别的 `{{$content}}`：'
          'legado 会按变量（有则替换）或 JS 表达式求值');
    }
    // `key` / `page` 是 legado 注入的变量，写在 JS 里（而不是 `{{key}}`）时
    // 上面那轮扫不到，这里补一轮。已经认出来的（`{{page}}` / `$page` 等）不重复加。
    final Set<String> seen = <String>{
      for (final UrlPlaceholder p in placeholders)
        p.token.replaceAll(RegExp(r'[{}$]'), ''),
    };
    for (final UrlPlaceholder p in _detectInjectedVars(template)) {
      if (seen.add(p.token)) placeholders.add(p);
    }

    // ---- data: 自定义协议 ----
    final RegExpMatch? dataMatch = _dataUriPattern.firstMatch(template);
    if (dataMatch != null) {
      return ParsedUrlRule(
        raw: text,
        kind: UrlRuleKind.dataUri,
        template: template,
        options: options,
        pageValues: pageValues,
        placeholders: List<UrlPlaceholder>.unmodifiable(placeholders),
        dataUriBase64: dataMatch.group(1),
        notes: List<String>.unmodifiable(<String>[
          ...notes,
          '自定义协议：沿用 `data:` 前缀但不是标准 data URI，legado 会直接 base64 解码当响应体，'
              '不发网络请求（`AnalyzeUrl.getByteArrayIfDataUri`）',
        ]),
      );
    }

    // ---- 类型 ----
    UrlRuleKind kind;
    if (template.contains('{{')) {
      kind = UrlRuleKind.template;
    } else if (!RegExp(r'^[a-zA-Z][\w+.-]*://').hasMatch(template)) {
      kind = UrlRuleKind.relative;
    } else {
      kind = UrlRuleKind.staticUrl;
    }

    if (kind == UrlRuleKind.relative) {
      notes.add('相对地址：需要与书源地址（或 baseUrl）拼接');
    }

    return ParsedUrlRule(
      raw: text,
      kind: kind,
      template: template,
      options: options,
      pageValues: List<String>.unmodifiable(pageValues),
      placeholders: List<UrlPlaceholder>.unmodifiable(placeholders),
      notes: List<String>.unmodifiable(notes),
    );
  }

  /// 识别 legado 注入的两个变量：`key`（搜索词）与 `page`（页码）。
  ///
  /// 依据原始 legado `AnalyzeUrl`：搜索类 URL 在求值**之前**，legado 会把这两个
  /// 值塞进 JS 执行环境（`@js:` 里能直接用），并把 `{{key}}` / `{{page}}` 先做字符串替换。
  /// 真实书源更常用前者 —— 本次的 `searchUrl` 就是
  /// `{{`data:;base64,${java.base64Encode(key+'🀄'+page)},…`}}`，
  /// 没有 `{{key}}` 字样，只有裸的 `key` / `page`，所以要单独认一次。
  ///
  /// 用前后界断言而不是 `\b`：`\b` 会把 `mykey`、`$.page` 里的也算进来。
  static List<UrlPlaceholder> _detectInjectedVars(String text) {
    if (text.isEmpty) return const <UrlPlaceholder>[];
    final List<UrlPlaceholder> result = <UrlPlaceholder>[];
    for (final UrlPlaceholder p in _injectedVars) {
      final RegExp pattern =
          RegExp('(?<![\\w.\$])${RegExp.escape(p.token)}(?![\\w\$])');
      if (pattern.hasMatch(text)) result.add(p);
    }
    return result;
  }

  /// legado 注入的 JS 变量。
  static const List<UrlPlaceholder> _injectedVars = <UrlPlaceholder>[
    UrlPlaceholder(token: 'key', label: '搜索词（legado 注入的 JS 变量）'),
    UrlPlaceholder(token: 'page', label: '页码（legado 注入的 JS 变量）'),
  ];

  /// 判断 [index] 是否落在某个 `{{...}}` 区间内部。
  ///
  /// 用途：区分「`{{`data:...,{'type':''}`}}` 里的 `,{`（JS 字符串内容）」
  /// 与「`https://a.com/s,{"method":"POST"}` 里的 `,{`（真正的选项块）」。
  static bool _insideTemplate(String text, int index) {
    int depth = 0;
    for (int i = 0; i < index && i < text.length - 1; i++) {
      if (text.startsWith('{{', i)) {
        depth++;
        i++;
      } else if (text.startsWith('}}', i)) {
        if (depth > 0) depth--;
        i++;
      }
    }
    return depth > 0;
  }

  /// 先按严格 JSON 解析，失败再尝试宽松化 —— 对应 legado
  /// 「GSONStrict 失败后退到 Gson 宽松模式」的两段式解析。
  ///
  /// 宽松化的三步（真实书源里的选项几乎都是这种「JS 对象字面量」写法）：
  ///   1. 单引号 → 双引号
  ///   2. 给不加引号的键补引号：`{headers:{referer:...}}` → `{"headers":{"referer":...}}`
  ///   3. 去掉尾随逗号
  ///
  /// 这是**启发式**，不是完整的 JS 对象解析器 —— 键名里带引号/转义/注释等
  /// 极端写法仍需真正的解析器。解析结果只用于展示与体检，不作为执行依据。
  static Object? _tryDecodeOptions(String optionStr) {
    try {
      return jsonDecode(optionStr);
    } on FormatException {
      // 落到宽松解析
    }
    try {
      String relaxed = optionStr.replaceAll("'", '"');
      relaxed = relaxed.replaceAllMapped(
        RegExp(r'([{,]\s*)([A-Za-z_$][\w$]*)(\s*:)'),
        (Match m) => '${m.group(1)}"${m.group(2)}"${m.group(3)}',
      );
      // 去尾随逗号。
      // ⚠️ 必须用 `replaceAllMapped` —— `String.replaceAll` 的替换串里 `$1`
      // 是**字面量**，不做分组引用，会直接把 `$1` 写进 JSON 里导致解析失败。
      relaxed = relaxed.replaceAllMapped(
        RegExp(r',\s*([}\]])'),
        (Match m) => m.group(1) ?? '',
      );
      return jsonDecode(relaxed);
    } on FormatException {
      return null;
    }
  }
}
