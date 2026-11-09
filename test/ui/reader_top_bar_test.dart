// §2.122 顶栏胶囊（`ReaderTopBar`）契约：两枚 `MiFloatingActionButton`
// 圆钮 + 中间「章节名 · 进度」，且**不引 `BackdropFilter`**。
//
// ⚠️ 负向护栏：胶囊的玻璃观感只能由半透明纯色表达；谁把 `BackdropFilter`
// 加回阅读页顶栏，正文两态就不全清晰了（§2.121）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ui/mi_like_ui/mi_like_ui.dart';
import 'package:mreader/ui/reader_control_chrome.dart';

import '../test_config.dart';

void main() {
  capTestTimeout();

  int backTaps = 0;
  int ttsTaps = 0;

  Future<void> pumpTopBar(WidgetTester tester) async {
    backTaps = 0;
    ttsTaps = 0;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.black,
          automaticallyImplyLeading: false,
          titleSpacing: 0,
          title: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: ReaderTopBar(
              statusText: '第十六章 · 21%',
              onBack: () => backTaps++,
              mode: MiThemeMode.dark,
              ttsButton: MiFloatingActionButton(
                key: const Key('reader-control-tts'),
                size: kReaderTopBarButtonSize,
                showShadow: false,
                color: Colors.grey,
                themeMode: MiThemeMode.dark,
                onPressed: () => ttsTaps++,
                child: const Icon(Icons.headphones, size: 19),
              ),
            ),
          ),
          actions: const <Widget>[],
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('§2.122 阅读页顶栏胶囊', () {
    testWidgets('两端各一枚 MiFloatingActionButton，中间只显示章节名 + 进度',
        (WidgetTester tester) async {
      await pumpTopBar(tester);

      expect(find.byKey(const Key('reader-top-bar')), findsOneWidget);
      expect(find.byType(MiFloatingActionButton), findsNWidgets(2),
          reason: '左返回 + 右听书，两枚圆钮都必须是 MiFloatingActionButton');
      expect(find.byKey(const Key('reader-top-back')), findsOneWidget);
      expect(find.byKey(const Key('reader-control-tts')), findsOneWidget);
      expect(find.text('第十六章 · 21%'), findsOneWidget);
      expect(find.byKey(const Key('reader-top-title')), findsOneWidget);
      final Rect title =
          tester.getRect(find.byKey(const Key('reader-top-title')));
      expect(title.width, greaterThan(120),
          reason: '中间章节读数不得被两端圆钮 / AppBar 默认 titleSpacing 挤没');
      expect(tester.getSize(find.byType(ReaderTopBar)).height,
          kReaderTopBarHeight);
    });

    testWidgets('玻璃观感不靠 BackdropFilter（正文两态全清晰）',
        (WidgetTester tester) async {
      await pumpTopBar(tester);

      expect(find.byType(BackdropFilter), findsNothing,
          reason: '§2.121 阅读页整树零 BackdropFilter');
      final DecoratedBox capsule = tester.widget<DecoratedBox>(
          find.byKey(const Key('reader-top-bar')));
      final ShapeDecoration decoration = capsule.decoration as ShapeDecoration;
      expect(decoration.shape, isA<StadiumBorder>(),
          reason: '顶栏应是圆角胶囊，不是满宽 Material 底');
      expect(decoration.color!.a, lessThan(1.0),
          reason: '导航层玻璃 = 半透明表面叠在 AppBar 的不透明底色上');
      expect(decoration.color!.a, greaterThan(0.8),
          reason: '过透会让正文首行从标题背后透出来');
    });

    testWidgets('两枚圆钮各自可点，回调不串', (WidgetTester tester) async {
      await pumpTopBar(tester);

      await tester.tap(find.byKey(const Key('reader-top-back')));
      await tester.pump();
      expect(backTaps, 1);
      expect(ttsTaps, 0);

      await tester.tap(find.byKey(const Key('reader-control-tts')));
      await tester.pump();
      expect(ttsTaps, 1);
      expect(backTaps, 1);
    });
  });
}
