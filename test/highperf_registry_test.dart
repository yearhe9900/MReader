// `lib/highperf/**` 与 `BookRegistry` 加速层注入缝的单测（`M35-T01` / `RUST-01` / `RUST-10`）。
//
// 纯 Dart `test()`：不涉及 widget、不涉及 FakeAsync（本项目已两次实证
// `testWidgets` 体内 `await` 真异步会挂死）。
//
// 覆盖四条主线：
//   ① **三态探测**与幂等（§A.2）——「未探测 / 探测失败 / 可用」必须可区分；
//   ② **五情形处置**（§A.3）——含「情形 5 不翻转 probeOk、只降级具体能力」；
//   ③ **强制纯 Dart**与可观测（§A.5 / `RUST-10 ②`）；
//   ④ **注入缝**（§A.1）：构造注入优先、组合根注入点兜底、`capabilityFor` 映射。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_registry.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/highperf/high_perf_capability.dart';
import 'package:mreader/highperf/high_perf_error.dart';
import 'package:mreader/highperf/high_perf_registry.dart';
import 'package:mreader/highperf/null_high_perf_engine.dart';

/// 可编程的假引擎：探测可成功 / 可抛指定异常 / 可回一个错版本。
class _FakeEngine implements HighPerfEngine {
  _FakeEngine({
    this.abiVersion = kRustAbiVersion,
    Set<HighPerfCapability>? capabilities,
    this.probeFailure,
    this.probeDelay = Duration.zero,
  }) : capabilities = capabilities ?? <HighPerfCapability>{
          HighPerfCapability.epubDecompress,
          HighPerfCapability.txtChapterize,
        };

  @override
  String get id => 'rust';

  @override
  final String abiVersion;

  @override
  final Set<HighPerfCapability> capabilities;

  /// 非空则 `probe()` 抛它（模拟 §A.3 情形 1/2）。
  final HighPerfException? probeFailure;

  /// 模拟「探测慢」（用于超时路径）。
  final Duration probeDelay;

  /// 探测次数——幂等断言（`RUST-01 ③`）的取证点。
  int probeCalls = 0;

  @override
  Future<void> probe() async {
    probeCalls++;
    if (probeDelay > Duration.zero) {
      await Future<void>.delayed(probeDelay);
    }
    if (probeFailure != null) throw probeFailure!;
  }

  @override
  Future<void> dispose() async {}
}

/// 一个能把「探测通过」的引擎装进注册表的最小工具。
Future<HighPerfRegistry> _probed(HighPerfEngine engine) async {
  final HighPerfRegistry registry = HighPerfRegistry(engine: engine);
  await registry.warmUp();
  return registry;
}

void main() {
  tearDown(() {
    // 全局态复位：任何用例改了这两处都必须还原，避免跨用例污染（顺序依赖最难查）。
    HighPerfRegistry.debugForcePureDart = false;
    HighPerfRegistryProvider.current = HighPerfRegistry.fallback();
  });

  group('HighPerfCapability 元信息（RUST-06 ⑤ 的「阈值编号可逐条指出」）', () {
    test('wireId 唯一且非空', () {
      final List<String> ids =
          HighPerfCapability.values.map((c) => c.wireId).toList();
      expect(ids.toSet().length, ids.length);
      expect(ids.every((id) => id.isNotEmpty), isTrue);
    });

    test('候选项数与阈值编号：1 MOBI / 2 EPUB / 3 TXT / 4 搜索 / 5 BM25', () {
      // 「5 项」是 §A.4 与 §J.1 的写死口径（2b 不占枚举值，见 HighPerfCapability 注释）。
      expect(HighPerfCapability.values.length, 5);
      expect(HighPerfCapability.mobiDecompress.thresholdNo, 1);
      expect(HighPerfCapability.epubDecompress.thresholdNo, 2);
      expect(HighPerfCapability.txtChapterize.thresholdNo, 3);
      expect(HighPerfCapability.fullTextSearch.thresholdNo, 4);
      expect(HighPerfCapability.bm25Index.thresholdNo, 5);
    });

    test('labelZh 全非空且互不相同', () {
      final List<String> labels =
          HighPerfCapability.values.map((c) => c.labelZh).toList();
      expect(labels.every((l) => l.isNotEmpty), isTrue);
      expect(labels.toSet().length, labels.length);
    });

    test('探测期原因表覆盖 §A.3 情形 1~4（调用期类别不在表内）', () {
      expect(
        kHighPerfProbeReasonZh.keys.toSet(),
        <HighPerfErrorKind>{
          HighPerfErrorKind.notCompiled,
          HighPerfErrorKind.missingSymbol,
          HighPerfErrorKind.abiMismatch,
          HighPerfErrorKind.platformUnsupported,
        },
      );
      expect(kHighPerfProbeReasonZh.values.every((v) => v.isNotEmpty), isTrue);
    });

    test('HighPerfException.toString() 只回 messageZh（§D.1，不泄漏 detail）', () {
      const HighPerfException error = HighPerfException(
        HighPerfErrorKind.missingContainer,
        '缺少 META-INF/container.xml，不是合法的 EPUB 结构。',
        detail: 'ArgumentError: xxx',
      );
      expect(error.toString(), '缺少 META-INF/container.xml，不是合法的 EPUB 结构。');
      expect(error.toString().contains('ArgumentError'), isFalse);
    });
  });

  group('NullHighPerfEngine（回落路径的唯一实现，§A.4）', () {
    test('不声明任何能力；probe / dispose 皆为不抛的空操作', () async {
      const NullHighPerfEngine engine = NullHighPerfEngine();
      expect(engine.id, 'null');
      expect(engine.abiVersion, '');
      expect(engine.capabilities, isEmpty);
      await engine.probe();
      await engine.dispose();
    });
  });

  group('三态探测与幂等（§A.2）', () {
    test('未探测：probeOk 未收敛、isPureDart 为 true（宁保守不冒进）', () {
      final HighPerfRegistry registry =
          HighPerfRegistry(engine: _FakeEngine());
      expect(registry.isProbed, isFalse);
      expect(registry.isPureDart, isTrue);
      expect(registry.reason, isNull);
      for (final HighPerfCapability c in HighPerfCapability.values) {
        expect(registry.has(c), isFalse);
        expect(registry.reasonFor(c), '尚未探测（warmUp 未执行）');
      }
    });

    test('探测通过：可用能力为 true，未提供的能力给出「未提供」原因', () async {
      final HighPerfRegistry registry = await _probed(_FakeEngine());
      expect(registry.isProbed, isTrue);
      expect(registry.isPureDart, isFalse);
      expect(registry.engineId, 'rust');
      expect(registry.reason, isNull);
      expect(registry.has(HighPerfCapability.epubDecompress), isTrue);
      expect(registry.has(HighPerfCapability.txtChapterize), isTrue);
      expect(registry.has(HighPerfCapability.fullTextSearch), isFalse);
      expect(registry.reasonFor(HighPerfCapability.epubDecompress), isNull);
      expect(
        registry.reasonFor(HighPerfCapability.fullTextSearch),
        contains('未提供该能力'),
      );
    });

    test('幂等：warmUp 第二次不再探测（RUST-01 ③ 探测只做一次）', () async {
      final _FakeEngine engine = _FakeEngine();
      final HighPerfRegistry registry = HighPerfRegistry(engine: engine);
      await registry.warmUp();
      await registry.warmUp();
      await registry.warmUp();
      expect(engine.probeCalls, 1);
    });

    test('抖动探针不回翻结论：失败后再 warmUp 仍为失败', () async {
      final _FakeEngine engine = _FakeEngine(
        probeFailure: const HighPerfException(
          HighPerfErrorKind.notCompiled,
          '未编译 Rust 加速层',
        ),
      );
      final HighPerfRegistry registry = HighPerfRegistry(engine: engine);
      await registry.warmUp();
      expect(registry.isPureDart, isTrue);
      await registry.warmUp();
      expect(registry.isPureDart, isTrue);
      expect(engine.probeCalls, 1);
    });
  });

  group('探测失败的五情形（§A.3）', () {
    test('情形 1 未编译：probeOk=false、原因逐字、全部能力回落', () async {
      final HighPerfRegistry registry = await _probed(
        _FakeEngine(
          probeFailure: const HighPerfException(
            HighPerfErrorKind.notCompiled,
            '未编译 Rust 加速层',
          ),
        ),
      );
      expect(registry.isPureDart, isTrue);
      expect(registry.reason, '未编译 Rust 加速层');
      for (final HighPerfCapability c in HighPerfCapability.values) {
        expect(registry.has(c), isFalse);
        expect(registry.reasonFor(c), '未编译 Rust 加速层');
      }
    });

    test('情形 2 符号缺失：原因取自引擎的 HighPerfException', () async {
      final HighPerfRegistry registry = await _probed(
        _FakeEngine(
          probeFailure: const HighPerfException(
            HighPerfErrorKind.missingSymbol,
            '动态库符号缺失（版本不匹配）',
            detail: 'Invalid argument(s): symbol not found',
          ),
        ),
      );
      expect(registry.isPureDart, isTrue);
      expect(registry.reason, '动态库符号缺失（版本不匹配）');
      // 原始报错只进 detail，不进单一原因（§D.1）。
      expect(registry.reason!.contains('Invalid argument'), isFalse);
    });

    test('情形 3 版本不匹配：期望 / 实际都进原因（唯一可靠哨兵）', () async {
      final HighPerfRegistry registry =
          await _probed(_FakeEngine(abiVersion: '9.9.9'));
      expect(registry.isPureDart, isTrue);
      expect(registry.reason, contains('期望 $kRustAbiVersion，实际 9.9.9'));
    });

    test('情形 3 变体：引擎不回版本串 → 原因为「实际 未知」', () async {
      final HighPerfRegistry registry =
          await _probed(_FakeEngine(abiVersion: ''));
      expect(registry.isPureDart, isTrue);
      expect(registry.reason, contains('实际 未知'));
    });

    test('探测超时：按 kHighPerfProbeTimeout 判死且不抛', () async {
      final HighPerfRegistry registry = HighPerfRegistry(
        engine: _FakeEngine(probeDelay: const Duration(milliseconds: 300)),
      );
      await registry.warmUp(timeout: const Duration(milliseconds: 30));
      expect(registry.isPureDart, isTrue);
      expect(registry.reason, contains('探测超时'));
    });

    test('情形 5：单次失败不翻转 probeOk；连续 2 次只降级该能力', () async {
      final HighPerfRegistry registry = await _probed(_FakeEngine());
      expect(registry.has(HighPerfCapability.epubDecompress), isTrue);

      registry.noteFailure(HighPerfCapability.epubDecompress);
      // 第一次失败：探测结论不动、能力仍可用（一次坏字节不该让能力下线）。
      expect(registry.isProbed, isTrue);
      expect(registry.reason, isNull);
      expect(registry.has(HighPerfCapability.epubDecompress), isTrue);

      registry.noteFailure(HighPerfCapability.epubDecompress);
      expect(registry.has(HighPerfCapability.epubDecompress), isFalse);
      expect(
        registry.reasonFor(HighPerfCapability.epubDecompress),
        contains('惰性降级'),
      );
      // 只降级该能力，其余不受影响。
      expect(registry.has(HighPerfCapability.txtChapterize), isTrue);
      expect(registry.degraded, <HighPerfCapability>{
        HighPerfCapability.epubDecompress,
      });
    });

    test('情形 5：成功会清零连续失败计数', () async {
      final HighPerfRegistry registry = await _probed(_FakeEngine());
      registry.noteFailure(HighPerfCapability.txtChapterize);
      registry.noteSuccess(HighPerfCapability.txtChapterize);
      registry.noteFailure(HighPerfCapability.txtChapterize);
      // 失败—成功—失败 = 连续 1 次 → 不降级。
      expect(registry.has(HighPerfCapability.txtChapterize), isTrue);
      expect(registry.degraded, isEmpty);
    });

    test('已定型为不可用时，note* 为空操作（共享回落实例可安全复用）', () {
      final HighPerfRegistry registry = HighPerfRegistry.fallback();
      // 若这些调用回写了状态，`fallback()` 就不再是可共享的只读实例。
      for (final HighPerfCapability c in HighPerfCapability.values) {
        registry.noteFailure(c);
        registry.noteFailure(c);
        registry.noteSuccess(c);
      }
      expect(registry.degraded, isEmpty);
      expect(registry.isProbed, isTrue);
      expect(registry.isPureDart, isTrue);
    });
  });

  group('纯 Dart 回落与强制开关（§A.5 / RUST-10）', () {
    test('fallback() 是共享只读实例，且 fromEnvironment() 无引擎时返回同一个', () {
      final HighPerfRegistry a = HighPerfRegistry.fallback();
      final HighPerfRegistry b = HighPerfRegistry.fallback();
      final HighPerfRegistry c = HighPerfRegistry.fromEnvironment();
      expect(identical(a, b), isTrue);
      expect(identical(a, c), isTrue);
      expect(a.isPureDart, isTrue);
      expect(a.reason, kPureDartFallbackReason);
      expect(a.engineId, 'null');
      for (final HighPerfCapability cap in HighPerfCapability.values) {
        expect(a.has(cap), isFalse);
        expect(a.reasonFor(cap), kPureDartFallbackReason);
      }
    });

    test('无引擎 == 「本次构建没有加速层」：不 probe、不编造版本不匹配', () async {
      final HighPerfRegistry registry = HighPerfRegistry.fromEnvironment();
      await registry.warmUp();
      expect(registry.reason, kPureDartFallbackReason);
      expect(registry.reason, isNot(contains('版本不匹配')));
    });

    test('隐藏开关强制纯 Dart：即便给了能探测通过的引擎也不用它', () async {
      HighPerfRegistry.debugForcePureDart = true;
      final _FakeEngine engine = _FakeEngine();
      final HighPerfRegistry registry =
          HighPerfRegistry.fromEnvironment(engine: engine);
      await registry.warmUp();
      expect(registry.isPureDart, isTrue);
      expect(registry.reason, kForcedPureDartReason);
      expect(registry.engineId, 'null');
      expect(engine.probeCalls, 0);
    });

    test('开关关闭后恢复原状（RUST-10 ⑤）', () async {
      HighPerfRegistry.debugForcePureDart = false;
      final HighPerfRegistry registry =
          HighPerfRegistry.fromEnvironment(engine: _FakeEngine());
      await registry.warmUp();
      expect(registry.isPureDart, isFalse);
      expect(registry.has(HighPerfCapability.epubDecompress), isTrue);
    });
  });

  group('可观测 describe()（RUST-10 ②，只进调试日志）', () {
    test('字段齐全 + 逐能力结论 + degraded 排序', () async {
      final HighPerfRegistry registry = await _probed(_FakeEngine());
      registry.noteFailure(HighPerfCapability.txtChapterize);
      registry.noteFailure(HighPerfCapability.txtChapterize);
      registry.noteFailure(HighPerfCapability.epubDecompress);
      registry.noteFailure(HighPerfCapability.epubDecompress);

      final Map<String, Object?> info = registry.describe();
      expect(info['engineId'], 'rust');
      expect(info['probeOk'], isTrue);
      expect(info['probeReason'], isNull);
      expect(info['abiVersion'], kRustAbiVersion);
      expect(info['expectedAbiVersion'], kRustAbiVersion);
      expect(info['forcedPureDart'], isFalse);
      // degraded 是排序后的 wireId 列表（排序 → 快照可比对，便于劣化哨兵）。
      expect(info['degraded'], <String>['epub-decompress', 'txt-chapterize']);
      final Map<String, bool> caps = info['capabilities']! as Map<String, bool>;
      expect(caps.length, HighPerfCapability.values.length);
      expect(caps['epub-decompress'], isFalse);
      expect(caps['full-text-search'], isFalse);
    });

    test('未探测时 describe() 如实给出 null（而不是假装失败）', () {
      final HighPerfRegistry registry = HighPerfRegistry(engine: _FakeEngine());
      final Map<String, Object?> info = registry.describe();
      expect(info['probeOk'], isNull);
      expect(info['probeReason'], isNull);
    });
  });

  group('BookRegistry 注入缝与格式↔能力映射（§A.1）', () {
    test('capabilityFor：epub/txt/mobi 有候选；cbz/cbr/pdf/unsupported 没有', () {
      const BookRegistry registry = BookRegistry();
      expect(
        registry.capabilityFor(FormatKind.epub),
        HighPerfCapability.epubDecompress,
      );
      expect(
        registry.capabilityFor(FormatKind.txt),
        HighPerfCapability.txtChapterize,
      );
      expect(
        registry.capabilityFor(FormatKind.mobi),
        HighPerfCapability.mobiDecompress,
      );
      // PRD §15.6.2 的六项候选里没有 CBZ / CBR / PDF——不得「顺手」挂上去（RUST-06）。
      expect(registry.capabilityFor(FormatKind.cbz), isNull);
      expect(registry.capabilityFor(FormatKind.cbr), isNull);
      expect(registry.capabilityFor(FormatKind.pdf), isNull);
      expect(registry.capabilityFor(FormatKind.unsupported), isNull);
    });

    test('构造注入优先于组合根注入点', () {
      final HighPerfRegistry injected = HighPerfRegistry(engine: _FakeEngine());
      HighPerfRegistryProvider.current = HighPerfRegistry.fallback();
      expect(identical(BookRegistry(highPerf: injected).highPerf, injected), isTrue);
    });

    test('未构造注入时取组合根注入点；未写入时即纯 Dart 回落', () {
      final HighPerfRegistry provider = HighPerfRegistry(engine: _FakeEngine());
      HighPerfRegistryProvider.current = provider;
      expect(identical(const BookRegistry().highPerf, provider), isTrue);

      HighPerfRegistryProvider.current = HighPerfRegistry.fallback();
      expect(const BookRegistry().highPerf.isPureDart, isTrue);
    });

    test(
      '状态钉：T01 阶段探测通过也不改分发结果（Rust 源属 T04，gate 未过）',
      () async {
        // 这条断言**故意钉住当前状态**，不是目标行为：
        // 架构 §A.1 的终态是「epub/txt 按 has(...) 择 Rust 源」，但 Rust 源是 M35-T04
        // 且依赖 T03 的 FRB gate。T01 不预置恒不被选中的 Rust 分支，故此处仍为纯 Dart。
        // **T04 落地本接缝时，本用例必须同步改写**（改成断言实现了 Rust 源）。
        final HighPerfRegistry probed = await _probed(_FakeEngine());
        expect(probed.has(HighPerfCapability.txtChapterize), isTrue);

        final BookRegistry registry = BookRegistry(highPerf: probed);
        final BookSource source = await registry.open(
          fileName: 'a.txt',
          bytes: Uint8List.fromList(utf8.encode('第1章 开始\n正文内容')),
        );
        expect(source.implId, 'dart-txt');
        await source.dispose();
      },
    );

    test('openBook() 默认走组合根注入点，签名向后兼容', () async {
      final HighPerfRegistry provider = HighPerfRegistry(engine: _FakeEngine());
      HighPerfRegistryProvider.current = provider;
      final BookSource source = await openBook(
        fileName: 'a.txt',
        bytes: Uint8List.fromList(utf8.encode('第1章 开始\n正文内容')),
      );
      expect(source.implId, 'dart-txt');
      await source.dispose();
    });
  });
}
