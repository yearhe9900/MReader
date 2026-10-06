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

  // vendored cargokit 的 Gradle 9 兼容护栏：Gradle 9 移除了 `Project.exec()`
  // （Flutter 3.47 工具链 = Gradle 9.1，javap 实证 Project 上无任何 exec 成员）。
  // 上游 fzyzcjy/cargokit main 已改注入 `ExecOperations`，本仓 vendored 副本曾是
  // 旧版导致 `flutter build apk` 报 `Could not find method exec()`。
  // 另：flutter_rust_bridge_codegen 2.13.0 **内嵌模板仍是坏版本**——重跑
  // `flutter rust_bridge_codegen generate` 若重写本文件，此测试会立刻判红。
  test('rust_builder/cargokit 用 ExecOperations 而非 project.exec（Gradle 9 护栏）',
      () {
    final File f = File('rust_builder/cargokit/gradle/plugin.gradle');
    if (!f.existsSync()) return; // Rust 线尚未落地的环境，跳过
    final String src = f.readAsStringSync();
    expect(RegExp(r'project\s*\.\s*exec\s*\(').hasMatch(src), isFalse,
        reason: 'Gradle 9 已删除 Project.exec()，构建会失败；改用注入的 ExecOperations');
    expect(src.contains('execOperations.exec'), isTrue,
        reason: 'ExecOperations 注入与调用必须在场（上游 cargokit 同款修法）');
    expect(RegExp(r'@Inject\s+abstract\s+ExecOperations\s+getExecOperations')
            .hasMatch(src),
        isTrue, reason: '任务类需 @Inject 注入 ExecOperations 服务');
  });
}
