// `M3-T02`：生词本存储持久化（`AI-03` ②「退出重进仍在」的数据侧）。
//
// 形制同 `provider_store_test`：临时目录 + 新实例重载验证落盘；
// 另覆盖坏条目跳过 / 损坏文件回退空表 / 同 id 幂等覆盖 / 监听通知。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/vocab_store.dart';

VocabEntry _entry(
  String id, {
  String word = '词',
  String meaning = '释义',
  String bookId = 'b1',
  int paraIndex = 2,
  DateTime? createdAt,
}) {
  return VocabEntry(
    id: id,
    word: word,
    meaning: meaning,
    bookId: bookId,
    bookTitle: '书名',
    chapterHref: 'h1',
    paraIndex: paraIndex,
    createdAt: createdAt ?? DateTime.fromMillisecondsSinceEpoch(1700000000000),
  );
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mreader_vocab_');
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  VocabStore newStore() => VocabStore(dir);

  File vocabFile() =>
      File('${dir.path}${Platform.pathSeparator}vocab.json');

  test('add → 新实例 load：字段保真，落盘为 List', () async {
    final VocabStore store = newStore();
    await store.load();
    await store.add(_entry('e1', word: 'serendipity', meaning: '意外之喜'));

    final VocabStore reloaded = newStore();
    await reloaded.load();
    expect(reloaded.entries, hasLength(1));
    final VocabEntry e = reloaded.entries.single;
    expect(e.id, 'e1');
    expect(e.word, 'serendipity');
    expect(e.meaning, '意外之喜');
    expect(e.bookId, 'b1');
    expect(e.bookTitle, '书名');
    expect(e.chapterHref, 'h1');
    expect(e.paraIndex, 2);
    expect(e.createdAt.millisecondsSinceEpoch, 1700000000000);
    expect(vocabFile().readAsStringSync(), startsWith('['));
  });

  test('remove：按 id 删除并落盘；不存在的 id 静默', () async {
    final VocabStore store = newStore();
    await store.load();
    await store.add(_entry('e1'));
    await store.add(_entry('e2'));
    await store.remove('e1');
    expect(store.entries.map((VocabEntry e) => e.id), <String>['e2']);
    await store.remove('nope'); // 静默，不抛。
    expect(store.entries, hasLength(1));

    final VocabStore reloaded = newStore();
    await reloaded.load();
    expect(reloaded.entries.map((VocabEntry e) => e.id), <String>['e2']);
  });

  test('新条目插到最前（最新在前）', () async {
    final VocabStore store = newStore();
    await store.load();
    await store.add(_entry('old', createdAt: DateTime.fromMillisecondsSinceEpoch(1)));
    await store.add(
      _entry('new', createdAt: DateTime.fromMillisecondsSinceEpoch(2)),
    );
    expect(store.entries.first.id, 'new');
  });

  test('同 id 覆盖不产生重复（语义幂等）', () async {
    final VocabStore store = newStore();
    await store.load();
    await store.add(_entry('e1', meaning: '旧'));
    await store.add(_entry('e1', meaning: '新'));
    expect(store.entries, hasLength(1));
    expect(store.entries.single.meaning, '新');
  });

  test('坏条目跳过、好条目保留', () async {
    vocabFile().writeAsStringSync(jsonEncode(<Object?>[
      <String, Object?>{'id': '', 'word': 'x'}, // 缺字段 / id 空 → 丢弃
      'not-a-map', // 非对象 → 丢弃
      _entry('ok').toJson(),
      <String, Object?>{'id': 'x2'}, // 缺 word/meaning → 丢弃
    ]));
    final VocabStore store = newStore();
    await store.load();
    expect(store.entries.map((VocabEntry e) => e.id), <String>['ok']);
    expect(store.isLoaded, isTrue);
  });

  test('文件损坏（非 List）→ 回退空表不抛', () async {
    vocabFile().writeAsStringSync('{corrupt!!');
    final VocabStore store = newStore();
    await store.load();
    expect(store.entries, isEmpty);
    expect(store.isLoaded, isTrue);
  });

  test('文件缺失 → 空表；load 后可正常 add', () async {
    final VocabStore store = newStore();
    expect(store.isLoaded, isFalse);
    await store.load();
    expect(store.entries, isEmpty);
    await store.add(_entry('e1'));
    expect(store.entries, hasLength(1));
  });

  test('监听：add / remove 都通知；removeListener 后不再通知', () async {
    final VocabStore store = newStore();
    await store.load();
    int fired = 0;
    void listener() => fired++;
    store.addListener(listener);
    await store.add(_entry('e1'));
    expect(fired, 1);
    await store.remove('e1');
    expect(fired, 2);
    store.removeListener(listener);
    await store.add(_entry('e2'));
    expect(fired, 2);
  });
}
