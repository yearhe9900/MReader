// `test/search/` 共享搜索假源（非 `*_test.dart`，不会被 `flutter test` 当用例执行）。
//
// ⚠️ 契约：这些假源的 `searchSpec` 恒为 `null`（继承 `FakeBookSource` 的默认实现），
// 搜索一律走 `SearchSession` 的**本 isolate 流式路径**——widget 测试**禁用后台
// isolate 路径**：`testWidgets` 的 FakeAsync 区不排空 isolate 消息（真异步 IO
// 挂死坑，见 reader_harness 头注），spawn 真后台 isolate 的用例只存在于纯 `test()`
// 的 `search_session_test.dart`。
import 'dart:async';

import 'package:mreader/format/book_source.dart';

import '../reader/reader_harness.dart';

/// 命中样本（人工推演后写死，防假绿）。
SearchHit fakeHit({
  required int chapterIndex,
  required String chapterTitle,
  required int offset,
  required String context,
}) =>
    SearchHit(
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
      offset: offset,
      context: context,
    );

/// 事件回放式搜索假源：`search()` 按序回放 [events]（微任务派发，
/// FakeAsync 下 `pump` / [settle] 即推进）；[error] 非空时改以错误收尾。
///
/// 段落内容沿用 [FakeBookSource] 的 `'第N章正文P'` 模板（可经 `paragraphCounts`
/// 注入章数），供「offset → 段落下标换算」类推演对表。
class StubSearchSource extends FakeBookSource {
  StubSearchSource({
    this.events = const <SearchEvent>[],
    this.error,
    super.paragraphCounts,
    super.hangIndices,
    super.gates,
  });

  /// 按序回放的搜索事件。
  final List<SearchEvent> events;

  /// 非空时 `search()` 以该错误收尾（错误文案展示断言用）。
  final Object? error;

  /// `search()` 被调用次数（空词不发起 / 重复提交断言用）。
  int searchCalls = 0;

  /// 每次 `search()` 收到的取消令牌（「取消已下传」断言用）。
  final List<CancelToken> cancels = <CancelToken>[];

  @override
  Stream<SearchEvent> search(String query, {required CancelToken cancel}) {
    searchCalls++;
    cancels.add(cancel);
    if (error != null) {
      return Stream<SearchEvent>.error(error!);
    }
    return Stream<SearchEvent>.fromIterable(events);
  }
}

/// 手动推流的搜索假源：测试逐条 [StreamController.add] / `close` 控制时序
/// （「搜索中可取消」「重复提交」「dispose 取消」类断言用）。
class ControlledSearchSource extends FakeBookSource {
  ControlledSearchSource({super.paragraphCounts});

  /// 手动推流口；测试负责（或 [dispose] 时）关闭。
  final StreamController<SearchEvent> controller =
      StreamController<SearchEvent>();

  int searchCalls = 0;
  final List<CancelToken> cancels = <CancelToken>[];

  @override
  Stream<SearchEvent> search(String query, {required CancelToken cancel}) {
    searchCalls++;
    cancels.add(cancel);
    return controller.stream;
  }

  @override
  Future<void> dispose() async {
    await controller.close();
    await super.dispose();
  }
}

/// 图片页搜索假源（CBZ / PDF 出图路径）：`content()` 恒返回 [ChapterContent.imagePages]，
/// 「命中 → 跳转」应走纯跳章（无段落可换算，`paraIndex = -1`）。
///
/// `readResource` 沿用 [FakeBookSource] 的 `null`（图片加载失败走占位图标，不崩即可）。
class StubImagePageSource extends FakeBookSource {
  StubImagePageSource({this.events = const <SearchEvent>[]});

  final List<SearchEvent> events;
  int searchCalls = 0;
  final List<CancelToken> cancels = <CancelToken>[];

  @override
  Future<ChapterContent> content(int chapterIndex) async =>
      ChapterContent.imagePages(<String>['img-$chapterIndex.png']);

  @override
  Stream<SearchEvent> search(String query, {required CancelToken cancel}) {
    searchCalls++;
    cancels.add(cancel);
    return Stream<SearchEvent>.fromIterable(events);
  }
}
