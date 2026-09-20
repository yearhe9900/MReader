// 书源详情页：基本信息 + 体检结论 + 字段级的结构展开。
//
// 这是「书源解析」的最终呈现面：把一条源从 JSON 一路拆到
// 「哪个字段、什么模式、用什么选择器、取哪个属性、替换链怎么配、哪里依赖 JS」。
// `hide DiagnosticLevel`：flutter/material.dart 里也有一个同名的
// foundation 枚举（`DiagnosticsNode` 用的），不藏起来会 ambiguous_import。
// 本页要的是书源体检的等级枚举。
import 'package:flutter/material.dart' hide DiagnosticLevel;

import '../../source/book_source.dart';
import '../../source/capability/capability.dart';
import '../../source/capability/capability_registry.dart';
import '../../source/capability/rule_evaluator.dart';
import '../../source/rule_analyzer.dart';
import '../../source/source_diagnostic.dart';
import '../../source/source_rule.dart';
import '../../source/url_rule.dart';

/// 书源详情页。
class SourceDetailPage extends StatelessWidget {
  const SourceDetailPage({
    super.key,
    required this.source,
    required this.diagnostic,
    this.capabilityRegistry,
  });

  /// 书源。
  final BookSource source;

  /// 已算好的体检结果（由列表页传入，避免每次 build 重算）。
  final SourceDiagnostic diagnostic;

  /// 本平台能力注册表。
  ///
  /// 可选：未注入时退化为 [CapabilityRegistry.fallback]（无引擎）。
  /// 由 `main.dart` 装配真实能力后逐层显式传递（本项目不使用全局单例）。
  final CapabilityRegistry? capabilityRegistry;

  @override
  Widget build(BuildContext context) {
    final List<ParsedField> configured = diagnostic.fields
        .where((ParsedField f) => f.isConfigured)
        .toList(growable: false);
    final CapabilityRegistry registry =
        capabilityRegistry ?? CapabilityRegistry.fallback();

    return Scaffold(
      appBar: AppBar(
        title: Text(source.displayName),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                source.bookSourceUrl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: <Widget>[
          _Section(
            title: '基本信息',
            child: _BasicInfo(source: source),
          ),
          _Section(
            title: '体检结论（${diagnostic.findings.length}）',
            child: Column(
              children: <Widget>[
                for (final DiagnosticFinding finding in diagnostic.findings)
                  _FindingTile(finding: finding),
              ],
            ),
          ),
          _Section(
            title: '本平台能力',
            subtitle: '第 1 层（源固有）+ 第 2 层（当前平台）合成结论',
            child: _PlatformCapabilityPanel(
              diagnostic: diagnostic,
              registry: registry,
            ),
          ),
          _Section(
            title: '能力（${diagnostic.capabilities.length}）',
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final SourceCapability capability
                    in diagnostic.capabilities)
                  _Tag(
                    text: capability.label,
                    tooltip: capability.detail,
                    tone: _capabilityTone(capability),
                  ),
              ],
            ),
          ),
          if (diagnostic.legadoApis.isNotEmpty)
            _Section(
              title: 'legado 私有 API（${diagnostic.legadoApis.length}）',
              subtitle: '这些符号只在 legado 运行期存在，Dart 侧要逐个提供等价实现',
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final String api in diagnostic.legadoApis)
                    _Tag(text: api, monospace: true),
                ],
              ),
            ),
          _Section(
            title: '字段明细（已配置 ${configured.length}/${diagnostic.fields.length}）',
            subtitle: '展开可看规则被拆成什么结构',
            child: Column(
              children: <Widget>[
                for (final ParsedField field in configured)
                  _FieldTile(field: field),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 能力标签的色调：越接近「需要额外引擎」越显眼。
  static _TagTone _capabilityTone(SourceCapability capability) {
    switch (capability) {
      case SourceCapability.js:
      case SourceCapability.webView:
      case SourceCapability.login:
      case SourceCapability.customProtocol:
        return _TagTone.warn;
      case SourceCapability.network:
      case SourceCapability.cookieJar:
        return _TagTone.neutral;
      case SourceCapability.css:
      case SourceCapability.xpath:
      case SourceCapability.jsonPath:
      case SourceCapability.regex:
      case SourceCapability.template:
      case SourceCapability.replaceChain:
      case SourceCapability.base64:
      case SourceCapability.hex:
      case SourceCapability.charset:
      case SourceCapability.concurrencyRate:
        return _TagTone.ok;
    }
  }
}

// ---------------------------------------------------------------------------
// 基本信息
// ---------------------------------------------------------------------------

class _BasicInfo extends StatelessWidget {
  const _BasicInfo({required this.source});

  final BookSource source;

  @override
  Widget build(BuildContext context) {
    final (int, int)? rate = source.parsedConcurrentRate;
    return Column(
      children: <Widget>[
        _InfoRow(label: '类型', value: '${source.bookSourceType.label}'
            '（bookSourceType=${source.bookSourceType.code}）'),
        _InfoRow(label: '主机', value: source.host.isEmpty ? '—' : source.host),
        _InfoRow(
          label: '分组',
          value: source.groups.isEmpty ? '—' : source.groups.join(' / '),
        ),
        _InfoRow(
          label: '启用',
          value: '源=${_onOff(source.enabled)}　'
              '发现=${_onOff(source.enabledExplore)}　'
              'Cookie=${_onOff(source.enabledCookieJar)}',
        ),
        _InfoRow(
          label: '并发',
          value: rate == null
              ? '—'
              : '${rate.$1} 并发 / ${rate.$2}ms 间隔',
        ),
        _InfoRow(label: '超时', value: '${source.respondTime} ms'),
        _InfoRow(label: '权重', value: '${source.weight}'),
        _InfoRow(label: '更新时间', value: _formatTime(source.lastUpdateTime)),
        if (source.bookSourceComment != null)
          _InfoRow(label: '备注', value: source.bookSourceComment!),
        if (source.extras.isNotEmpty)
          _InfoRow(label: '未建模键', value: source.extras.keys.join('、')),
      ],
    );
  }

  static String _onOff(bool value) => value ? '开' : '关';

  /// 毫秒时间戳转可读文本。刻意不引 intl —— 只为一行展示加一个依赖不划算。
  static String _formatTime(int millis) {
    if (millis <= 0) return '—';
    final DateTime time = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 64,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 体检结论
// ---------------------------------------------------------------------------

class _FindingTile extends StatelessWidget {
  const _FindingTile({required this.finding});

  final DiagnosticFinding finding;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final (IconData icon, Color color) = switch (finding.level) {
      DiagnosticLevel.blocker => (Icons.block_outlined, theme.colorScheme.error),
      DiagnosticLevel.warn => (Icons.warning_amber_outlined, theme.colorScheme.tertiary),
      DiagnosticLevel.info => (Icons.info_outline, theme.colorScheme.primary),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  finding.title,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  finding.detail,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 本平台能力
// ---------------------------------------------------------------------------

/// 「本平台能力」面板：把第 1 层（源固有）与第 2 层（平台相对）合成三态呈现。
///
/// · ✅ 可跑 —— 已配置字段全部可求值；
/// · ⚠️ 降级 —— 有依赖 JS 的字段在本平台不可用（纯规则字段仍可跑）；
/// · ❌ 不可用 —— 无脚本引擎且该源强依赖 JS。
class _PlatformCapabilityPanel extends StatelessWidget {
  const _PlatformCapabilityPanel({
    required this.diagnostic,
    required this.registry,
  });

  final SourceDiagnostic diagnostic;
  final CapabilityRegistry registry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool jsAvailable = registry.has(Capability.script);

    // 优先用体检时算好的平台结论；若详情页拿到的是第 1 层结果
    // （`inspect`，evaluations 为空），就地按注入的 registry 补算。
    final Map<ParsedField, FieldEvaluation> evaluations =
        diagnostic.evaluations.isNotEmpty
            ? diagnostic.evaluations
            : _evaluateAll(RuleEvaluator(registry), diagnostic.fields);

    int countOf(EvaluationOutcome outcome) => evaluations.values
        .where((FieldEvaluation e) => e.outcome == outcome)
        .length;

    final int jsUnavailable = countOf(EvaluationOutcome.jsUnavailable);
    final int jsRequired = countOf(EvaluationOutcome.jsRequired);
    final int staticOk = diagnostic.fields
        .where((ParsedField f) =>
            f.isConfigured &&
            evaluations[f]?.outcome == EvaluationOutcome.staticOk)
        .length;

    final (String overall, _TagTone tone) = switch ((
      jsUnavailable,
      jsRequired,
    )) {
      (> 0, _) => ('本平台降级：$jsUnavailable 个 JS 字段不可求值', _TagTone.warn),
      (_, > 0) => ('可跑：$jsRequired 个 JS 字段由本平台引擎执行', _TagTone.ok),
      _ => ('可跑：已配置字段均为纯静态求值', _TagTone.ok),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            _Tag(text: overall, tone: tone),
            _Tag(
              text: jsAvailable
                  ? '脚本引擎：${registry.script.label}'
                  : '脚本引擎：缺失',
              tone: jsAvailable ? _TagTone.ok : _TagTone.warn,
            ),
            _Tag(text: '静态可跑 $staticOk', tone: _TagTone.ok),
            if (jsUnavailable > 0)
              _Tag(text: '降级 $jsUnavailable', tone: _TagTone.warn),
            if (jsRequired > 0)
              _Tag(text: 'JS 可跑 $jsRequired', tone: _TagTone.ok),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          jsAvailable
              ? '本平台具备 JS 执行能力，依赖 JS 的字段可求值。'
              : '本平台无 JS 引擎：依赖 JS 的字段会降级，纯规则字段照常可跑。'
                  '请改用纯规则源，或切换到具备 JS 能力的平台。',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  /// 按注入的 registry 逐字段求平台结论。
  static Map<ParsedField, FieldEvaluation> _evaluateAll(
    RuleEvaluator evaluator,
    List<ParsedField> fields,
  ) =>
      <ParsedField, FieldEvaluation>{
        for (final ParsedField field in fields)
          field: evaluator.evaluate(field.toUsage()),
      };
}

// ---------------------------------------------------------------------------
// 字段明细
// ---------------------------------------------------------------------------

class _FieldTile extends StatelessWidget {
  const _FieldTile({required this.field});

  final ParsedField field;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ExpansionTile(
      dense: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 4),
      title: Row(
        children: <Widget>[
          SizedBox(
            width: 52,
            child: Text(
              field.groupLabel,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Row(
              children: <Widget>[
                Flexible(
                  child: Text(
                    field.fieldName,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (field.usesJs)
                  const _Tag(text: 'JS', tone: _TagTone.warn, dense: true),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(
              field.summary,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
      childrenPadding: const EdgeInsets.fromLTRB(12, 0, 4, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _LabeledBlock(label: '类型', child: Text(field.kind.detail)),
        _LabeledBlock(
          label: '原文',
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              field.raw,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        if (field.url != null)
          _LabeledBlock(label: 'URL 结构', child: _UrlStructure(url: field.url!)),
        if (field.rule != null)
          _LabeledBlock(
            label: '规则结构',
            child: _RuleStructure(rule: field.rule!),
          ),
      ],
    );
  }
}

/// URL 规则的结构展示。
class _UrlStructure extends StatelessWidget {
  const _UrlStructure({required this.url});

  final ParsedUrlRule url;

  @override
  Widget build(BuildContext context) {
    final UrlRequestOption? options = url.options;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _Kv(keyName: '类型', value: url.kind.label),
        if (url.template.isNotEmpty)
          _Kv(keyName: 'template', value: url.template),
        if (url.dataUriBase64 != null)
          _Kv(keyName: 'base64', value: url.dataUriBase64!),
        if (url.pageValues.isNotEmpty)
          _Kv(keyName: '页码模板', value: url.pageValues.join(' / ')),
        if (url.placeholders.isNotEmpty)
          _Kv(
            keyName: '占位符',
            value: url.placeholders
                .map((UrlPlaceholder p) => '${p.token} = ${p.label}')
                .join('\n'),
          ),
        if (url.jsCode != null)
          _Kv(keyName: 'js', value: url.jsCode!, monospace: true),
        if (options != null) ...<Widget>[
          _Kv(
            keyName: '选项',
            value: options.parsed ? '解析成功' : '解析失败（非标准 JSON）',
          ),
          if (options.method != null)
            _Kv(keyName: 'method', value: options.method!),
          if (options.charset != null)
            _Kv(keyName: 'charset', value: options.charset!),
          if (options.type != null)
            _Kv(keyName: 'type', value: options.type!),
          if (options.headers != null)
            _Kv(keyName: 'headers', value: options.headers!.toString()),
          if (options.retry != null)
            _Kv(keyName: 'retry', value: '${options.retry}'),
          if (options.specialNeeds.isNotEmpty)
            _Kv(keyName: '额外需要', value: options.specialNeeds.join('、')),
          if (!options.parsed && options.raw != null)
            _Kv(keyName: '选项原文', value: options.raw!, monospace: true),
        ],
        for (final String note in url.notes)
          _Note(text: note),
      ],
    );
  }
}

/// 源规则的结构展示：阶段 → 段 → 结构。
class _RuleStructure extends StatelessWidget {
  const _RuleStructure({required this.rule});

  final ParsedSourceRule rule;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _Kv(keyName: '阶段数', value: '${rule.stages.length}'),
        if (rule.isListRule)
          _Kv(keyName: '列表规则', value: '是（行首可带 - / + 顺序修饰）'),
        if (rule.listOrder != ListOrderModifier.none)
          _Kv(keyName: '顺序修饰', value: '${rule.listOrder.token}  ${rule.listOrder.label}'),
        if (rule.isListRule && rule.raw.trim() != rule.body.trim())
          _Kv(keyName: '交给规则引擎的串', value: rule.body, monospace: true),
        for (int i = 0; i < rule.stages.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: theme.dividerColor),
                borderRadius: BorderRadius.circular(6),
              ),
              child: _StageView(index: i, stage: rule.stages[i]),
            ),
          ),
        for (final String note in rule.notes) _Note(text: note),
      ],
    );
  }
}

/// 单个执行阶段的展示。
class _StageView extends StatelessWidget {
  const _StageView({required this.index, required this.stage});

  final int index;
  final RuleStage stage;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String head = stage.isJs
        ? '阶段 ${index + 1}：JS'
            '${stage.isWebJs ? '（@webjs，需 WebView）' : ''}'
        : '阶段 ${index + 1}：普通规则'
            '${stage.combinator == RuleCombinator.none ? '' : '（组合 ${stage.combinator.label}）'}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          head,
          style: theme.textTheme.labelMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (stage.isJs)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: SelectableText(
              stage.jsCode ?? '',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        for (int i = 0; i < stage.segments.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _SegmentView(index: i, segment: stage.segments[i]),
          ),
        for (final String note in stage.notes) _Note(text: note),
      ],
    );
  }
}

/// 单个组合段的展示。
class _SegmentView extends StatelessWidget {
  const _SegmentView({required this.index, required this.segment});

  final int index;
  final RuleSegment segment;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<Widget> rows = <Widget>[
      _Kv(keyName: '模式', value: segment.mode.label),
      if (segment.forced) _Kv(keyName: '前缀', value: '强制/转义模式前缀'),
      if (segment.legacyPrefix != null)
        _Kv(keyName: '老式前缀', value: segment.legacyPrefix!),
      if (segment.selectorChain.isNotEmpty)
        _Kv(keyName: '选择器', value: segment.selectorChain.join('  ▸  ')),
      if (segment.extractor != RuleExtractor.none)
        _Kv(
          keyName: '取数',
          value: segment.extractor == RuleExtractor.attribute
              ? '@${segment.attributeName}'
              : segment.extractor.token,
        ),
      if (segment.indexExpression != null)
        _Kv(
          keyName: '索引',
          value: '${segment.indexExpression}'
              '（${segment.indexFilter.label}）'
              '${segment.index != null ? ' → 第 ${segment.index} 个' : ''}',
        ),
      if (segment.regexSource != null)
        _Kv(keyName: '正则', value: segment.regexSource!, monospace: true),
      if (segment.hasReplace) ...<Widget>[
        _Kv(keyName: '替换 · 匹配', value: segment.replaceRegex!, monospace: true),
        if (segment.replacement != null)
          _Kv(keyName: '替换 · 换成', value: segment.replacement!, monospace: true),
        if (segment.replaceFirst) _Kv(keyName: '替换 · 范围', value: '只替换第一处'),
      ],
      if (segment.groupRefs.isNotEmpty)
        _Kv(
          keyName: '分组引用',
          value: segment.groupRefs.map((int g) => '\$$g').join('、'),
        ),
      if (segment.templates.isNotEmpty)
        _Kv(
          keyName: '模板',
          value: segment.templates
              .map((RuleTemplate t) => '${t.raw} → ${t.kind.label}')
              .join('\n'),
        ),
      if (segment.variableRefs.isNotEmpty)
        _Kv(keyName: '@get 变量', value: segment.variableRefs.join('、')),
      if (segment.putRefs.isNotEmpty)
        _Kv(keyName: '@put 变量', value: segment.putRefs.join('、')),
    ];

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '段 ${index + 1}',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          ...rows,
          for (final String note in segment.notes) _Note(text: note),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 小组件
// ---------------------------------------------------------------------------

/// 一个带标题的区块。
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.child,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                subtitle!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 8),
          child,
          const Divider(height: 24),
        ],
      ),
    );
  }
}

/// 键值一行。
class _Kv extends StatelessWidget {
  const _Kv({
    required this.keyName,
    required this.value,
    this.monospace = false,
  });

  final String keyName;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 88,
            child: Text(
              keyName,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: monospace
                  ? const TextStyle(fontFamily: 'monospace', fontSize: 11)
                  : theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// 提示行。
class _Note extends StatelessWidget {
  const _Note({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        '· $text',
        style: theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.tertiary),
      ),
    );
  }
}

/// 带小标题的块。
class _LabeledBlock extends StatelessWidget {
  const _LabeledBlock({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 3),
          DefaultTextStyle.merge(
            style: theme.textTheme.bodySmall ?? const TextStyle(),
            child: child,
          ),
        ],
      ),
    );
  }
}

/// 标签色调。
enum _TagTone { ok, neutral, warn }

/// 小标签。
class _Tag extends StatelessWidget {
  const _Tag({
    required this.text,
    this.tone = _TagTone.neutral,
    this.monospace = false,
    this.dense = false,
    this.tooltip,
  });

  final String text;
  final _TagTone tone;
  final bool monospace;
  final bool dense;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color background = switch (tone) {
      _TagTone.ok => theme.colorScheme.secondaryContainer,
      _TagTone.neutral => theme.colorScheme.surfaceContainerHighest,
      _TagTone.warn => theme.colorScheme.tertiaryContainer,
    };
    final Color foreground = switch (tone) {
      _TagTone.ok => theme.colorScheme.onSecondaryContainer,
      _TagTone.neutral => theme.colorScheme.onSurfaceVariant,
      _TagTone.warn => theme.colorScheme.onTertiaryContainer,
    };

    final Widget chip = Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 8,
        vertical: dense ? 1 : 3,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: (dense ? theme.textTheme.labelSmall : theme.textTheme.labelMedium)
            ?.copyWith(
          color: foreground,
          fontFamily: monospace ? 'monospace' : null,
        ),
      ),
    );

    if (tooltip == null) return chip;
    return Tooltip(message: tooltip!, child: chip);
  }
}
