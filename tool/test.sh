#!/usr/bin/env bash
# 测试分组局部执行器（2026-09-23，应对「每次全量太慢」）。
#
# 用法：bash tool/test.sh [parse|data|reader|ui|fast|all]
#   parse  解析层（纯 Dart，最快）      test/epub、test/format
#   data   数据层（多为纯 test+临时目录） test/library、test/meta、test/storage、test/task
#   reader 阅读器（含 testWidgets）      test/reader、test/typography、test/perf
#   ui     界面层（最慢，FakeAsync 重）   test/ui、test/widget_test.dart
#   fast   parse + data（不含 widget 重的两组）
#   all    全量（批收官 / 里程碑验收用；默认）
#
# 分组口径见 docs/tech-usage.md「测试分组与局部执行」。
# 统一 --timeout 30s：排查挂死的既定纪律（默认 10 分钟/个太慢）。
set -euo pipefail
cd "$(dirname "$0")/.."

group="${1:-all}"
args=(test --timeout 30s)

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
