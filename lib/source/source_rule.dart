// 单条 legado 规则的**结构化解析**（不是执行）。
//
// 把一条规则串拆成「执行阶段 → 组合段 → 模式/选择器/提取器/替换链/模板/变量引用」，
// 让 UI 能把规则的可读结构摊开给人看，也便于做静态体检。
//
// ─────────────────────────────────────────────────────────────────────────
// 核心：切分顺序必须是「先切 JS，再切组合符」
//
// 权威依据是原始 legado 的 `AnalyzeRule.splitSourceRule`
// （`567Reader/app/src/main/java/com/qreader/reader/model/analyzeRule/AnalyzeRule.kt`）：
//
//   JS_PATTERN    = <js>([\w\W]*?)</js>|@js:([\w\W]*)      // AppPattern.kt:7
//   WebJS_PATTERN = @webjs:([\w\W]{5,})                     // AppPattern.kt:9
//
// 它先用这两条正则把规则串切成**有序的段**（JS 段 / 普通段），
// 之后 `&&` / `||` / `%%` 的拆分只在普通段内部发生
// （见 `AnalyzeByJSoup.kt:87-88`：`RuleAnalyzer(sourceRule.elementsRule).splitRule("&&","||","%%")`）。
//
// ⚠️ 参考实现 `legado_flutter-2026/lib/utils/parsers/rule_parser.dart:151` 反了 ——
// 它对整条规则先 `RuleAnalyzer(...).splitRule(['&&','||','%%'])` 再判 JS，
// 于是**任何含 `&&` / `||` 的 `<js>` 规则都会被切碎**。
// 实测 `shenshi.json` 的 `ruleSearch.bookList`（内部有 `hj!=''&&result.length>1`）
// 会被切成两段，整条源直接报废。本文件按原始 legado 的顺序实现，并在体检里报这条差异。
// ─────────────────────────────────────────────────────────────────────────
//
// 其余语法判定同样对照原始 legado：
//   · `##` 替换链 → `SourceRule.makeUpRule`
//     （`split("##")` 后 size>1 取 replaceRegex、>2 取 replacement、>3 置 replaceFirst）
//   · `@get:{key}` / `{{...}}` / `$1` → `SourceRule.init` + `evalPattern` + `splitRegex`
//   · 模式前缀 `@@` / `@XPath:` / `@Json:` / `.` 开头 → `SourceRule.init` 的 when 分支
//
// 本文件不依赖 Flutter。

import 'rule_analyzer.dart';

/// 规则的取数模式。
enum RuleMode {
  /// 空规则（legado 用空串表示「未配置」）。
  empty('空', '未配置'),

  /// CSS / jsoup 选择器（legado 的 `Mode.Default`）。
  css('css', 'CSS 选择器'),

  /// XPath（`Mode.XPath`）。
  xpath('xpath', 'XPath'),

  /// JSONPath（`Mode.Json`）。
  jsonPath('json', 'JSONPath'),

  /// 正则取数（`Mode.Regex`）。
  regex('regex', '正则'),

  /// JavaScript（`Mode.Js`）。
  js('js', 'JS'),

  /// 整段就是一个 `{{...}}` 模板。
  template('tpl', '模板'),

  /// `@get:{key}` 变量引用。
  variable('get', '@get 变量'),

  /// 纯字面量 / 裸标识符（无选择器特征）。
  /// 裸标识符，如 `kind`、`jj`、`fm`、`tags`。
  ///
  /// 依据原始 legado `AnalyzeRule.getString`：求值前先看内容类型 ——
  /// ```
  /// if (result is NativeObject) { … 按键直接访问 … }
  /// else if (result is LinkedTreeMap<*, *>) { result = result[rule.rule] }
  /// ```
  /// 内容是从 `init` JS 出来的 **map** 时，`kind` 是**键名**；
  /// 内容是 DOM 时才会落到 jsoup `select("kind")`。
  /// 同一串文本含义取决于内容类型，静态分析阶段只能标注、不能断言。
  identifier('bare', '裸标识符'),

  /// 字面量 / 常量文本。
  literal('text', '字面量');

  const RuleMode(this.code, this.label);

  /// 短标识，用于紧凑展示。
  final String code;

  /// 中文说明。
  final String label;
}

/// CSS 选择器后面的取数方式。
///
/// 白名单照着原始 legado 的 `AnalyzeByJSoup` / 参考实现的 `_parseCss`、`parseListRule`：
/// `text, html, textNodes, ownText, all, href, src, data-src, alt, title, class, id`。
enum RuleExtractor {
  /// 没有提取器 —— 直接取元素或元素文本。
  none('(元素)', '元素本身'),

  /// `@text`：元素文本。
  text('@text', '文本'),

  /// `@html`：元素内部 HTML（已去 script/style）。
  html('@html', 'HTML'),

  /// `@textNodes`：直接文本节点（不递归子元素）。
  textNodes('@textNodes', '文本节点'),

  /// `@ownText`：自身文本（不含子元素文本）。
  ownText('@ownText', '自身文本'),

  /// `@all`：整个元素的外层 HTML。
  all('@all', '全部 HTML'),

  /// 其他属性名，如 `@href` / `@src` / `@data-src`。
  attribute('@属性', '属性');

  const RuleExtractor(this.token, this.label);

  /// 规则里的写法。
  final String token;

  /// 中文说明。
  final String label;

  /// 按提取器名解析。[name] 不含 `@`。
  static RuleExtractor fromName(String name) {
    switch (name.trim().toLowerCase()) {
      case '':
        return RuleExtractor.none;
      case 'text':
        return RuleExtractor.text;
      case 'html':
        return RuleExtractor.html;
      case 'textnodes':
        return RuleExtractor.textNodes;
      case 'owntext':
        return RuleExtractor.ownText;
      case 'all':
        return RuleExtractor.all;
      default:
        return RuleExtractor.attribute;
    }
  }
}

/// `{{...}}` 模板里内容的分类。
///
/// 依据原始 legado `SourceRule.makeUpRule`：`{{}}` 里的内容**先判 [isRule]**，
/// 是规则就先当规则跑一遍，否则才交给 JS 引擎（`evalJS`）。
/// 索引筛选方式。
///
/// 依据原始 legado `AnalyzeByJSoup.findIndexSet` 的注释：
/// ```
/// 1. 支持阅读原有写法，':' 分隔索引，! 或 . 表示筛选方式，索引可为负数
/// 2. 支持与 jsonPath 类似的 [] 索引写法
///    格式形如 [it,it,...] 或 [!it,it,...] 其中 [! 开头表示筛选方式为排除
/// ```
/// 也就是说 `!` **不是**「整条规则取反」，而是「这批索引用来排除元素」，
/// 它只出现在索引块里，和 `.` 是同一层级的对偶写法。
enum IndexFilter {
  /// 没有索引块。
  none('', '无索引'),

  /// `.` / `:` / `[` 开头：按索引**选出**元素。
  select('.', '选择'),

  /// `!` / `[!` 开头：按索引**排除**元素。
  exclude('!', '排除');

  const IndexFilter(this.token, this.label);

  final String token;
  final String label;
}

/// 列表规则的顺序修饰前缀。
///
/// 依据原始 legado `BookList.kt:90` / `BookChapterList.kt:54` / `RssParserByRule.kt:49`
/// —— 这段处理发生在调用 `analyzeRule.getElements()` **之前**，剥掉前缀后才把
/// 剩下的规则串交给规则引擎：
/// ```
/// if (ruleList.startsWith("-")) { reverse = true; ruleList = ruleList.substring(1) }
/// if (ruleList.startsWith("+")) { ruleList = ruleList.substring(1) }
/// ```
/// 所以 `-` 属于「列表规则」这一层，而不是某一段选择器的一部分。
/// 本次的绅士漫画源 `ruleToc.chapterList = "-<js>…</js>"` 正好用到它。
enum ListOrderModifier {
  /// 没写前缀。
  none('', '默认顺序'),

  /// `-` 前缀：取完元素后反转。
  ///
  /// 注意方向 —— legado 的正文列表（`BookChapterList`）默认**会**反转，
  /// 写了 `-` 反而**不**反转；书籍列表（`BookList`）正相反，写了 `-` 才反转。
  reverse('-', '反转（legado 里列表与目录的反转方向相反）'),

  /// `+` 前缀：显式声明「不要反转」。
  explicit('+', '显式不反转');

  const ListOrderModifier(this.token, this.label);

  final String token;
  final String label;
}

/// `{{...}}` 模板里那一坨内容的性质。
enum TemplateKind {
  /// 裸标识符，像变量名（如 `{{page}}`、`{{key}}`）。
  variable('变量'),

  /// 内容本身是一条规则 —— `@` / `$.` / `$[` / `//` 开头（如 `{{@@img@src}}`）。
  /// legado 会把它当规则求值，而不是当 JS。
  rule('内嵌规则'),

  /// 其余，按 JS 表达式处理（如 `{{surl()}}`、`{{java.base64Encode(key)}}`）。
  js('JS 表达式');

  const TemplateKind(this.label);

  /// 中文说明。
  final String label;
}

/// 一个 `{{...}}` 模板。
class RuleTemplate {
  const RuleTemplate({required this.content, required this.kind});

  /// 花括号内的原文（已 trim）。
  final String content;

  /// 静态猜测的分类。
  final TemplateKind kind;

  /// 还原成规则里的写法。
  String get raw => '{{$content}}';

  /// 对应 legado `SourceRule.isRule`：
  /// `ruleStr.startsWith('@') || startsWith("$.") || startsWith("$[") || startsWith("//")`
  static bool isRuleContent(String content) {
    final String c = content.trim();
    return c.startsWith('@') ||
        c.startsWith(r'$.') ||
        c.startsWith(r'$[') ||
        c.startsWith('//');
  }

  /// 分类：先判是不是规则，再看是不是裸标识符，最后归为 JS。
  factory RuleTemplate.fromContent(String content) {
    final String trimmed = content.trim();
    if (isRuleContent(trimmed)) {
      return RuleTemplate(content: trimmed, kind: TemplateKind.rule);
    }
    if (RegExp(r'^[\w\u4e00-\u9fa5]+$').hasMatch(trimmed)) {
      return RuleTemplate(content: trimmed, kind: TemplateKind.variable);
    }
    return RuleTemplate(content: trimmed, kind: TemplateKind.js);
  }

  @override
  String toString() => '$raw(${kind.label})';
}

/// 一条规则拆出的单段结构（**不含** JS 段，JS 已由 [RuleStage] 独立承载）。
class RuleSegment {
  const RuleSegment({
    required this.raw,
    required this.mode,
    this.forced = false,
    this.indexFilter = IndexFilter.none,
    this.indexExpression,
    this.subject = '',
    this.selectorChain = const <String>[],
    this.extractor = RuleExtractor.none,
    this.attributeName,
    this.index,
    this.regexSource,
    this.replaceRegex,
    this.replacement,
    this.replaceFirst = false,
    this.templates = const <RuleTemplate>[],
    this.variableRefs = const <String>[],
    this.putRefs = const <String>[],
    this.groupRefs = const <int>[],
    this.legacyPrefix,
    this.notes = const <String>[],
  });

  /// 段原文（`RuleAnalyzer` 拆分后的原样切片）。
  final String raw;

  /// 取数模式。
  final RuleMode mode;

  /// 是否用了 `@XPath:` / `@Json:` / `@@` 这类强制/转义前缀。
  final bool forced;

  /// 索引的筛选方式（`选择` / `排除`）。
  ///
  /// 只在 CSS（jsoup）模式下有意义 —— XPath / JSONPath 的方括号属于表达式自身，
  /// 由各自的解析器处理，legado 不会去拆。
  final IndexFilter indexFilter;

  /// 索引表达式原文（已去掉前置分隔符），如 `0`、`-1`、`0,2`、`1-5:2`、`!1,3`。
  final String? indexExpression;

  /// 去掉替换链与模板后的规则主体。
  final String subject;

  /// 元素选择器链（按 `@` 拆开，如 `id.list@tag.dd` → `['id.list', 'tag.dd']`）。
  final List<String> selectorChain;

  /// 末尾的取数方式。
  final RuleExtractor extractor;

  /// [extractor] 为 [RuleExtractor.attribute] 时的属性名。
  final String? attributeName;

  /// [indexExpression] 是「单个整数」时的数值（可为负），否则为 null。
  ///
  /// legado 的索引远不止单个整数（支持集合、区间、步长、排除），
  /// 完整语义请看 [indexExpression]；这个字段只是给展示用的快捷值。
  final int? index;

  /// [RuleMode.regex] 时的正则原文（已去掉开头的 `:`）。
  final String? regexSource;

  /// 替换链第 2 段：匹配用的正则。
  final String? replaceRegex;

  /// 替换链第 3 段：替换成的文本，支持 `$1` 分组引用。
  final String? replacement;

  /// 替换链是否带尾部 `###`（只替换第一处）。
  final bool replaceFirst;

  /// 段内出现的 `{{...}}` 模板。
  final List<RuleTemplate> templates;

  /// `@get:{key}` 引用的变量名。
  final List<String> variableRefs;

  /// `@put:{...}` 写入的变量名。
  final List<String> putRefs;

  /// `$1` / `$2` 分组引用序号。
  final List<int> groupRefs;

  /// 老式 jsoup 前缀：`class.` / `id.` / `tag.` / `children.` / `text.`。
  final String? legacyPrefix;

  /// 解析过程中发现的可疑点（人话，直接可展示）。
  final List<String> notes;

  /// 这一段是否含 JS 相关成分（模板里含 JS 表达式）。
  bool get usesJs =>
      templates.any((RuleTemplate t) => t.kind == TemplateKind.js);

  /// 这一段是否含模板。
  bool get hasTemplates => templates.isNotEmpty;

  /// 是否有替换链。
  bool get hasReplace => replaceRegex != null;

  /// 替换链的原文写法，便于展示。
  String get replaceChain {
    if (!hasReplace) return '';
    final StringBuffer buffer = StringBuffer('##$replaceRegex');
    if (replacement != null) buffer.write('##$replacement');
    if (replaceFirst) buffer.write('#');
    return buffer.toString();
  }

  @override
  String toString() => 'RuleSegment(${mode.code}: $raw)';

  /// 解析一段（非 JS）规则。
  factory RuleSegment.fromString(String raw) {
    final List<String> notes = <String>[];
    String working = raw.trim();

    // ---- `!` 的语义澄清 ----
    // 这里**不**把行首 `!` 当「整条规则取反」。原始 legado 的 `findIndexSet` 里
    // `!` 是索引块的分隔符（`!` = 排除这批索引，`.` = 选出这批索引），
    // 也就是 `a.0!2` 这种写法。把它当整规则取反会得出错误结论。
    // 行首 `!` 交给下面的索引块解析处理。

    // ---- 模式前缀：严格照原始 legado `SourceRule.init` 的 when 顺序 ----
    bool forced = false;
    RuleMode? prefixMode;
    String lower = working.toLowerCase();

    if (lower.startsWith('@css:')) {
      // legado 这里把 mode 设回 Default，但**不剥掉 `@CSS:` 前缀**
      // （后续 `RuleAnalyzer.trim()` 会吃掉首个 `@`，于是变成 `CSS:div.a`）。
      // 原始行为如此，这里只标注、不做「修正」。
      forced = true;
      working = working.substring(5).trim();
      notes.add('`@CSS:` 强制前缀：legado 会保留该前缀，最终由拆分器吃掉首个 `@`');
    } else if (working.startsWith('@@')) {
      forced = true;
      working = working.substring(2).trim();
      notes.add('`@@` 转义前缀：强制按 JSoup Default 模式解析');
    } else if (lower.startsWith('@xpath:')) {
      forced = true;
      prefixMode = RuleMode.xpath;
      working = working.substring(7).trim();
    } else if (lower.startsWith('@json:')) {
      forced = true;
      prefixMode = RuleMode.jsonPath;
      working = working.substring(6).trim();
    } else if (lower.startsWith('@js:')) {
      // 正常流程里 JS 已被 `RuleStage` 切走，走到这里说明是异常输入
      prefixMode = RuleMode.js;
      working = working.substring(4).trim();
    }

    // ---- `##` 替换链：照原始 legado `makeUpRule`（size>1 就取，不等 3）----
    String? replaceRegex;
    String? replacement;
    bool replaceFirst = false;
    String subject = working;
    if (working.contains('##')) {
      final List<String> pieces = working.split('##');
      subject = pieces[0];
      if (pieces.length > 1) replaceRegex = pieces[1];
      if (pieces.length > 2) replacement = pieces[2];
      // 尾部 `###` 会多切出一段（通常是一个孤立的 `#`），表示「只替换第一处」
      if (pieces.length > 3) replaceFirst = true;
      if (pieces.length > 3 && replacement != null && pieces[2].isNotEmpty) {
        notes.add('替换链尾部带 `###`：只替换第一处匹配');
      }
    }

    // ---- `@get:{key}` 变量引用 ----
    final List<String> variableRefs = <String>[];
    for (final RegExpMatch match
        in RegExp(r'@get:\s*\{([^}]*)\}').allMatches(subject)) {
      final String key = match.group(1)?.trim() ?? '';
      if (key.isNotEmpty) variableRefs.add(key);
    }

    // ---- `@put:{key:value}` 变量写入 ----
    final List<String> putRefs = <String>[];
    for (final RegExpMatch match
        in RegExp(r'@put:\s*\{([^}]+?)\}').allMatches(subject)) {
      final String body = match.group(1)?.trim() ?? '';
      if (body.isNotEmpty) {
        putRefs.add(body.split(':').first.trim());
      }
    }

    // ---- `$1` / `$2` 分组引用 ----
    //
    // 既可能出现在规则主体里（较少），也可能出现在替换链的**替换文本**里
    // （常见：`##^(\d+)##$1张图###`）。刻意不扫 `replaceRegex` ——
    // 那里的 `$` 是正则的「行尾」锚点，不是分组引用。
    final List<int> groupRefs = <int>[];
    for (final RegExpMatch match
        in RegExp(r'\$(\d{1,2})').allMatches('$subject ${replacement ?? ''}')) {
      final int? n = int.tryParse(match.group(1) ?? '');
      if (n != null && n > 0 && !groupRefs.contains(n)) groupRefs.add(n);
    }

    // ---- `{{...}}` 模板 ----
    final List<RuleTemplate> templates = <RuleTemplate>[];
    for (final RegExpMatch match
        in RegExp(r'\{\{([\w\W]*?)\}\}').allMatches(subject)) {
      final String content = match.group(1)?.trim() ?? '';
      if (content.isNotEmpty) {
        templates.add(RuleTemplate.fromContent(content));
      }
    }

    // ---- 模式判定 ----
    RuleMode mode = prefixMode ?? _detectMode(subject);

    // ---- 选择器 / 提取器 / 索引 / 老前缀 ----
    RuleExtractor extractor = RuleExtractor.none;
    String? attributeName;
    int? index;
    String? legacyPrefix;
    IndexFilter indexFilter = IndexFilter.none;
    String? indexExpression;
    List<String> selectorChain = const <String>[];

    if (mode == RuleMode.css ||
        mode == RuleMode.xpath ||
        mode == RuleMode.jsonPath) {
      final _SelectorParse parsed = _parseSelector(subject, allowIndex: mode == RuleMode.css);
      extractor = parsed.extractor;
      attributeName = parsed.attributeName;
      index = parsed.index;
      indexFilter = parsed.indexFilter;
      indexExpression = parsed.indexExpression;
      legacyPrefix = parsed.legacyPrefix;
      selectorChain = parsed.chain;

      if (legacyPrefix != null) {
        notes.add('老式元素写法 `$legacyPrefix`：${_legacyPrefixDetail[legacyPrefix]}');
      }

      if (indexExpression != null) {
        if (!RegExp(r'^-?\d+$').hasMatch(indexExpression)) {
          notes.add('索引表达式 `$indexExpression`：legado 支持索引集合/区间/步长'
              '（如 `[0,2]`、`[1-5:2]`、`!1` 排除），这里只做结构标注，不展开求值');
        }
        if (selectorChain.isEmpty) {
          notes.add('索引直接作为根元素 —— legado 把前置规则为空的情况等价于 '
              '`children`，即从当前节点的直接子元素里取');
        }
      }
      if (mode != RuleMode.css) {
        notes.add(mode == RuleMode.xpath
            ? 'XPath 模式的方括号属于表达式自身，legado 不拆分索引'
            : 'JSONPath 模式的方括号属于表达式自身，legado 不拆分索引');
      }
    } else if (mode == RuleMode.identifier) {
      // 裸标识符：内容类型决定了它是对象键名还是标签选择器，静态阶段只能标注。
      selectorChain = <String>[subject.trim()];
      notes.add('裸标识符 `$subject`：内容来自 `init` JS 的对象（map）时，legado 按'
          '**键名**直接取值（`AnalyzeRule.getString` 里的 `LinkedTreeMap` 分支）；'
          '内容是 DOM 时才会走 jsoup 选择器 —— 它是标签名吗？'
          '${isHtmlTagName(subject) ? '是，按标签选择器解析' : '不是，多半是 init JS 写入的键名'}');
    } else if (mode == RuleMode.regex) {
      if (subject.startsWith(':')) subject = subject.substring(1).trim();
      if (subject.contains('&&')) {
        notes.add('正则模式内部用 `&&` 串联多条正则 —— 这些 `&&` 属于规则语义，不是组合符');
      }
    }

    return RuleSegment(
      raw: raw,
      mode: mode,
      forced: forced,
      indexFilter: indexFilter,
      indexExpression: indexExpression,
      subject: subject.trim(),
      selectorChain: selectorChain,
      extractor: extractor,
      attributeName: attributeName,
      index: index,
      regexSource: mode == RuleMode.regex ? subject.trim() : null,
      replaceRegex: replaceRegex,
      replacement: replacement,
      replaceFirst: replaceFirst,
      templates: templates,
      variableRefs: variableRefs,
      putRefs: putRefs,
      groupRefs: groupRefs,
      legacyPrefix: legacyPrefix,
      notes: List<String>.unmodifiable(notes),
    );
  }

  /// 按原始 legado `SourceRule.init` 的分支判定模式。
  ///
  /// 刻意**不**复刻 `init` 里那段 `evalPattern` 触发的 `Mode.Regex` 推断 ——
  /// 那段逻辑会让 `.info@text{{x}}` 这类规则被误判成正则模式，属遗留分支；
  /// 正则模式只按「`:` 开头且不是伪类」认定（对应 legado 的 allInOne 判定）。
  static RuleMode _detectMode(String subject) {
    final String s = subject.trim();
    if (s.isEmpty) return RuleMode.empty;

    // 整段就是一个 `{{...}}` 模板
    if (s.startsWith('{{')) return RuleMode.template;

    final String lower = s.toLowerCase();
    if (lower.startsWith('@get:')) return RuleMode.variable;

    // 以 `:` 开头，但要排除 `:first-child` 这类伪类
    if (s.startsWith(':') && s.length > 1) {
      final String afterColon = s.substring(1).trim();
      final bool isPseudoClass =
          afterColon.isNotEmpty && RegExp(r'^[a-zA-Z-]').hasMatch(afterColon);
      if (!isPseudoClass) return RuleMode.regex;
    }

    // legado：`$.` / `$[` → Json；`/` 开头 → XPath
    if (s.startsWith(r'$.') || s.startsWith(r'$[')) return RuleMode.jsonPath;
    if (s.startsWith('/')) return RuleMode.xpath;

    // legado 的 `children` 关键字是按 `beforeRule.split(".")[0]` 比的，所以裸写也生效
    if (_legacyKeywords.contains(s)) return RuleMode.css;

    if (_looksLikeSelector(s)) return RuleMode.css;
    if (RegExp(r'^[\w\u4e00-\u9fa5]+$').hasMatch(s)) return RuleMode.identifier;
    return RuleMode.literal;
  }

  /// 判断一串文本是否「像选择器」。
  ///
  /// 真实书源里 `fm` / `jj` / `tags` / `kind` 这种裸标识符是**对象键名或变量名**
  /// （由 `init` JS 写入），不是标签选择器；把它们当 CSS 会得出误导性的结论。
  ///
  /// 但 `h1` / `div` / `p` 这类**合法 HTML 标签名**同样是裸标识符，它们是货真价实的选择器。
  /// 所以裸标识符必须先过一遍标签名白名单，不能一刀切。
  static bool _looksLikeSelector(String s) {
    final RegExp bare = RegExp(r'^[\w\u4e00-\u9fa5]+$');
    if (bare.hasMatch(s)) return _htmlTags.contains(s.toLowerCase()); // 裸标识符
    // 字面 URL 片段，如 `https:{{@@img@src}},{headers:{...}}`
    // 注意 `https:` 后面不一定有 `//`，不能只判 `^https?://`。
    if (RegExp(r'^https?:', caseSensitive: false).hasMatch(s)) return false;
    return true;
  }

  /// 判断一串裸标识符是否是合法 HTML 标签名（用于区分标签选择器与对象键名）。
  static bool isHtmlTagName(String s) => _htmlTags.contains(s.toLowerCase());

  /// HTML 标签名白名单。
  ///
  /// 刻意写死而不是引入完整 HTML 规范表 —— 目的是**消歧**，不是做校验：
  /// 落在表里的一律当选择器，落在表外的一律标注为「裸标识符」交给人工确认。
  static const Set<String> _htmlTags = <String>{
    'a', 'abbr', 'address', 'area', 'article', 'aside', 'audio', 'b', 'base',
    'bdi', 'bdo', 'big', 'blockquote', 'body', 'br', 'button', 'canvas',
    'caption', 'center', 'cite', 'code', 'col', 'colgroup', 'data',
    'datalist', 'dd', 'del', 'details', 'dfn', 'dialog', 'div', 'dl', 'dt',
    'em', 'embed', 'fieldset', 'figcaption', 'figure', 'font', 'footer',
    'form', 'frame', 'frameset', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'head',
    'header', 'hgroup', 'hr', 'html', 'i', 'iframe', 'img', 'input', 'ins',
    'kbd', 'label', 'legend', 'li', 'link', 'main', 'map', 'mark', 'marquee',
    'menu', 'meta', 'meter', 'nav', 'noscript', 'object', 'ol', 'optgroup',
    'option', 'output', 'p', 'param', 'picture', 'pre', 'progress', 'q', 'rp',
    'rt', 'ruby', 's', 'samp', 'script', 'section', 'select', 'slot', 'small',
    'source', 'span', 'strike', 'strong', 'style', 'sub', 'summary', 'sup',
    'table', 'tbody', 'td', 'template', 'textarea', 'tfoot', 'th', 'thead',
    'time', 'title', 'tr', 'track', 'tt', 'u', 'ul', 'var', 'video', 'wbr',
  };

  /// 解析选择器：拆出提取器、索引、老前缀与元素链。
  static _SelectorParse _parseSelector(String subject, {required bool allowIndex}) {
    String selectorPart = subject.trim();
    RuleExtractor extractor = RuleExtractor.none;
    String? attributeName;

    // 末尾的 `@xxx` 若是已知取数名，则整体是「选择器 + 提取器」；
    // 否则按元素选择器链处理（参考实现 parseListRule 的判断）。
    final int at = selectorPart.lastIndexOf('@');
    if (at > 0 && at < selectorPart.length - 1) {
      final String after = selectorPart.substring(at + 1).trim().toLowerCase();
      if (_extractorNames.contains(after)) {
        extractor = RuleExtractor.fromName(after);
        attributeName = extractor == RuleExtractor.attribute ? after : null;
        selectorPart = selectorPart.substring(0, at).trim();
      }
    }

    // 索引（仅 CSS 模式）：`img.0`、`li[0]`、`a.-1`、`[!0,2]`、`[1-5:2]` …
    IndexFilter indexFilter = IndexFilter.none;
    String? indexExpression;
    int? index;
    if (allowIndex) {
      final _IndexBlock? block = _parseIndexBlock(selectorPart);
      if (block != null) {
        indexFilter = block.filter;
        indexExpression = block.expression;
        index = RegExp(r'^-?\d+$').hasMatch(block.expression)
            ? int.tryParse(block.expression)
            : null;
        selectorPart = selectorPart.substring(0, block.start).trim();
      }
    }

    final List<String> chain = extractor == RuleExtractor.none
        ? selectorPart
            .split('@')
            .map((String p) => p.trim())
            .where((String p) => p.isNotEmpty)
            .toList(growable: false)
        : <String>[selectorPart];

    return _SelectorParse(
      extractor: extractor,
      attributeName: attributeName,
      index: index,
      indexFilter: indexFilter,
      indexExpression: indexExpression,
      legacyPrefix: _legacyPrefixOf(selectorPart),
      chain: chain,
    );
  }

  /// 索引块允许出现的字符。
  ///
  /// `,` 分隔集合元素，`-` 是负数或区间，`:` 是步长分隔符，`!` 是排除标记，
  /// `[` `]` 是 jsonPath 风格的索引括号。
  static const String _indexChars = '0123456789- ,:!.[]';

  /// 从选择器尾部剥出索引块；没有则返回 null。
  ///
  /// 判定规则（对着 legado `findIndexSet` 的逆向扫描写的）：
  ///   1. 从尾部往前吃 [_indexChars]，且这一段必须**含数字**；
  ///   2. 这一段的**首字符必须是分隔符**（`.` / `!` / `:` / `[`），
  ///      否则说明这些数字属于选择器本身（`h1`、`.class-2`、`li:nth-child(2)`），
  ///      不能当索引。
  ///
  /// 刻意不做「求值」—— 只把原文与筛选方式交出来，因为 legado 的索引集合
  /// 语义很绕（多组索引会从右往左依次应用），静态分析阶段不该假装算得出来。
  static _IndexBlock? _parseIndexBlock(String selector) {
    final String s = selector.trim();
    if (s.isEmpty) return null;

    int i = s.length;
    bool hasDigit = false;
    while (i > 0) {
      final String ch = s[i - 1];
      if (!_indexChars.contains(ch)) break;
      final int code = ch.codeUnitAt(0);
      if (code >= 0x30 && code <= 0x39) hasDigit = true;
      i--;
    }
    if (!hasDigit || i == s.length) return null;

    final String run = s.substring(i);
    // 整段都是索引是合法的（legado：前置规则为空等价于 children），
    // 此时 run 必然以分隔符开头，下面的判断同样成立。
    final String lead = run[0];

    if (lead == '[') {
      // jsonPath 风格：`[it,it]` 或 `[!it,it]`
      if (!run.endsWith(']') || run.length < 3) return null;
      String inner = run.substring(1, run.length - 1).trim();
      IndexFilter filter = IndexFilter.select;
      if (inner.startsWith('!')) {
        filter = IndexFilter.exclude;
        inner = inner.substring(1).trim();
      }
      if (inner.isEmpty) return null;
      return _IndexBlock(
        start: i,
        filter: filter,
        expression: inner,
      );
    }

    if (lead == '.' || lead == '!' || lead == ':') {
      final String expression = run.substring(1).trim();
      if (expression.isEmpty) return null;
      // 排除只在 `!` 时才成立；`.` / `:` 都是「选出」。
      return _IndexBlock(
        start: i,
        filter: lead == '!' ? IndexFilter.exclude : IndexFilter.select,
        expression: expression,
      );
    }

    return null;
  }

  /// 参考实现与原始 legado 一致的属性名白名单。
  static const Set<String> _extractorNames = <String>{
    'text', 'html', 'textnodes', 'owntext', 'all',
    'href', 'src', 'data-src', 'alt', 'title', 'class', 'id',
  };

  /// 老式元素写法的准确含义。
  ///
  /// 依据原始 legado `AnalyzeByJSoup.ElementsSingle.getElementsSingle`：
  /// ```
  /// val rules = beforeRule.split(".")
  /// when (rules[0]) {
  ///     "children" -> temp.children()
  ///     "class"    -> temp.getElementsByClass(rules[1])
  ///     "tag"      -> temp.getElementsByTag(rules[1])
  ///     "id"       -> Collector.collect(Evaluator.Id(rules[1]), temp)
  ///     "text"     -> temp.getElementsContainingOwnText(rules[1])
  ///     else       -> temp.select(beforeRule)
  /// }
  /// ```
  /// 注意 `text.` **不是**「取文本」——`@text` 才是取文本；`text.abc` 是
  /// 「自身文本包含 abc 的元素」。这两个最容易搞混。
  static const Map<String, String> _legacyPrefixDetail = <String, String>{
    'children.':
        '取当前节点的**直接子元素**（等价于 `>` 一步），后面跟的选择器会被忽略',
    'children':
        '取当前节点的**直接子元素**（等价于 `>` 一步），后面跟的选择器会被忽略',
    'class.': '按 class 选择（`temp.getElementsByClass`），等价于 `.abc`',
    'tag.': '按标签名选择（`temp.getElementsByTag`），等价于 `abc`',
    'id.': '按 id 选择（`Evaluator.Id`），等价于 `#abc`',
    'text.':
        '⚠️ 不是「取文本」——`text.abc` 是「**自身文本包含** abc 的元素」；取文本要用 `@text`',
  };

  /// 老式 jsoup 前缀。
  static String? _legacyPrefixOf(String selector) {
    for (final String prefix in _legacyPrefixes) {
      if (selector.startsWith(prefix)) return prefix;
    }
    for (final String keyword in _legacyKeywords) {
      if (selector == keyword) return keyword;
    }
    return null;
  }

  static const List<String> _legacyPrefixes = <String>[
    'class.', 'id.', 'tag.', 'children.', 'text.',
  ];

  /// 不带点号的独立关键字。
  static const List<String> _legacyKeywords = <String>['children'];
}

/// [_SelectorParse] 的内部结果容器。
class _SelectorParse {
  const _SelectorParse({
    required this.extractor,
    required this.attributeName,
    required this.index,
    required this.indexFilter,
    required this.indexExpression,
    required this.legacyPrefix,
    required this.chain,
  });

  final RuleExtractor extractor;
  final String? attributeName;
  final int? index;
  final IndexFilter indexFilter;
  final String? indexExpression;
  final String? legacyPrefix;
  final List<String> chain;
}

/// 索引块的解析结果。
class _IndexBlock {
  const _IndexBlock({
    required this.start,
    required this.filter,
    required this.expression,
  });

  /// 索引块在选择器串里的起始下标（链表部分 = `[0, start)`）。
  final int start;

  /// 筛选方式。
  final IndexFilter filter;

  /// 索引表达式原文（不含前置分隔符与 `[]`）。
  final String expression;
}

/// 一个执行阶段。
///
/// legado 的 `splitSourceRule` 按 JS 正则把规则串切成有序段，所以一条规则天然是
/// 「普通段 → JS 段 → 普通段 …」这样的序列。段与段之间是**顺序执行**：
/// 前一段的结果作为后一段的输入。
class RuleStage {
  const RuleStage({
    required this.raw,
    required this.isJs,
    this.isWebJs = false,
    this.jsCode,
    this.combinator = RuleCombinator.none,
    this.segments = const <RuleSegment>[],
    this.notes = const <String>[],
  });

  /// 阶段原文。
  final String raw;

  /// 是否是 JS 阶段。
  final bool isJs;

  /// 是否是 `@webjs:`（把 JS 交给 WebView 执行）。
  final bool isWebJs;

  /// [isJs] 为真时的 JS 代码。
  final String? jsCode;

  /// 普通阶段的组合方式（JS 阶段恒为 [RuleCombinator.none]）。
  final RuleCombinator combinator;

  /// 普通阶段按组合符拆出的各段。
  final List<RuleSegment> segments;

  /// 该阶段的可疑点。
  final List<String> notes;

  @override
  String toString() => isJs
      ? 'RuleStage(js: ${jsCode?.length ?? 0} 字符)'
      : 'RuleStage(${combinator.token.isEmpty ? '单条' : combinator.token}, '
          '${segments.length} 段)';
}

/// 一整条规则的解析结果。
class ParsedSourceRule {
  const ParsedSourceRule({
    required this.raw,
    required this.stages,
    this.body = '',
    this.isListRule = false,
    this.listOrder = ListOrderModifier.none,
    this.listOrderNote,
  });

  /// 规则原文（含被剥掉的列表顺序前缀）。
  final String raw;

  /// 剥掉列表顺序前缀后的规则串 —— 真正交给规则引擎的那一份。
  final String body;

  /// 是否按「列表规则」解析（用 [ParsedSourceRule.parseList] 时才为真）。
  final bool isListRule;

  /// 列表规则的顺序修饰前缀（`-` / `+`）。
  ///
  /// 只有 [isListRule] 为真时才有意义。
  final ListOrderModifier listOrder;

  /// 顺序修饰带来的说明（非列表规则或无前缀时为 null）。
  final String? listOrderNote;

  /// 有序执行阶段。
  final List<RuleStage> stages;

  /// 全部普通段（跨阶段摊平）。
  List<RuleSegment> get segments => <RuleSegment>[
        for (final RuleStage stage in stages) ...stage.segments,
      ];

  /// 是否用到 JS（含 JS 阶段或含 JS 模板）。
  bool get usesJs =>
      stages.any((RuleStage s) => s.isJs) ||
      segments.any((RuleSegment s) => s.usesJs);

  /// 是否含 `{{...}}` 模板。
  bool get hasTemplates => segments.any((RuleSegment s) => s.hasTemplates);

  /// 是否含替换链。
  bool get hasReplaceChain => segments.any((RuleSegment s) => s.hasReplace);

  /// 是否是「先普通规则、再交给 JS」的两段式。
  bool get isMixed =>
      stages.length > 1 && stages.any((RuleStage s) => !s.isJs);

  /// 各段的取数模式（去重、保持出现顺序）。
  List<RuleMode> get modes {
    final List<RuleMode> result = <RuleMode>[];
    for (final RuleSegment segment in segments) {
      if (segment.mode == RuleMode.empty) continue;
      if (!result.contains(segment.mode)) result.add(segment.mode);
    }
    return result;
  }

  /// 全部 JS 代码汇总。
  List<String> get jsBlocks => <String>[
        for (final RuleStage stage in stages)
          if (stage.isJs && (stage.jsCode ?? '').isNotEmpty) stage.jsCode!,
      ];

  /// 全部变量引用汇总。
  List<String> get variableRefs => <String>[
        for (final RuleSegment segment in segments) ...segment.variableRefs,
      ];

  /// 全部 `{{...}}` 模板汇总。
  List<RuleTemplate> get templates => <String, RuleTemplate>{
        for (final RuleSegment segment in segments)
          for (final RuleTemplate template in segment.templates)
            template.content: template,
      }.values.toList(growable: false);

  /// 全部可疑点汇总（规则级 → 阶段级）。
  List<String> get notes => <String>[
        ?listOrderNote,
        for (final RuleStage stage in stages) ...stage.notes,
      ];

  @override
  String toString() =>
      'ParsedSourceRule(${stages.length} 阶段, ${segments.length} 段)';

  /// legado 的 JS 切分正则。
  ///
  /// 照抄 `AppPattern.kt` 的两条正则，合并成一条交替式：
  ///   `JS_PATTERN    = <js>([\w\W]*?)</js>|@js:([\w\W]*)`
  ///   `WebJS_PATTERN = @webjs:([\w\W]{5,})`
  /// 合并是为了按**出现位置**统一排序 —— legado 分两趟扫，若 `@webjs:` 排在 `<js>` 之后
  /// 会出现段序错乱（真实书源里未见过，属防御性处理）。
  /// `@js:` 分支是贪婪到串尾的，与 legado 一致：`@js:` 之后不能再接别的规则。
  static final RegExp _jsSplitPattern = RegExp(
    r'<js>([\w\W]*?)</js>|@webjs:([\w\W]{5,})|@js:([\w\W]*)',
    caseSensitive: false,
  );

  /// 解析一条规则。**不抛异常** —— 脏规则退化成「单阶段、未配置」，不会炸掉整次导入。
  static ParsedSourceRule parse(String rule) =>
      _parse(rule, rule, ListOrderModifier.none);

  /// 解析一条**列表规则**（`ruleSearch.bookList` / `ruleExplore.bookList` /
  /// `ruleToc.chapterList` / RSS 的 `articles`）。
  ///
  /// 列表规则比普通规则多一层行首修饰，legado 在把规则交给规则引擎**之前**
  /// 先剥掉它（`BookList.kt` / `BookChapterList.kt` / `RssParserByRule.kt`）：
  /// ```
  /// if (rule.startsWith("-")) { reverse = true; rule = rule.substring(1) }
  /// if (rule.startsWith("+")) rule = rule.substring(1)
  /// ```
  /// 不剥的话，`-<js>…</js>` 里的 `-` 会被当成 CSS 选择器，结论就错了。
  static ParsedSourceRule parseList(String rule) {
    String body = rule.trim();
    ListOrderModifier order = ListOrderModifier.none;

    if (body.startsWith('-')) {
      order = ListOrderModifier.reverse;
      body = body.substring(1);
    }
    if (body.startsWith('+')) {
      body = body.substring(1);
      if (order == ListOrderModifier.none) {
        order = ListOrderModifier.explicit;
      }
    }

    final String? note = switch (order) {
      ListOrderModifier.none => null,
      ListOrderModifier.reverse =>
        '`-` 前缀：这是**列表规则**的顺序修饰（legado 剥掉它之后才交给规则引擎），'
            '不是选择器的一部分。目录列表（chapterList）默认会被反转，写 `-` 反而不反转；'
            '书籍列表（bookList）默认不反转，写 `-` 才反转 —— 两者方向相反。',
      ListOrderModifier.explicit =>
        '`+` 前缀：显式声明不要反转，同样在进入规则引擎前被剥掉。',
    };

    return _parse(rule, body, order, isListRule: true, note: note);
  }

  static ParsedSourceRule _parse(
    String raw,
    String body,
    ListOrderModifier listOrder, {
    bool isListRule = false,
    String? note,
  }) {
    final List<RuleStage> stages = <RuleStage>[];

    int cursor = 0;
    for (final RegExpMatch match in _jsSplitPattern.allMatches(body)) {
      // 先收下 JS 之前的普通文本
      if (match.start > cursor) {
        final String text = body.substring(cursor, match.start).trim();
        if (text.isNotEmpty) stages.add(_plainStage(text));
      }

      final String? jsTag = match.group(1);
      final String? webJs = match.group(2);
      final String? inlineJs = match.group(3);
      final String code = (jsTag ?? webJs ?? inlineJs ?? '').trim();
      final List<String> notes = <String>[];
      if (code.isEmpty) {
        notes.add('JS 段内容为空');
      }
      if (webJs != null) {
        notes.add('`@webjs:` 需要 WebView 执行，纯 Dart 侧无法跑');
      }
      stages.add(RuleStage(
        raw: match.group(0) ?? '',
        isJs: true,
        isWebJs: webJs != null,
        jsCode: code,
        notes: List<String>.unmodifiable(notes),
      ));

      cursor = match.end;
    }

    // 收尾：最后一段普通文本
    if (cursor < body.length) {
      final String text = body.substring(cursor).trim();
      if (text.isNotEmpty) stages.add(_plainStage(text));
    }

    // 整条规则既没有 JS 也没有普通段（理论上是空串）
    if (stages.isEmpty) {
      stages.add(_plainStage(body.trim()));
    }

    return ParsedSourceRule(
      raw: raw,
      body: body,
      isListRule: isListRule,
      listOrder: listOrder,
      listOrderNote: note,
      stages: List<RuleStage>.unmodifiable(stages),
    );
  }

  /// 把一个普通阶段按 `&&` / `||` / `%%` 拆成若干段。
  static RuleStage _plainStage(String text) {
    final RuleSplit split = RuleAnalyzer.splitRule(text);
    final List<String> notes = <String>[];

    if (split.parts.length == 1 &&
        (text.contains('&&') || text.contains('||') || text.contains('%%'))) {
      notes.add('出现了组合符但只拆出一段 —— 分隔符大概率落在括号/引号内部，'
          '被平衡扫描正确跳过了');
    }

    return RuleStage(
      raw: text,
      isJs: false,
      combinator: split.combinator,
      segments: split.parts
          .map((String part) => RuleSegment.fromString(part))
          .toList(growable: false),
      notes: List<String>.unmodifiable(notes),
    );
  }
}
