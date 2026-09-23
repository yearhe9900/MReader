#!/usr/bin/env bash
# 测试分组局部执行器（2026-09-23，应对「每次全量太慢」）。
#
# 用法：bash tool/test.sh [parse|data|reader|ui|fast|all]
#   parse  解析层（纯 Dart，最快）      test/epub、test/format
#   data   数据层（多为纯 test+临时目录） test/library、test/meta、test/storage、test/task
#   reader 阅读器（含 testWidgets）      test/reader、test/typography、test/perf
#   ui     界面层（最慢，FakeAsync 重）   test/ui、test/widget_test.dart
#   fast   parse + data（不含 widget 重的两组）
#   all    全量 —— 仅在负责人明确发出「全量测试」指令时执行（2026-09-23 拍板）；
#          开发批次只跑与改动相关的分组。无参数不默认全量。
#
# 分组口径见 docs/tech-usage.md「测试分组与局部执行」。
# 统一 --timeout 30s：排查挂死的既定纪律（默认 10 分钟/个太慢）。
# ⚠️ CLI --timeout 只覆盖纯 test()——testWidgets 显式用 binding 的 10 分钟
# 默认值压过它，故含 testWidgets 的文件须在 main() 首行调
# test/test_config.dart 的 capTestTimeout()（30s 兜底才真正生效）。
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -lt 1 ]; then
  echo "usage: bash tool/test.sh [parse|data|reader|ui|fast|all]" >&2
  echo "（全量 all 仅在负责人明确下令时执行；开发批次请指定相关分组）" >&2
  exit 2
fi
group="$1"
# 注意：`flutter test` 的 `test` 子命令已由第 33 行写出，这里**只放选项**——
# 曾误写成 `args=(test --timeout 30s)`，与子命令叠加成 `flutter test test …`，
# 第二个位置参数 `test`（目录）把全量拖了进来，分组形同虚设。
args=(--timeout 30s)

case "$group" in
  parse)  targets=(test/epub test/format) ;;
  data)   targets=(test/library test/meta test/storage test/task) ;;
  reader) targets=(test/reader test/typography test/perf) ;;
  ui)     targets=(test/ui test/widget_test.dart) ;;
  fast)   targets=(test/epub test/format test/library test/meta test/storage test/task) ;;
  all)    targets=() ;;
  *)
    echo "usage: bash tool/test.sh [parse|data|reader|ui|fast|all]" >&2
    exit 2
    ;;
esac

exec flutter test "${args[@]}" ${targets[@]+"${targets[@]}"}
