// 规则组合拆分器。
//
// 对应 legado 的 `RuleAnalyzer.kt`，逐行对照参考实现的 Dart 移植版：
//   legado_flutter-2026/lib/utils/parsers/rule_analyzer.dart
// 算法（含递归结构、`_step`/`_startX` 的推进方式）保持一致，只为可读性改名与补注释。
//
// 为什么不能直接用 `String.split('&&')`：
//   legado 的规则串里，`&&` / `||` / `%%` 可能出现在**正则、JS 代码、字符串字面量、
//   CSS 属性选择器或 JSONPath 表达式内部**。例如：
//     · `$.data.list[?(@.id==1 && @.has)]`   —— JSONPath 里的 `&&` 是语法
//     · `//div[@class="a||b"]`                —— 属性值里的 `||`
//   裸 split 会在这些位置切开，把一条规则碎成几条废规则。
//
// 本拆分器靠**状态扫描**（跟踪引号开合 + `[`/`(` 括号平衡）只在顶层切分。
//
// 本文件不依赖 Flutter。

/// 规则组合方式。
enum RuleCombinator {
  /// 单条规则，没有组合。
  none('', '单条'),

  /// `&&`：与 —— 各段结果按 `\n` 竖向拼接。
  and('&&', '与'),

  /// `||`：或 —— 返回第一个非空结果。
  or('||', '或'),

  /// `%%`：交错 —— 用于「正则 + 取反」这类需要两条规则配合的场景。
  interleave('%%', '交错');

  const RuleCombinator(this.token, this.label);

  /// 规则串里的符号原文。
  final String token;

  /// 中文说明。
  final String label;

  static RuleCombinator fromToken(String token) {
    for (final RuleCombinator combinator in values) {
      if (combinator.token == token) return combinator;
    }
    return RuleCombinator.none;
  }
}

/// 一条规则的拆分结果。
class RuleSplit {
  const RuleSplit({required this.parts, required this.combinator});

  /// 拆分后的各段规则（原样切片，未做二次加工 —— 与 legado 一致）。
  final List<String> parts;

  /// 组合方式。拆分前不知道，拆完才知道。
  final RuleCombinator combinator;

  /// 是否是组合规则（多于一段）。
  bool get isCombined => parts.length > 1;

  /// 拆出的段数。
  int get length => parts.length;

  @override
  String toString() =>
      'RuleSplit(${combinator.token.isEmpty ? '单条' : combinator.token}, $parts)';
}

/// 按 legado 语义拆分规则串。
class RuleAnalyzer {
  /// 默认探测的分隔符。算法取**位置最靠前**的那个，不按数组顺序优先。
  static const List<String> _defaultSeparators = <String>['&&', '||', '%%'];

  RuleAnalyzer(this._queue);

  /// 被处理的规则串。
  final String _queue;

  int _pos = 0; // 当前扫描位置
  int _start = 0; // 当前字段开始位置
  int _startX = 0; // 当前规则开始位置
  int _step = 0; // 命中的分隔符长度
  String _elementsType = ''; // 命中的分隔符原文

  final List<String> _rule = <String>[];

  /// 修剪规则串开头的 `@` 与空白符。
  void _trim() {
    if (_pos >= _queue.length) return;
    if (_queue[_pos] == '@' || _queue[_pos].codeUnitAt(0) < 33) {
      _pos++;
      while (_pos < _queue.length &&
          (_queue[_pos] == '@' || _queue[_pos].codeUnitAt(0) < 33)) {
        _pos++;
      }
      _start = _pos;
      _startX = _pos;
    }
  }

  /// 把 `_pos` 重置为 0，便于复用同一个实例。
  void resetPos() {
    _pos = 0;
    _startX = 0;
  }

  /// 从剩余串中拉出一段，直到（不含）匹配序列。区分大小写。
  ///
  /// 命中时把段起点记在 `_start`，并把 `_pos` 移到匹配处。
  bool _consumeTo(String seq) {
    _start = _pos;
    final int offset = _queue.indexOf(seq, _pos);
    if (offset != -1) {
      _pos = offset;
      return true;
    }
    return false;
  }

  /// 从剩余串中拉出一段，直到（不含）任一匹配序列。命中时记录 `_step`。
  bool _consumeToAny(List<String> seq) {
    int pos = _pos;
    while (pos < _queue.length) {
      for (final String s in seq) {
        if (_queue.length - pos >= s.length &&
            _queue.substring(pos, pos + s.length) == s) {
          _step = s.length;
          _pos = pos;
          return true;
        }
      }
      pos++;
    }
    return false;
  }

  /// 从剩余串中找出任一目标字符的位置（用于定位筛选器 `[` / `(`）。
  int _findToAny(List<String> seq) {
    int pos = _pos;
    while (pos < _queue.length) {
      for (final String s in seq) {
        if (_queue[pos] == s) return pos;
      }
      pos++;
    }
    return -1;
  }

  /// 拉出一个平衡组（`[...]` 或 `(...)`）。
  ///
  /// 逐个扫描并跟踪嵌套深度；**引号内的括号不计数、引号内的转义不看** ——
  /// xpath 和 jsoup 的选择器里引号转义本就无效，按字面处理才与 legado 一致。
  bool _chompRuleBalanced(String open, String close) {
    int pos = _pos;
    int depth = 0;
    bool inSingleQuote = false;
    bool inDoubleQuote = false;

    do {
      if (pos >= _queue.length) break;
      final String c = _queue[pos];
      pos++;

      if (c == '\'' && !inDoubleQuote) {
        inSingleQuote = !inSingleQuote;
      } else if (c == '"' && !inSingleQuote) {
        inDoubleQuote = !inDoubleQuote;
      }

      // 语法单元未闭合，直接进入下一轮
      if (inSingleQuote || inDoubleQuote) continue;

      if (c == r'\') {
        // 引号外的转义字符把下一个字符吃掉
        if (pos < _queue.length) pos++;
        continue;
      }

      if (c == open) {
        depth++;
      } else if (c == close) {
        depth--;
      }
    } while (depth > 0);

    if (depth > 0) return false; // 不平衡
    _pos = pos;
    return true;
  }

  /// 按默认分隔符（`&&` / `||` / `%%`）拆分。
  ///
  /// 无分隔符时 `_splitMultiple` 会原样返回整串，`_elementsType` 保持空，
  /// 于是组合类型自然是 [RuleCombinator.none] —— 不必单独判断。
  RuleSplit split() {
    _trim();
    _rule.clear();
    _elementsType = '';

    final List<String> parts = _splitMultiple(_defaultSeparators);
    return RuleSplit(
      parts: List<String>.unmodifiable(parts),
      combinator: RuleCombinator.fromToken(_elementsType),
    );
  }

  /// 固定用某一个分隔符拆分（便于做「只按 && 拆」这类实验）。
  RuleSplit splitBy(String separator) {
    _trim();
    _rule.clear();
    _elementsType = separator;
    final List<String> parts = _splitSingle(separator);
    return RuleSplit(
      parts: List<String>.unmodifiable(parts),
      combinator: RuleCombinator.fromToken(_elementsType),
    );
  }

  /// 单分隔符拆分。与参考实现 `_splitRuleSingle` 同构。
  List<String> _splitSingle(String separator) {
    if (!_consumeTo(separator)) {
      if (_startX < _queue.length) {
        _rule.add(_queue.substring(_startX));
      }
      return _rule;
    }

    final int end = _pos; // 记录分隔位置
    _pos = _start; // 退回段首，改为查找筛选器

    do {
      final int st = _findToAny(<String>['[', '(']);

      if (st == -1) {
        // 后面没有筛选器了，放心按分隔符切
        _rule.add(_queue.substring(_startX, end));
        _elementsType = _queue.substring(end, end + _step);
        _pos = end + _step;

        while (_consumeTo(_elementsType)) {
          _rule.add(_queue.substring(_start, _pos));
          _pos += _step;
        }
        _rule.add(_queue.substring(_pos));
        return _rule;
      }

      if (st > end) {
        // 分隔符在筛选器之前 → 不在选择器内部，可以安全切
        _rule.add(_queue.substring(_startX, end));
        _elementsType = _queue.substring(end, end + _step);
        _pos = end + _step;

        while (_consumeTo(_elementsType) && _pos < st) {
          _rule.add(_queue.substring(_start, _pos));
          _pos += _step;
        }

        if (_pos > st) {
          // 首段已切出，但当前段落在筛选器里，递归处理剩余部分
          _startX = _start;
          return _splitSingle(_elementsType);
        }
        // 后面再无分隔符
        _rule.add(_queue.substring(_pos));
        return _rule;
      }

      // 筛选器在分隔符之前 → 整体跳过这个平衡组，否则组内的分隔符会被误切
      _pos = st;
      final String next = _queue[_pos] == '[' ? ']' : ')';
      if (!_chompRuleBalanced(_queue[_pos], next)) {
        throw FormatException('${_queue.substring(0, _start)} 后的括号未平衡');
      }
    } while (end > _pos);

    _start = _pos;
    return _splitSingle(separator); // 递归切首段
  }

  /// 多分隔符拆分。与参考实现 `_splitRuleMultiple` 同构 ——
  /// 与单分隔符版的唯一差别是用 `_consumeToAny` 找「位置最靠前」的分隔符。
  List<String> _splitMultiple(List<String> split) {
    if (!_consumeToAny(split)) {
      if (_startX < _queue.length) {
        _rule.add(_queue.substring(_startX));
      }
      return _rule;
    }

    final int end = _pos;
    _pos = _start;

    do {
      final int st = _findToAny(<String>['[', '(']);

      if (st == -1) {
        _rule.add(_queue.substring(_startX, end));
        _elementsType = _queue.substring(end, end + _step);
        _pos = end + _step;

        while (_consumeTo(_elementsType)) {
          _rule.add(_queue.substring(_start, _pos));
          _pos += _step;
        }
        _rule.add(_queue.substring(_pos));
        return _rule;
      }

      if (st > end) {
        _rule.add(_queue.substring(_startX, end));
        _elementsType = _queue.substring(end, end + _step);
        _pos = end + _step;

        while (_consumeTo(_elementsType) && _pos < st) {
          _rule.add(_queue.substring(_start, _pos));
          _pos += _step;
        }

        if (_pos > st) {
          _startX = _start;
          return _splitMultiple(split);
        }
        _rule.add(_queue.substring(_pos));
        return _rule;
      }

      _pos = st;
      final String next = _queue[_pos] == '[' ? ']' : ')';
      if (!_chompRuleBalanced(_queue[_pos], next)) {
        throw FormatException('${_queue.substring(0, _start)} 后的括号未平衡');
      }
    } while (end > _pos);

    _start = _pos;
    return _splitMultiple(split);
  }

  /// 便捷入口：拆一条规则串，永不抛异常。
  ///
  /// 括号不平衡等脏规则会让 `_splitSingle` 抛 [FormatException]；
  /// 解析用户导入的书源时不该因为一条脏规则炸掉整次导入，所以这里兜底成单条。
  static RuleSplit splitRule(String rule) {
    try {
      return RuleAnalyzer(rule).split();
    } on FormatException {
      return RuleSplit(
        parts: <String>[rule.trim()],
        combinator: RuleCombinator.none,
      );
    }
  }
}
