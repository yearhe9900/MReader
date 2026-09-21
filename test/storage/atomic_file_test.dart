// 原子写入与 JSON 回退语义单测（PRD `DATA-01`）。
//
// 覆盖四种关键情形：
//   ① 正常写入后可读回；
//   ② 「写完临时文件但未替换」后读回退 `.bak` / 仍返回当前有效内容；
//   ③ JSON 损坏时回退 `.bak` 并另存 `.corrupt`；
//   ④ Windows 下目标已存在时的替换路径（轮转式 rename）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/storage/atomic_file.dart';
import 'package:mreader/storage/json_store.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mreader_atomic_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  group('AtomicFile 原子写入', () {
    test('① 正常写入后可读回，且不残留临时文件', () async {
      final AtomicFile file = AtomicFile('${tmp.path}/a.json');
      await file.writeString('{"v":1}');

      expect(await file.readString(), '{"v":1}');
      expect(await File(file.tempPath).exists(), isFalse);
    });

    test('④ 目标已存在时仍可替换（轮转式 rename，兼容 Windows）', () async {
      final AtomicFile file = AtomicFile('${tmp.path}/b.json');
      await file.writeString('v1');
      await file.writeString('v2');

      expect(await file.readString(), 'v2');
      // 上一份有效副本进入 .bak。
      expect(await file.hasBackup(), isTrue);
      expect(await File(file.backupPath).readAsString(), 'v1');
      // 未残留临时文件。
      expect(await File(file.tempPath).exists(), isFalse);
    });
  });

  group('JsonStore 回退语义', () {
    test('② 写完临时文件但未替换时，读取仍返回当前有效内容', () async {
      final AtomicFile file = AtomicFile('${tmp.path}/c.json');
      final JsonStore store = JsonStore(file);
      await store.write(<String, Object?>{'v': 1});

      // 模拟：新一次写入只完成了临时文件，尚未替换目标（甚至临时文件是半截的）。
      await File(file.tempPath).writeAsString('{"v":2');

      expect(await store.read(), <String, Object?>{'v': 1});
    });

    test('② 目标缺失但存在 .bak 时，回退上一份有效副本并自愈', () async {
      final AtomicFile file = AtomicFile('${tmp.path}/d.json');
      final JsonStore store = JsonStore(file);
      await store.write(<String, Object?>{'v': 1});
      await store.write(<String, Object?>{'v': 2}); // main=v2, bak=v1

      // 模拟：轮转后、改名到目标前断电 → 目标缺失，仅剩备份。
      await File(file.path).delete();

      expect(await store.read(), <String, Object?>{'v': 1});
      // 回退后应自愈：目标被备份内容恢复。
      expect(await File(file.path).exists(), isTrue);
    });

    test('③ JSON 损坏时回退 .bak，并把损坏文件另存为 .corrupt', () async {
      final AtomicFile file = AtomicFile('${tmp.path}/e.json');
      final JsonStore store = JsonStore(file);
      await store.write(<String, Object?>{'v': 1});
      await store.write(<String, Object?>{'v': 2}); // main=v2, bak=v1

      // 写坏目标文件（模拟写入中途断电产生的半截内容）。
      await File(file.path).writeAsString('{not json');

      expect(await store.read(), <String, Object?>{'v': 1});
      expect(await File(file.corruptPath).exists(), isTrue);
    });

    test('无主文件也无 .bak 时返回 null（确实没有数据）', () async {
      final JsonStore store = JsonStore(AtomicFile('${tmp.path}/f.json'));
      expect(await store.read(), isNull);
    });

    test('并发写入同一文件不产生半截文件', () async {
      final AtomicFile file = AtomicFile('${tmp.path}/g.json');
      final JsonStore store = JsonStore(file);

      await Future.wait<void>(<Future<void>>[
        for (int i = 0; i < 50; i++)
          store.write(<String, Object?>{'i': i}),
      ]);

      final Object? value = await store.read();
      expect(value, isA<Map<Object?, Object?>>());
      expect((value! as Map<Object?, Object?>)['i'], isA<int>());
    });
  });
}
