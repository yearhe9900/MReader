// `RUST-08 ③` 入库检查（架构 §G.4）：FRB 生成物不得被 .gitignore 忽略。
//
// 与 §G.4 字面规格的一处**有意偏差**：原文断言 `contains('lib/src/rust') == false`，
// 但同节又要求带 `!lib/src/rust/**` 反排除（防御性）——两者字面互斥。此处取两者
// 意图合一：① 提及 `lib/src/rust` 的**有效规则行**必须是 `!` 反排除（正向忽略判红）；
// ② 反排除必须在场；③ `*.dart` 通配忽略一律判红（原文断言，逐字保留）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FRB 生成物在版本库可见（未被 .gitignore）（RUST-08 ③）', () {
    final String gi = File('.gitignore').readAsStringSync();

    // 有效规则行 = 去空白、非空、非注释。
    final List<String> hits = gi
        .split('\n')
        .map((String line) => line.trim())
        .where((String line) =>
            line.isNotEmpty &&
            !line.startsWith('#') &&
            line.contains('lib/src/rust'))
        .toList();
    expect(hits.where((String line) => !line.startsWith('!')), isEmpty,
        reason: 'lib/src/rust 只允许以 ! 反排除出现，不得被正向忽略：$hits');
    expect(hits.any((String line) => line.startsWith('!')), isTrue,
        reason: '§G.4 要求 !lib/src/rust/** 反排除在场（防未来 *.so 类通配误伤）');

    // 更强的检查：禁止 *.dart 被 ignore。
    expect(RegExp(r'\*\.dart\s*$', multiLine: true).hasMatch(gi), isFalse,
        reason: '*.dart 通配忽略会把 FRB 生成物逐出版本库（RUST-08 ①）');
  });
}
