// `RUST-04` 机械护栏（架构 §D.2 逐字规格）：无 Rust 工具链也能跑（只读文本）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rust/Cargo.toml 不得出现 panic = "abort"（RUST-04 护栏）', () {
    final File f = File('rust/Cargo.toml');
    if (!f.existsSync()) return; // Rust 线尚未落地的环境，跳过
    final String src = f.readAsStringSync();
    expect(src.contains('panic = "abort"'), isFalse,
        reason: 'panic=abort 会让 catch_unwind 失效、panic 直接终止进程（RUST-04）');
    expect(RegExp(r'panic\s*=\s*"unwind"').allMatches(src).length >= 2, isTrue,
        reason: 'dev/release 两个 profile 都需显式 panic = "unwind"');
  });
}
