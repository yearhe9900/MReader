// 书源体检：把一条书源静态拆开，回答三个问题 ——
//   1. 这条源用到了哪些能力？（联网 / JS / WebView / 登录 / Cookie / 各种取数模式）
//   2. 它依赖哪些 legado 私有 API？（`java.*` / `source.*` / `cache.*` / `Packages.*` …）
//   3. 以当前 demo 的实现程度，哪些字段能跑、哪些跑不了、为什么？
//
// 与参考实现的差异：它没有「诊断」这一层，书源解析止于模型。
// 本文件的价值在于**把「能不能跑」的判断显式化**，而不是等用户点了搜索再报错。
//
// 本文件不依赖 Flutter。

import 'book_source.dart';
import 'capability/capability.dart';
import 'capability/capability_registry.dart';
import 'capability/rule_evaluator.dart';
import 'source_rule.dart';
import 'url_rule.dart';

/// 字段类型 —— **不是每个字段都是规则**，这是书源体检最容易搞错的一点。
enum SourceFieldKind {
  /// 普通规则，交给规则引擎求值。
  rule('规则', '交给规则引擎求值'),

  /// 内容直接就是 JS 代码（**不需要** `<js>` 包裹）。
  /// 如 `ruleToc.preUpdateJs`、`ruleContent.webJs` —— legado 直接拿它当 JS 跑。
  js('JS 代码', 'legado 直接当 JS 执行，不走规则引擎'),

  /// 规则求值结果是 URL，额外按 URL 规则解析（可能带 `,{headers:...}` 选项）。
  urlResult('规则→URL', '规则求值后作为 URL 使用，可能带请求选项'),

  /// 纯文本，不是规则。如 `ruleSearch.checkKeyWord`（校验关键字）。
  text('纯文本', '直接当字符串用，不做规则解析'),

  /// 本身就是 URL 规则（`searchUrl` / `exploreUrl`），由 legado 的 `AnalyzeUrl` 处理。
  url('URL 规则', '由 legado 的 AnalyzeUrl 处理：模板 + 页码 + 选项 + JS');

  const SourceFieldKind(this.label, this.detail);

  /// 中文显示名。
  final String label;

  /// 说明。
  final String detail;
}

/// 书源用到的能力。
enum SourceCapability {
  network('联网', '需要 HTTP 请求'),
  js('JS 引擎', '需要可执行 JavaScript 的引擎'),
  webView('WebView', '需要真实浏览器内核'),
  login('登录态', '需要登录 / 切换域名才能取数'),
  cookieJar('Cookie 管理', '需要自动保存与携带 cookie'),
  customProtocol('自定义协议', '使用 data: 协议内嵌内容'),
  base64('base64', '需要 base64 编解码'),
  hex('hex 解码', '需要十六进制解码'),
  charset('指定字符集', '需要按指定编码解码响应'),
  css('CSS 选择器', 'jsoup 风格选择器'),
  xpath('XPath', 'XPath 取数'),
  jsonPath('JSONPath', 'JSONPath 取数'),
  regex('正则', '正则取数 / 替换'),
  template('{{}} 模板', '模板变量或内嵌 JS'),
  replaceChain('## 替换链', '结果再做一次正则替换'),
  concurrencyRate('并发限速', '声明了 concurrentRate');

  const SourceCapability(this.label, this.detail);

  /// 中文显示名。
  final String label;

  /// 说明。
  final String detail;
}

/// 诊断等级。
enum DiagnosticLevel {
  /// 正常信息。
  info('信息'),

  /// 需要注意，但源本身没问题。
  warn('注意'),

  /// 当前实现跑不了，必须先补能力。
  blocker('阻塞');

  const DiagnosticLevel(this.label);

  /// 中文显示名。
  final String label;
}

/// 一条诊断结论。
class DiagnosticFinding {
  const DiagnosticFinding({
    required this.level,
    required this.title,
    required this.detail,
  });

  /// 等级。
  final DiagnosticLevel level;

  /// 一句话结论。
  final String title;

  /// 展开说明。
  final String detail;
}

/// 一个字段的解析产物。
class ParsedField {
  const ParsedField({
    required this.groupKey,
    required this.groupLabel,
    required this.fieldName,
    required this.raw,
    required this.kind,
    this.rule,
    this.url,
  });

  /// 所属规则组键名（顶层字段为 `''`）。
  final String groupKey;

  /// 所属规则组显示名。
  final String groupLabel;

  /// 字段名（legado 原始键名）。
  final String fieldName;

  /// 字段原文。
  final String raw;

  /// 字段类型。
  final SourceFieldKind kind;

  /// 规则解析结果（[SourceFieldKind.rule] / [SourceFieldKind.urlResult] / [SourceFieldKind.js] 时可能为空）。
  final ParsedSourceRule? rule;

  /// URL 解析结果（[SourceFieldKind.url] / [SourceFieldKind.urlResult] 时）。
  final ParsedUrlRule? url;

  /// 是否已配置。
  bool get isConfigured => raw.trim().isNotEmpty;

  /// 该字段是否依赖 JS。
  bool get usesJs => (rule?.usesJs ?? false) || (url?.usesJs ?? false);

  /// 提取给 [RuleEvaluator] 判定的静态事实。
  ///
  /// 由体检层负责转换，从而断开 `capability/` 对体检层的反向依赖
  /// （避免循环 import）。
  FieldUsage toUsage() => FieldUsage(isConfigured: isConfigured, usesJs: usesJs);

  /// 该字段是否是列表规则（行首可带 `-` / `+` 顺序修饰）。
  bool get isListRule => rule?.isListRule ?? false;

  /// 一句话摘要，供列表展示。
  String get summary {
    if (!isConfigured) return '未配置';
    if (kind == SourceFieldKind.text) return '纯文本';
    if (kind == SourceFieldKind.js) return 'JS ${raw.length} 字符';

    // URL 类字段先给 URL 结构的摘要，信息量比「规则」大得多
    final ParsedUrlRule? u = url;
    if (u != null) {
      final List<String> urlBits = <String>[
        u.kind.label,
        if (u.template.isNotEmpty && u.kind != UrlRuleKind.js)
          u.template.length > 40 ? '${u.template.substring(0, 40)}…' : u.template,
        if (u.pageValues.isNotEmpty) '页码模板',
        if (u.options != null) '带请求选项',
        if (u.options?.parsed == false) '选项非标准 JSON',
        if (u.needsWebView) 'WebView',
      ];
      return urlBits.join(' · ');
    }

    final ParsedSourceRule? r = rule;
    if (r == null) return kind.label;
    // 列表规则的顺序修饰在早期返回路径上也要带上 —— `-<js>…</js>` 恰好命中这条。
    final String listPrefix = <String>[
      if (r.isListRule) '列表规则',
      if (r.listOrder != ListOrderModifier.none) r.listOrder.token,
    ].join(' · ');
    String withList(String s) => listPrefix.isEmpty ? s : '$listPrefix · $s';

    if (r.stages.any((RuleStage s) => s.isJs) && r.segments.isEmpty) {
      return withList(
        'JS ${r.jsBlocks.fold<int>(0, (int a, String b) => a + b.length)} 字符',
      );
    }
    final String modes = r.modes.map((RuleMode m) => m.label).join('/');
    final List<String> bits = <String>[
      if (r.isListRule) '列表规则',
      if (r.listOrder != ListOrderModifier.none) r.listOrder.token,
      if (modes.isNotEmpty) modes,
      if (r.hasTemplates) '模板',
      if (r.hasReplaceChain) '替换链',
      if (r.isMixed) '规则+JS 两段式',
      if (r.usesJs) 'JS',
    ];
    return bits.isEmpty ? kind.label : bits.join(' · ');
  }
}

/// 一条书源的完整体检结果。
class SourceDiagnostic {
  const SourceDiagnostic({
    required this.source,
    required this.fields,
    required this.capabilities,
    required this.findings,
    required this.legadoApis,
    this.evaluator,
    this.evaluations = const <ParsedField, FieldEvaluation>{},
  });

  /// 被体检的书源。
  final BookSource source;

  /// 全部字段的解析产物（含未配置的，便于展示「N/M 已配置」）。
  final List<ParsedField> fields;

  /// 用到的能力。
  final Set<SourceCapability> capabilities;

  /// 诊断结论（blocker 在前）。
  final List<DiagnosticFinding> findings;

  /// 引用到的 legado 私有 API，如 `java.ajax`、`source.putLoginInfo`。
  final List<String> legadoApis;

  /// 第 2 层（平台相对）的判定器。
  ///
  /// [inspect] 时为 null（只有第 1 层）；[inspectFor] 时非空。
  final RuleEvaluator? evaluator;

  /// 按字段的平台评估结果（第 2 层）。[inspect] 时为空表。
  ///
  /// 键是 [fields] 中的**同一实例**（[ParsedField] 未定义值相等），
  /// 因此用 `evaluations[field]` 查询时须传入来自 [fields] 的实例。
  final Map<ParsedField, FieldEvaluation> evaluations;

  /// 是否叠加了平台层（第 2 层）结论。
  bool get hasPlatformLayer => evaluator != null;

  /// 依赖 JS 但本平台不可用（降级）的字段数。
  int get jsUnavailableFieldCount => evaluations.values
      .where((FieldEvaluation e) =>
          e.outcome == EvaluationOutcome.jsUnavailable)
      .length;

  /// 依赖 JS 且本平台可求值的字段数。
  int get jsRequiredFieldCount => evaluations.values
      .where((FieldEvaluation e) => e.outcome == EvaluationOutcome.jsRequired)
      .length;

  /// 某字段的平台结论；未叠加平台层或字段不存在时返回 null。
  FieldEvaluation? evaluationOf(ParsedField field) => evaluations[field];

  /// 已配置的字段数。
  int get configuredFieldCount =>
      fields.where((ParsedField f) => f.isConfigured).length;

  /// 依赖 JS 的字段数。
  int get jsFieldCount =>
      fields.where((ParsedField f) => f.isConfigured && f.usesJs).length;

  /// 与 JS 无关、纯静态就能跑通的字段（用来回答「不接 JS 引擎能跑多远」）。
  List<ParsedField> get jsFreeFields => fields
      .where((ParsedField f) => f.isConfigured && !f.usesJs)
      .toList(growable: false);

  /// 最高等级的诊断结论。
  DiagnosticLevel get worstLevel {
    if (findings.any((DiagnosticFinding f) => f.level == DiagnosticLevel.blocker)) {
      return DiagnosticLevel.blocker;
    }
    if (findings.any((DiagnosticFinding f) => f.level == DiagnosticLevel.warn)) {
      return DiagnosticLevel.warn;
    }
    return DiagnosticLevel.info;
  }

  /// 按等级分组后的结论，便于 UI 分节。
  List<DiagnosticFinding> findingsOf(DiagnosticLevel level) => findings
      .where((DiagnosticFinding f) => f.level == level)
      .toList(growable: false);

  /// 对一条书源做体检（**第 1 层：源固有、平台无关**）。
  ///
  /// 结论只回答「这条源依赖什么」，与运行平台无关 ——
  /// 换平台时本方法的结果**不变**。平台可用性请用 [inspectFor]。
  static SourceDiagnostic inspect(BookSource source) => _inspect(source);

  /// 在 [inspect] 的第 1 层结论之上，叠加**第 2 层「本平台能力」**结论。
  ///
  /// 设计原则：**第 1 层是「事实」，第 2 层是「当前环境下的结论」**。
  /// 本方法不改写 [SourceDiagnostic.fields] / [SourceDiagnostic.capabilities] /
  /// [SourceDiagnostic.legadoApis]，只在 [SourceDiagnostic.evaluations] 上叠加
  /// 按字段的平台判定，并把「依赖 JS 引擎」的 blocker 文案按平台分流。
  ///
  /// [registry] 由调用方显式注入（本项目不使用全局单例）。
  static SourceDiagnostic inspectFor(
    BookSource source,
    CapabilityRegistry registry,
  ) =>
      _inspect(source, registry: registry);

  /// 体检主流程。`registry` 为 null 时只产第 1 层结论（等价于 [inspect]）。
  static SourceDiagnostic _inspect(
    BookSource source, {
    CapabilityRegistry? registry,
  }) {
    final List<ParsedField> fields = _parseFields(source);
    final Set<SourceCapability> capabilities = <SourceCapability>{
      SourceCapability.network,
    };
    final Set<String> apis = <String>{};

    // ---- 汇总各字段的能力与 API 依赖 ----
    for (final ParsedField field in fields) {
      if (!field.isConfigured) continue;
      _collectCapabilities(field, capabilities, apis);
    }

    // ---- 顶层字段 ----
    _scanTopLevel(source, capabilities, apis);

    // ---- 规则组整体 ----
    //
    // 未建模字段单独出结论、不混进 API 列表 —— 「数据可能丢」和
    // 「运行期符号缺失」是两回事。
    final List<String> unmodeledGroups = <String>[
      for (final SourceRuleGroup group in source.ruleGroups)
        if (group.extras.isNotEmpty)
          '`${group.key}`（${group.extras.keys.join('、')}）',
    ];

    final List<DiagnosticFinding> findings = _buildFindings(
      source: source,
      fields: fields,
      capabilities: capabilities,
      apis: apis,
      unmodeledGroups: unmodeledGroups,
      registry: registry,
    );

    // ---- 第 2 层：按字段的平台评估 ----
    final RuleEvaluator? evaluator =
        registry == null ? null : RuleEvaluator(registry);
    final Map<ParsedField, FieldEvaluation> evaluations = evaluator == null
        ? const <ParsedField, FieldEvaluation>{}
        : <ParsedField, FieldEvaluation>{
            for (final ParsedField field in fields)
              field: evaluator.evaluate(field.toUsage()),
          };

    return SourceDiagnostic(
      source: source,
      fields: List<ParsedField>.unmodifiable(fields),
      capabilities: Set<SourceCapability>.unmodifiable(capabilities),
      findings: List<DiagnosticFinding>.unmodifiable(findings),
      legadoApis: apis.toList(growable: false)..sort(),
      evaluator: evaluator,
      evaluations: Map<ParsedField, FieldEvaluation>.unmodifiable(evaluations),
    );
  }

  // -------------------------------------------------------------------------
  // 字段解析
  // -------------------------------------------------------------------------

  /// 哪些字段名是「规则求值结果为 URL」。
  static const Map<String, Set<String>> _urlResultFields =
      <String, Set<String>>{
    'ruleSearch': <String>{'bookUrl', 'coverUrl'},
    'ruleBookInfo': <String>{'coverUrl', 'tocUrl'},
    'ruleToc': <String>{'nextTocUrl'},
    'ruleContent': <String>{'nextContentUrl'},
    'ruleExplore': <String>{'bookUrl', 'coverUrl'},
  };

  /// 哪些字段内容直接就是 JS（不需要 `<js>` 包裹）。
  ///
  /// 依据：legado 里这些字段被直接当 JS 表达式求值，例如
  /// `BookInfoRule.init` → `_executeJs(html, rule.init!)`。
  static const Map<String, Set<String>> _jsFields = <String, Set<String>>{
    'ruleBookInfo': <String>{'init'},
    'ruleToc': <String>{'preUpdateJs', 'formatJs'},
    'ruleContent': <String>{'webJs', 'imageDecode'},
  };

  /// 哪些字段是纯文本（不是规则）。
  static const Map<String, Set<String>> _textFields = <String, Set<String>>{
    'ruleSearch': <String>{'checkKeyWord'},
  };

  /// 哪些字段是**列表规则** —— 行首可以带 `-` / `+` 顺序修饰。
  ///
  /// 依据：legado 里只有这几处会在调用 `getElements` 之前剥 `-` / `+`
  /// （`BookList.kt:90`、`BookChapterList.kt:54`、`RssParserByRule.kt:49`）。
  static const Map<String, Set<String>> _listRuleFields =
      <String, Set<String>>{
    'ruleSearch': <String>{'bookList'},
    'ruleExplore': <String>{'bookList'},
    'ruleToc': <String>{'chapterList'},
  };

  static List<ParsedField> _parseFields(BookSource source) {
    final List<ParsedField> result = <ParsedField>[];

    // 顶层 URL 规则
    result.add(_urlField('', '书源', 'searchUrl', source.searchUrl));
    result.add(_urlField('', '书源', 'exploreUrl', source.exploreUrl));
    result.add(_urlField('', '书源', 'bookUrlPattern', source.bookUrlPattern));

    // 顶层 JS 字段
    for (final MapEntry<String, String?> entry in <String, String?>{
      'jsLib': source.jsLib,
      'loginUrl': source.loginUrl,
      'loginCheckJs': source.loginCheckJs,
      'coverDecodeJs': source.coverDecodeJs,
    }.entries) {
      result.add(ParsedField(
        groupKey: '',
        groupLabel: '书源',
        fieldName: entry.key,
        raw: entry.value ?? '',
        kind: SourceFieldKind.js,
      ));
    }

    // 规则组
    for (final SourceRuleGroup group in source.ruleGroups) {
      for (final SourceRuleField field in group.fields) {
        result.add(_parseGroupField(group, field));
      }
    }

    return result;
  }

  static ParsedField _urlField(
    String groupKey,
    String groupLabel,
    String name,
    String? value,
  ) {
    final String raw = value ?? '';
    return ParsedField(
      groupKey: groupKey,
      groupLabel: groupLabel,
      fieldName: name,
      raw: raw,
      kind: SourceFieldKind.url,
      url: raw.trim().isEmpty ? null : ParsedUrlRule.parse(raw),
    );
  }

  static ParsedField _parseGroupField(
    SourceRuleGroup group,
    SourceRuleField field,
  ) {
    final String raw = field.value;

    // 字段类型取决于**字段名**，与是否已配置无关 ——
    // `formatJs` 就算空着也仍然是「JS 字段」，不能因为没配就标成「规则」。
    late final SourceFieldKind kind;
    if ((_jsFields[group.key] ?? const <String>{}).contains(field.name)) {
      kind = SourceFieldKind.js;
    } else if ((_textFields[group.key] ?? const <String>{}).contains(field.name)) {
      kind = SourceFieldKind.text;
    } else if ((_urlResultFields[group.key] ?? const <String>{})
        .contains(field.name)) {
      kind = SourceFieldKind.urlResult;
    } else {
      kind = SourceFieldKind.rule;
    }

    if (!field.isConfigured) {
      return ParsedField(
        groupKey: group.key,
        groupLabel: group.label,
        fieldName: field.name,
        raw: raw,
        kind: kind,
      );
    }

    final bool needsRule =
        kind == SourceFieldKind.rule || kind == SourceFieldKind.urlResult;
    final bool needsUrl =
        kind == SourceFieldKind.url || kind == SourceFieldKind.urlResult;
    final bool isListRule =
        (_listRuleFields[group.key] ?? const <String>{}).contains(field.name);

    return ParsedField(
      groupKey: group.key,
      groupLabel: group.label,
      fieldName: field.name,
      raw: raw,
      kind: kind,
      rule: !needsRule
          ? null
          : isListRule
              ? ParsedSourceRule.parseList(raw)
              : ParsedSourceRule.parse(raw),
      url: needsUrl ? ParsedUrlRule.parse(raw) : null,
    );
  }

  // -------------------------------------------------------------------------
  // 能力 / API 采集
  // -------------------------------------------------------------------------

  /// legado 私有 API 的形态：`java.ajax` / `source.get` / `Packages.java.lang.Thread`。
  static final RegExp _legadoApiPattern = RegExp(
    r'\b(java|source|cache|cookie|book|base64|Packages|org|com)\.[A-Za-z_$][\w$.]*',
  );

  static void _collectCapabilities(
    ParsedField field,
    Set<SourceCapability> capabilities,
    Set<String> apis,
  ) {
    final String raw = field.raw;

    // 字段类型决定的能力
    switch (field.kind) {
      case SourceFieldKind.js:
        capabilities.add(SourceCapability.js);
      case SourceFieldKind.url:
      case SourceFieldKind.urlResult:
        capabilities.add(SourceCapability.template);
      case SourceFieldKind.rule:
      case SourceFieldKind.text:
        break;
    }

    // 规则模式带来的能力
    final ParsedSourceRule? rule = field.rule;
    if (rule != null) {
      for (final RuleMode mode in rule.modes) {
        switch (mode) {
          case RuleMode.css:
            capabilities.add(SourceCapability.css);
          case RuleMode.xpath:
            capabilities.add(SourceCapability.xpath);
          case RuleMode.jsonPath:
            capabilities.add(SourceCapability.jsonPath);
          case RuleMode.regex:
            capabilities.add(SourceCapability.regex);
          case RuleMode.js:
            capabilities.add(SourceCapability.js);
          case RuleMode.template:
          case RuleMode.variable:
          case RuleMode.identifier:
          case RuleMode.literal:
          case RuleMode.empty:
            break;
        }
      }
      if (rule.hasTemplates) capabilities.add(SourceCapability.template);
      if (rule.hasReplaceChain) capabilities.add(SourceCapability.replaceChain);
      if (rule.usesJs) capabilities.add(SourceCapability.js);
      for (final RuleSegment segment in rule.segments) {
        if (segment.replaceRegex != null) capabilities.add(SourceCapability.regex);
      }
    }

    final ParsedUrlRule? url = field.url;
    if (url != null) {
      if (url.usesJs) capabilities.add(SourceCapability.js);
      if (url.kind == UrlRuleKind.dataUri) capabilities.add(SourceCapability.customProtocol);
      if (url.kind == UrlRuleKind.template) capabilities.add(SourceCapability.template);
      if (url.options?.specialNeeds.isNotEmpty ?? false) {
        if (url.needsWebView) capabilities.add(SourceCapability.webView);
        if ((url.options?.charset ?? '') .isNotEmpty) capabilities.add(SourceCapability.charset);
      }
      if (url.pageValues.isNotEmpty) capabilities.add(SourceCapability.template);
    }

    // 文本层面的能力探测
    final String lower = raw.toLowerCase();
    if (lower.contains('base64')) capabilities.add(SourceCapability.base64);
    if (lower.contains('hexdecode') || lower.contains('hexencode')) {
      capabilities.add(SourceCapability.hex);
    }
    if (lower.contains('getwebviewua') || lower.contains('webview')) {
      capabilities.add(SourceCapability.webView);
    }
    if (lower.contains('cache.')) capabilities.add(SourceCapability.js);

    // legado 私有 API
    for (final RegExpMatch match in _legadoApiPattern.allMatches(raw)) {
      apis.add(match.group(0) ?? '');
    }
  }

  static void _scanTopLevel(
    BookSource source,
    Set<SourceCapability> capabilities,
    Set<String> apis,
  ) {
    final StringBuffer top = StringBuffer()
      ..write(source.header ?? '')
      ..write(' ')
      ..write(source.loginUrl ?? '')
      ..write(' ')
      ..write(source.loginCheckJs ?? '')
      ..write(' ')
      ..write(source.loginUi ?? '')
      ..write(' ')
      ..write(source.jsLib ?? '')
      ..write(' ')
      ..write(source.coverDecodeJs ?? '');

    final String text = top.toString();
    if (text.trim().isEmpty) return;

    if ((source.loginUrl ?? '').isNotEmpty ||
        (source.loginCheckJs ?? '').isNotEmpty ||
        (source.loginUi ?? '').isNotEmpty) {
      capabilities.add(SourceCapability.login);
    }
    if (source.enabledCookieJar) capabilities.add(SourceCapability.cookieJar);
    if (source.parsedConcurrentRate != null) {
      capabilities.add(SourceCapability.concurrencyRate);
    }
    if (text.toLowerCase().contains('base64')) capabilities.add(SourceCapability.base64);
    if (text.toLowerCase().contains('getwebviewua')) {
      capabilities.add(SourceCapability.webView);
    }
    if (source.jsLib != null) capabilities.add(SourceCapability.js);

    for (final RegExpMatch match in _legadoApiPattern.allMatches(text)) {
      apis.add(match.group(0) ?? '');
    }
  }

  // -------------------------------------------------------------------------
  // 结论文本
  // -------------------------------------------------------------------------

  static List<DiagnosticFinding> _buildFindings({
    required BookSource source,
    required List<ParsedField> fields,
    required Set<SourceCapability> capabilities,
    required Set<String> apis,
    required List<String> unmodeledGroups,
    CapabilityRegistry? registry,
  }) {
    final List<DiagnosticFinding> findings = <DiagnosticFinding>[];
    final List<ParsedField> configured =
        fields.where((ParsedField f) => f.isConfigured).toList(growable: false);
    final int jsFields =
        configured.where((ParsedField f) => f.usesJs).length;

    // ---- 书源类型 ----
    if (source.bookSourceType != BookSourceType.text) {
      findings.add(DiagnosticFinding(
        level: DiagnosticLevel.blocker,
        title: '书源类型是「${source.bookSourceType.label}」，'
            '当前 demo 只实现了文本阅读',
        detail: 'bookSourceType=${source.bookSourceType.code}。'
            '图片/漫画源的内容是图片列表，需要图片阅读器（下载 + 翻页 + 缓存），'
            '与文本源的正文渲染完全不同，不能共用同一条渲染链路。',
      ));
    }

    // ---- 列表规则的顺序修饰 ----
    final List<ParsedField> ordered = fields
        .where((ParsedField f) => f.rule?.listOrder != null &&
            f.rule!.listOrder != ListOrderModifier.none)
        .toList(growable: false);
    if (ordered.isNotEmpty) {
      findings.add(DiagnosticFinding(
        level: DiagnosticLevel.info,
        title: '列表规则带顺序修饰：'
            '${ordered.map((ParsedField f) => '${f.groupLabel}.${f.fieldName}'
                '(${f.rule!.listOrder.token})').join('、')}',
        detail: '行首的 `-` / `+` 只在**列表规则**上生效（bookList / chapterList / '
            'RSS articles），legado 在把规则交给规则引擎之前先把它剥掉'
            '（`BookList.kt:90` / `BookChapterList.kt:54`）。它不参与选择器解析，'
            '整串照搬给 CSS 选择器会得到错误结果；'
            '而且两个列表的反转方向相反 —— 目录默认反转、书单默认不反转。',
      ));
    }

    // ---- JS 依赖 ----
    //
    // 第 1 层（registry == null）文案逐字保持不变；叠加平台层（inspectFor）时
    // 按平台分流：能力齐备 → 引导去实现引擎；能力缺失 → 本平台不可用。
    if (capabilities.contains(SourceCapability.js)) {
      findings.add(_jsDependencyFinding(
        registry: registry,
        jsFields: jsFields,
        configuredCount: configured.length,
      ));
    } else if (configured.isNotEmpty) {
      findings.add(DiagnosticFinding(
        level: DiagnosticLevel.info,
        title: '无 JS 依赖：全部字段可用静态规则求值',
        detail: '这类源只需要 CSS/XPath/JSONPath + 正则替换 + URL 模板即可跑通。',
      ));
    }

    // ---- legado 私有 API ----
    if (apis.isNotEmpty) {
      findings.add(DiagnosticFinding(
        level: DiagnosticLevel.warn,
        title: '引用了 ${apis.length} 个 legado 私有 API',
        detail: '这些符号只在 legado 运行期存在，Dart 侧需要逐个提供等价实现：'
            '${apis.take(12).join('、')}${apis.length > 12 ? ' 等' : ''}',
      ));
    }

    // ---- 取数模式分布 ----
    final List<String> modeLabels = <String>[
      for (final SourceCapability c in <SourceCapability>[
        SourceCapability.css,
        SourceCapability.xpath,
        SourceCapability.jsonPath,
        SourceCapability.regex,
      ])
        if (capabilities.contains(c)) c.label,
    ];
    if (modeLabels.isNotEmpty) {
      findings.add(DiagnosticFinding(
        level: DiagnosticLevel.info,
        title: '取数模式：${modeLabels.join('、')}',
        detail: '这几种模式都不需要 JS 引擎，是纯静态规则引擎要覆盖的范围。',
      ));
    }

    // ---- 登录 / 域名 ----
    if (capabilities.contains(SourceCapability.login)) {
      final bool uiIsNotJson = (source.loginUi ?? '').trim().isNotEmpty &&
          !(source.loginUi!.trim().startsWith('[') &&
              source.loginUi!.contains('"name"'));
      findings.add(DiagnosticFinding(
        level: DiagnosticLevel.warn,
        title: '该源带登录/域名切换逻辑',
        detail: '`loginUrl` 里往往内置了「发布页 → 测速 → 选最快域名」的流程，'
            '`loginCheckJs` 负责识别 302 跳转并回写新域名。'
            '${uiIsNotJson ? '`loginUi` 是 JS 对象字面量写法（键名未加引号），'
                '按标准 JSON 解析会失败 —— 需要用宽松解析。' : ''}'
            '固定写死书源地址的话，这类源很可能直接不可用。',
      ));
    }

    // ---- WebView ----
    if (capabilities.contains(SourceCapability.webView)) {
      findings.add(DiagnosticFinding(
        level: DiagnosticLevel.warn,
        title: '部分请求需要 WebView',
        detail: '源里出现了 `java.getWebViewUA()` 或请求选项 `webView:true`。'
            '这类请求依赖真实浏览器环境（Cookie 下发、JS 加密参数），'
            '纯 HTTP 客户端可能被拦。',
      ));
    }

    // ---- 并发限速 ----
    final (int, int)? rate = source.parsedConcurrentRate;
    if (rate != null) {
      findings.add(DiagnosticFinding(
        level: DiagnosticLevel.info,
        title: '声明了并发限速：${rate.$1} 并发 / ${rate.$2}ms 间隔',
        detail: '`concurrentRate` 是站方反爬的自我约束，做并发调度时要照它限流，'
            '超速容易被封。',
      ));
    }

    // ---- 中文域名 ----
    if (RegExp(r'[^\x00-\x7F]').hasMatch(source.host)) {
      findings.add(DiagnosticFinding(
        level: DiagnosticLevel.info,
        title: '书源地址含非 ASCII 域名（IDN）：${source.host}',
        detail: 'Dart 的 `Uri.parse` 会把主机名做百分号编码，'
            '拿 `uri.host` 直接发请求会失败；需要转 punycode 或按原始字节发。'
            '显示时则要 decode 回可读形式。',
      ));
    }

    // ---- 目录付费字段用了旧键名 ----
    if (source.ruleToc != null &&
        source.ruleToc!.isVip != null &&
        source.ruleToc!.extras.isNotEmpty) {
      findings.add(DiagnosticFinding(
        level: DiagnosticLevel.info,
        title: '目录规则含未建模字段',
        detail: 'ruleToc 里出现了模型未建模的键：'
            '${source.ruleToc!.extras.keys.join('、')}',
      ));
    }

    // ---- init JS 产出变量 ----
    final bool hasInitJs =
        (source.ruleBookInfo?.init ?? '').trim().isNotEmpty;
    if (hasInitJs) {
      final List<String> literalFields = <String>[
        for (final ParsedField f
            in configured.where((ParsedField f) => f.groupKey == 'ruleBookInfo'))
          if (f.rule != null &&
              f.rule!.segments.length == 1 &&
              (f.rule!.segments.first.mode == RuleMode.identifier ||
                  f.rule!.segments.first.mode == RuleMode.literal))
            f.fieldName,
      ];
      if (literalFields.isNotEmpty) {
        findings.add(DiagnosticFinding(
          level: DiagnosticLevel.warn,
          title: '详情页字段是「裸标识符」，依赖 init JS 写入的变量',
          detail: '字段 ${literalFields.join('、')} 的值不是选择器，'
              '而是 `${literalFields.first}` 这类标识符。legado 的 '
              '`AnalyzeRule.getString` 会先看内容类型：内容是 `init` JS 出来的对象（map）时'
              '**按键名直接取值**，只有内容是 DOM 时才走 jsoup 选择器。'
              '所以要跑通这些字段，必须先实现 init 的变量回写。',
        ));
      }
    }

    // ---- 规则组空置 ----
    for (final SourceRuleGroup group in source.ruleGroups) {
      if (group.isEmpty) {
        findings.add(DiagnosticFinding(
          level: DiagnosticLevel.info,
          title: '规则组「${group.label}」未配置任何字段',
          detail: '`${group.key}` 存在但全为空 —— 该能力在此源上不可用。',
        ));
      }
    }
    if (source.enabledExplore && source.ruleExplore == null) {
      findings.add(DiagnosticFinding(
        level: DiagnosticLevel.warn,
        title: '声明启用了「发现」，但没有发现规则',
        detail: '`enabledExplore=true` 而 `ruleExplore` 缺失，'
            '发现页会请求失败或被判为无效源。',
      ));
    }

    // ---- 未建模字段（会丢信息）----
    if (source.extras.isNotEmpty) {
      findings.add(DiagnosticFinding(
        level: DiagnosticLevel.warn,
        title: '书源含 ${source.extras.length} 个模型未建模的顶层字段',
        detail: '${source.extras.keys.join('、')} —— 已原样保留在 `extras`，'
            '导出时不会丢失。',
      ));
    }
    if (unmodeledGroups.isNotEmpty) {
      findings.add(DiagnosticFinding(
        level: DiagnosticLevel.info,
        title: '规则组里有 ${unmodeledGroups.length} 处未建模的键',
        detail: '${unmodeledGroups.join('；')} —— 同样已原样保留，'
            '不会在「导入 → 导出」链路里丢失。',
      ));
    }

    findings.sort((DiagnosticFinding a, DiagnosticFinding b) {
      final int byLevel = b.level.index.compareTo(a.level.index);
      if (byLevel != 0) return byLevel;
      return a.title.compareTo(b.title);
    });
    return findings;
  }

  /// 「依赖 JS 引擎」的 blocker。
  ///
  /// · [registry] 为 null（[inspect]）→ 输出第 1 层原文案，逐字不变；
  /// · 能力齐备（Android / iOS）→ 引导去实现引擎；
  /// · 能力缺失（鸿蒙未适配 / 无引擎）→ 说明「本平台不可用，请用纯规则源或换平台」。
  static DiagnosticFinding _jsDependencyFinding({
    required CapabilityRegistry? registry,
    required int jsFields,
    required int configuredCount,
  }) {
    final String title = '依赖 JS 引擎：$jsFields/$configuredCount 个已配置字段含 JS';

    // 第 1 层：平台中性的原文案。
    if (registry == null) {
      return DiagnosticFinding(
        level: DiagnosticLevel.blocker,
        title: title,
        detail: 'legado 用 QuickJS/JS 沙箱执行规则里的 JavaScript，并提供 '
            '`java.*`（网络、字符串、编解码）、`source.*`（登录态、变量）、'
            '`cache.*`（内存缓存）等私有 API。当前 demo 无 JS 引擎，'
            '这些字段**无法求值**。参考实现用 flutter_js 承载。',
      );
    }

    // 第 2 层 · 能力齐备：引导去实现引擎。
    if (registry.has(Capability.script)) {
      return DiagnosticFinding(
        level: DiagnosticLevel.blocker,
        title: title,
        detail: '本平台脚本能力可用（${registry.script.label}），'
            '但这些字段仍需接入 JS 引擎才能求值 —— '
            '请实现 `ScriptCapability` 实现类并在 `main.dart` 注入 '
            '`CapabilityRegistry`。接入之前，这些字段**无法求值**。',
      );
    }

    // 第 2 层 · 能力缺失：本平台不可用。
    final String reason =
        registry.reasonFor(Capability.script) ?? '本平台无 JS 引擎';
    return DiagnosticFinding(
      level: DiagnosticLevel.blocker,
      title: title,
      detail: '本平台不可用（$reason）—— '
          '请改用纯规则源，或切换到具备 JS 能力的平台。'
          'legado 原用 QuickJS/JS 沙箱承载这些字段，并提供 `java.*` / '
          '`source.*` / `cache.*` 等私有 API。',
    );
  }
}
