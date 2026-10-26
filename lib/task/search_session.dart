// 全书搜索执行会话（`CNT-06` / `RUST-05`）——「后台 isolate 流式搜索 + 协议级取消」的
// **唯一收口点**。
//
// 要点：
//   · **两条执行路径**（[SearchSession.start] 按入参分流，上层无感）：给 [SearchBookSpec]
//     → **后台重建**（spec 进长驻搜索 isolate 重建源并 `search()`，事件逐条回传；解压 /
//     HTML 解析 / 扫描全离开主 isolate，是 `CNT-06`「UI 不卡死」与阈值 4「单帧 ≤ 16ms」
//     的正面落点。重建一律 `prefetchFlatTitles: false`：搜索不吃全书标题预取——该预取是
//     搜索首屏的已知大户，命中章标题由扫描循环自取）；给 [BookSource] 实例 → **本 isolate
//     流式**（`PdfSource` 这类**持有不可序列化句柄**的源；PDF 逐页 `await` 之间必然让出
//     事件循环，不构成连续占用主 isolate）。两路径对外**同一句柄、同一事件流语义**；
//   · **协议级取消（`RUST-05` ①③）**：取消是消息协议的一等公民，**不杀线程**——
//     [SearchSession.cancel] ① 当即关本地事件流（UI 当帧恢复可用）② 经反向 [SendPort]
//     发取消令，后台把 [CancelToken] 置位后逐章短路、释放自建源、`Isolate.exit()` 自然
//     退出——**不留后台线程**。进度回报由各源产出，协议层保证**单调递增**（`RUST-05` ③）；
//   · **回落（`RUST-01` 式诚实降级，同 `PERF-01` 信封口径）**：后台派发失败 / 远端中途
//     崩溃（端口以「未 done」状态关闭）时，同一 spec 在**本 isolate** 重建重跑，结果与
//     从未走过 isolate 一致。业务空结果（零命中）与业务错误（[MReaderFormatException] 经
//     信封回传）**不是**失败，不触发回落。
import 'dart:async';
import 'dart:developer' show log;
import 'dart:isolate';

import '../format/book_registry.dart';
import '../src/rust/frb_generated.dart' show RustLib;
import '../format/book_source.dart';

/// 发起一次全书搜索。[spec] 与 [localSource] 至少给一个：[spec] 优先（后台重建路径），
/// 只给 [localSource] 走本 isolate 流式（句柄源）。**都不给**返回空流会话（调用方
/// 守卫，此处兜底不抛——对齐各 Source 的 dispose 竞态「优雅空结果」口径）。
class SearchSession {
  SearchSession._(this._run, this._stopwatch);

  factory SearchSession.start({
    required String query,
    SearchBookSpec? spec,
    BookSource? localSource,
  }) {
    final _SearchRun run;
    if (query.isEmpty) {
      run = const _EmptyRun();
    } else if (spec != null) {
      run = _IsolateRun(query: query, spec: spec);
    } else if (localSource != null) {
      run = _LocalRun(query: query, source: localSource, ownsSource: false);
    } else {
      run = const _EmptyRun();
    }
    final SearchSession session =
        SearchSession._(run, Stopwatch()..start());
    run.begin(_SessionSink(session));
    return session;
  }

  final _SearchRun _run;
  final Stopwatch _stopwatch;
  final StreamController<SearchEvent> _controller =
      StreamController<SearchEvent>();

  bool _cancelled = false;
  final Completer<void> _done = Completer<void>();

  /// 事件流：命中 `SearchEvent.hit` 与进度 `SearchEvent.progress` 交错，结束即关。
  Stream<SearchEvent> get events => _controller.stream;

  /// 本次会话是否跑在后台 isolate（观测 / 测试取证；`RUST-10` 可观测性精神）。
  bool get usedIsolate => _run is _IsolateRun;

  /// 流是否已收尾（done / 取消 / 失败都算）。
  bool get isDone => _done.isCompleted;

  /// 会话收尾（与 `events` 流结束同步；错误结束时以同一错误完成）。
  Future<void> get done => _done.future;

  /// 发起到**首个任意事件**（命中或进度）的耗时——响应性埋点（阈值 4 对照）。
  Duration? firstEventElapsed;

  /// 发起到**首个命中**的耗时——「首屏结果」埋点（阈值 4：50MB 书 > 1.5s 口径）。
  /// 全书零命中时保持 `null`。
  Duration? firstHitElapsed;

  /// 协议级取消：当帧关流（UI 立即恢复），并通知执行侧短路退出、释放资源。
  /// 取消不走 error：正常关闭（调用方 `onDone` 即「用户中止」）。
  void cancel() {
    if (_cancelled || _done.isCompleted) return;
    _cancelled = true;
    _run.cancel();
    _finish(null);
  }

  void _finish(Object? error) {
    if (_done.isCompleted) return;
    if (!_controller.isClosed) {
      if (error != null) {
        _controller.addError(error);
      }
      _controller.close();
    }
    _stopwatch.stop();
    if (error != null) {
      _done.completeError(error);
      // 调用方可能只听 events 不等 done：把「未被听取」的错误吞成正常收尾，
      // 避免 unhandled async error（done 的错误仍可被 await 方捕获）。
      _done.future.ignore();
    } else {
      _done.complete();
    }
  }
}

/// [SearchSession] 内部泵口（把执行侧事件接进会话状态与统计）。
class _SessionSink {
  _SessionSink(this._session);

  final SearchSession _session;

  void add(SearchEvent event) {
    final SearchSession s = _session;
    if (s._done.isCompleted) return; // 取消后迟到的事件直接丢弃
    s.firstEventElapsed ??= s._stopwatch.elapsed;
    if (event.hit != null) {
      s.firstHitElapsed ??= s._stopwatch.elapsed;
    }
    s._controller.add(event);
  }

  void fail(Object error) => _session._finish(error);

  void done() => _session._finish(null);
}

/// 执行侧抽象：后台 isolate 或本 isolate 流式，二者同形。
abstract class _SearchRun {
  void begin(_SessionSink sink);

  void cancel();
}

// ---------------------------------------------------------------------------
// 后台重建路径（spec 进长驻 isolate，事件流回）
// ---------------------------------------------------------------------------

/// `Isolate.spawn` 初始消息：纯数据（[SearchBookSpec] + query + 回传端口）。
class _SearchBootstrap {
  const _SearchBootstrap({
    required this.spec,
    required this.query,
    required this.eventsPort,
  });

  final SearchBookSpec spec;
  final String query;
  final SendPort eventsPort;
}

/// 控制消息（主 → 后台）：协议级取消令。
const String _kCancel = 'mreader-search-cancel';

/// 后台 → 主：流自然收尾标记。
class _SearchDoneMsg {
  const _SearchDoneMsg();
}

/// 后台 → 主：业务错误信封（不触发回落）。
class _SearchFailedMsg {
  const _SearchFailedMsg(this.error);

  final Object error;
}

/// 后台 → 主：远端意外崩溃（触发本 isolate 回落重跑）。
class _SearchCrashedMsg {
  const _SearchCrashedMsg(this.detail);

  final String detail;
}

/// 搜索 isolate 入口（**顶层函数** + entry-point：AOT 下防 tree-shake 剪除）。
@pragma('vm:entry-point')
void _searchIsolateMain(_SearchBootstrap boot) async {
  // FRB 每个 isolate 各自 init（内核书句柄绑定当前 isolate）：本函数跑在后台
  // isolate 里，不 init 则 `openBook` 抛「flutter_rust_bridge has not been
  // initialized」。失败不吞也不拦：下面的 open 会走格式层报错并经信封回传。
  try {
    await RustLib.init();
  } catch (_) {
    // 无原生库：交给 open 的格式层报错（文案单一来源）。
  }
  final CancelToken token = CancelToken();
  final ReceivePort control = ReceivePort();
  // 握手：先把反向控制通道给主侧（协议级取消的下发口）。
  boot.eventsPort.send(control.sendPort);
  control.listen((Object? message) {
    if (message == _kCancel) token.cancel();
  });

  BookSource? source;
  try {
    source = await openBook(
      fileName: boot.spec.fileName,
      bytes: boot.spec.bytes,
    );
    await for (final SearchEvent event
        in source.search(boot.query, cancel: token)) {
      if (token.isCancelled) break;
      boot.eventsPort.send(event);
    }
    boot.eventsPort.send(const _SearchDoneMsg());
  } on MReaderFormatException catch (e) {
    // 业务错误经信封回传（`PERF-01` 同款口径）：不是「派发失败」，不触发回落。
    boot.eventsPort.send(_SearchFailedMsg(e));
  } catch (e) {
    boot.eventsPort.send(_SearchCrashedMsg('$e'));
  } finally {
    await source?.dispose(); // 自建自毁（`PERF-02` 非驻留）
    control.close();
    // `RUST-05` ①：取消 / 完成后不留后台线程。
    Isolate.exit();
  }
}

class _IsolateRun implements _SearchRun {
  _IsolateRun({required this.query, required this.spec});

  final String query;
  final SearchBookSpec spec;

  _SessionSink? _sink;
  final ReceivePort _events = ReceivePort();
  SendPort? _control;
  bool _cancelRequested = false;
  bool _settled = false;

  @override
  void begin(_SessionSink sink) {
    _sink = sink;
    _events.listen(
      _onMessage,
      // 端口以「未 done」状态关闭 = 远端中途死亡：回落本 isolate 重跑。
      onDone: () {
        if (!_settled) {
          _settled = true;
          _fallback();
        }
      },
    );
    try {
      Isolate.spawn(
        _searchIsolateMain,
        _SearchBootstrap(
          spec: spec,
          query: query,
          eventsPort: _events.sendPort,
        ),
        debugName: 'mreader-search',
      );
    } catch (e) {
      // 派发失败：`RUST-01` 式回落——同一任务在本 isolate 现跑。
      _settled = true;
      log('搜索 isolate 派发失败，回落本 isolate：$e', name: 'mreader-search');
      _fallback();
    }
  }

  void _onMessage(Object? message) {
    final _SessionSink? sink = _sink;
    if (sink == null || _settled) return;
    if (message is SendPort) {
      _control = message;
      if (_cancelRequested) _control?.send(_kCancel); // 握手晚到的取消补发
    } else if (message is SearchEvent) {
      sink.add(message);
    } else if (message is _SearchDoneMsg) {
      _settled = true;
      _events.close();
      sink.done();
    } else if (message is _SearchFailedMsg) {
      _settled = true;
      _events.close();
      sink.fail(message.error);
    } else if (message is _SearchCrashedMsg) {
      _settled = true;
      _events.close();
      // `RUST-01`：回落事实只写调试日志（release 不输出）。
      log('搜索 isolate 远端意外，回落本 isolate：${message.detail}',
          name: 'mreader-search');
      _fallback();
    }
  }

  /// 本 isolate 回落重跑（派发失败 / 远端意外；语义与 `IsolateRunner.runWithFallback` 一致）。
  void _fallback() {
    final _SessionSink? sink = _sink;
    if (sink == null) return;
    _events.close();
    final _LocalRun fallback = _LocalRun(
      query: query,
      // 回落侧自建自毁源（与后台路径同一生命周期口径）。
      source: null,
      spec: spec,
      ownsSource: true,
    );
    _fallbackRun = fallback;
    if (_cancelRequested) {
      fallback.cancel();
    }
    // 复用同一泵口：会话级 done / fail 只收尾一次（`_finish` 有幂等守卫）。
    fallback.begin(sink);
  }

  _LocalRun? _fallbackRun;

  @override
  void cancel() {
    _cancelRequested = true;
    _control?.send(_kCancel);
    _fallbackRun?.cancel();
  }
}

// ---------------------------------------------------------------------------
// 本 isolate 流式路径（句柄源 / 回落重跑共用）
// ---------------------------------------------------------------------------

class _LocalRun implements _SearchRun {
  _LocalRun({
    required this.query,
    required this.source,
    this.spec,
    this.ownsSource = false,
  });

  final String query;

  /// 外部持有的句柄源（不 dispose）；与 [spec] 二选一。
  final BookSource? source;

  /// 回落时用 spec 在本 isolate 自建源（自建自毁）。
  final SearchBookSpec? spec;
  final bool ownsSource;

  _SessionSink? _sink;
  CancelToken? _token;
  bool _cancelRequested = false;

  @override
  void begin(_SessionSink sink) {
    _sink = sink;
    final CancelToken token = CancelToken();
    _token = token;
    if (_cancelRequested) token.cancel();
    unawaited(_run(token));
  }

  Future<void> _run(CancelToken token) async {
    final _SessionSink? sink = _sink;
    if (sink == null) return;
    BookSource? opened;
    try {
      final BookSource effective;
      final SearchBookSpec? spec = this.spec;
      final BookSource? held = source;
      if (held != null) {
        effective = held;
      } else if (spec != null) {
        opened = await openBook(
          fileName: spec.fileName,
          bytes: spec.bytes,
        );
        effective = opened;
      } else {
        sink.done();
        return;
      }
      await for (final SearchEvent event
          in effective.search(query, cancel: token)) {
        if (token.isCancelled) break;
        sink.add(event);
      }
      sink.done();
    } on MReaderFormatException catch (e) {
      sink.fail(e);
    } catch (e) {
      // 本 isolate 路径已是最后一站：远端意外语义不适用，错误直接上抛。
      sink.fail(e);
    } finally {
      if (ownsSource) {
        await opened?.dispose();
      }
    }
  }

  @override
  void cancel() {
    _cancelRequested = true;
    _token?.cancel();
  }
}

// ---------------------------------------------------------------------------
// 空会话兜底（无 query / 无源）
// ---------------------------------------------------------------------------

class _EmptyRun implements _SearchRun {
  const _EmptyRun();

  @override
  void begin(_SessionSink sink) => sink.done();

  @override
  void cancel() {}
}
