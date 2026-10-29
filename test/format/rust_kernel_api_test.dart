// 内核 ABI 8/9/10 新出口（章标题块 / 单章搜索 / 进度定位 / 偏移映射 / 选区取文 /
// 缩略图）的桥面契约（需原生库；无则运行期 `markTestSkipped`，不计失败）。
//
// 判据只钉**桥面语义**（坐标系同源 / 夹取 / 默认上限 / 缩放边界），内核内部
// 口径由 vendored `rrk-*` 自测钉（`rust/vendor/` 纪律：不在宿主侧重测内核）。
// 期望值从实际章文本推导，不硬编码偏移。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/highperf/high_perf_capability.dart';
import 'package:mreader/src/rust/api/guard.dart' show probe;
import 'package:mreader/src/rust/api/image.dart' as rki;
import 'package:mreader/src/rust/api/kernel.dart' as rk;
import 'package:mreader/src/rust/frb_generated.dart';

import 'epub_builder.dart';

/// FRB 可用性判别（与 `rust_kernel_source_test.dart` 同口径：二次 init 被拒时
/// 用同步 `probe()` 复核，防整组误判「无原生库」）。
bool? _kernelReady;

Future<bool> _ensureKernel() async {
  final bool? cached = _kernelReady;
  if (cached != null) return cached;
  try {
    await RustLib.init();
    return _kernelReady = true;
  } catch (_) {
    try {
      probe(); // 二次 init 被拒但内核在跑：probe 能回值即视为可用。
      return _kernelReady = true;
    } catch (_) {
      return _kernelReady = false;
    }
  }
}

/// 样本：单章 EPUB，标题 `<h1>` + 两段正文（其一带代理对字符，供偏移映射用）。
Uint8List _sampleEpub() => zipEntries(<EpubEntry>[
      textEntry('META-INF/container.xml', containerXml('OEBPS/content.opf')),
      textEntry(
        'OEBPS/content.opf',
        opfXml(
          title: '新出口样本',
          manifest: itemXml('c1', 'text/ch1.xhtml', 'application/xhtml+xml'),
          spine: itemrefXml('c1'),
        ),
      ),
      textEntry(
        'OEBPS/text/ch1.xhtml',
        xhtmlDoc(
          title: '新出口样本',
          heading: '第一章',
          paragraphs: <String>['正文一。', '正文二😀。'],
        ),
      ),
    ]);

// ---------------------------------------------------------------------------
// 手搓 PNG（RGBA，zlib stored 块）：免外部依赖、可解码、像素可辨识。
// ---------------------------------------------------------------------------

int _crc32(List<int> data) {
  int crc = 0xFFFFFFFF;
  for (final int b in data) {
    crc ^= b;
    for (int i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

int _adler32(List<int> data) {
  int a = 1, b = 0;
  for (final int x in data) {
    a = (a + x) % 65521;
    b = (b + a) % 65521;
  }
  return ((b << 16) | a) & 0xFFFFFFFF;
}

Uint8List _pngRgba(int w, int h) {
  final BytesBuilder raw = BytesBuilder();
  for (int y = 0; y < h; y++) {
    raw.addByte(0); // 滤波字节 = None
    for (int x = 0; x < w; x++) {
      raw.add(<int>[x * 40, y * 40, 128, 255]);
    }
  }
  final Uint8List rawBytes = raw.toBytes();
  final int n = rawBytes.length;
  final BytesBuilder z = BytesBuilder()
    ..add(<int>[0x78, 0x01]) // zlib 头：无字典、最快
    ..add(<int>[0x01, n & 0xFF, (n >> 8) & 0xFF, (~n) & 0xFF, ((~n) >> 8) & 0xFF])
    ..add(rawBytes);
  final int ad = _adler32(rawBytes);
  z.add(<int>[(ad >> 24) & 0xFF, (ad >> 16) & 0xFF, (ad >> 8) & 0xFF, ad & 0xFF]);

  Uint8List chunk(String type, Uint8List data) {
    final Uint8List t = ascii.encode(type);
    final BytesBuilder b = BytesBuilder()
      ..add(<int>[
        (data.length >> 24) & 0xFF,
        (data.length >> 16) & 0xFF,
        (data.length >> 8) & 0xFF,
        data.length & 0xFF,
      ])
      ..add(t)
      ..add(data);
    final int crc = _crc32(<int>[...t, ...data]);
    b.add(<int>[(crc >> 24) & 0xFF, (crc >> 16) & 0xFF, (crc >> 8) & 0xFF, crc & 0xFF]);
    return b.toBytes();
  }

  final BytesBuilder png = BytesBuilder()
    ..add(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(chunk('IHDR', Uint8List.fromList(<int>[
      (w >> 24) & 0xFF, (w >> 16) & 0xFF, (w >> 8) & 0xFF, w & 0xFF,
      (h >> 24) & 0xFF, (h >> 16) & 0xFF, (h >> 8) & 0xFF, h & 0xFF,
      8, 6, 0, 0, 0, // 8bit RGBA
    ])))
    ..add(chunk('IDAT', z.toBytes()))
    ..add(chunk('IEND', Uint8List(0)));
  return png.toBytes();
}

void main() {
  group('内核新出口（ABI 8/9/10）', () {
    test('探针版本三方一致（package = probe = kRustAbiVersion）', () async {
      if (!await _ensureKernel()) {
        markTestSkipped('原生库不可用，跳过探针版本判据');
        return;
      }
      expect(probe(), kRustAbiVersion);
    });

    test('章标题块轻量出口：h1 → (level, text)，无标题章空表', () async {
      if (!await _ensureKernel()) {
        markTestSkipped('原生库不可用，跳过章标题块出口');
        return;
      }
      final BigInt h = await rk.kernelOpenBytes(name: 'a.epub', data: _sampleEpub());
      final int id = (await rk.kernelChapters(handle: h)).first.id;
      final List<rk.RkHeading> hs =
          await rk.kernelChapterHeadings(handle: h, chapterId: id);
      expect(hs, hasLength(1));
      expect(hs.first.level, 1);
      expect(hs.first.text, '第一章');
      // 不存在的章 id 报错而非空表（非法句柄同口径）。
      await expectLater(
        rk.kernelChapterHeadings(handle: h, chapterId: 999),
        throwsA(anything),
      );
      await rk.kernelClose(handle: h);
    });

    test('单章搜索：坐标与选区取文同源，maxHits 截断', () async {
      if (!await _ensureKernel()) {
        markTestSkipped('原生库不可用，跳过单章搜索');
        return;
      }
      final BigInt h = await rk.kernelOpenBytes(name: 'a.epub', data: _sampleEpub());
      final int id = (await rk.kernelChapters(handle: h)).first.id;
      final rk.RkSearchPage page = await rk.kernelSearchChapter(
        handle: h,
        chapterId: id,
        query: '正文',
        caseSensitive: false,
        contextChars: 0,
        maxHits: 0,
      );
      expect(page.scanned, 1, reason: '单章同步扫完');
      expect(page.total, 1);
      expect(page.hits, hasLength(2)); // 「正文一。」「正文二😀。」
      final rk.RkSearchHit first = page.hits.first;
      final String hit = await rk.kernelSliceText(
        handle: h,
        chapter: id,
        start: first.offset,
        end: first.offset + first.len,
      );
      expect(hit, '正文');
      expect(first.snippet, contains('正文'));

      final rk.RkSearchPage one = await rk.kernelSearchChapter(
        handle: h,
        chapterId: id,
        query: '正文',
        caseSensitive: false,
        contextChars: 0,
        maxHits: 1,
      );
      expect(one.hits, hasLength(1));

      final rk.RkSearchPage none = await rk.kernelSearchChapter(
        handle: h,
        chapterId: id,
        query: '不存在词组',
        caseSensitive: false,
        contextChars: 0,
        maxHits: 0,
      );
      expect(none.hits, isEmpty);
      await rk.kernelClose(handle: h);
    });

    test('进度 ↔ 定位互转（估算口径互逆、越界夹取）', () async {
      if (!await _ensureKernel()) {
        markTestSkipped('原生库不可用，跳过进度/定位');
        return;
      }
      final BigInt h = await rk.kernelOpenBytes(name: 'a.epub', data: _sampleEpub());
      final int id = (await rk.kernelChapters(handle: h)).first.id;
      expect(
        await rk.kernelProgressOf(handle: h, chapter: id, byteOffset: 0),
        closeTo(0.0, 1e-6),
      );
      final rk.RkLocation loc0 = await rk.kernelLocate(handle: h, percent: 0);
      expect(loc0.chapter, id);
      expect(loc0.byteOffset, 0);

      final rk.RkLocation mid = await rk.kernelLocate(handle: h, percent: 0.5);
      final double pmid = await rk.kernelProgressOf(
          handle: h, chapter: mid.chapter, byteOffset: mid.byteOffset);
      expect(pmid, closeTo(0.5, 0.01));

      // 越界夹取：负数/超 1 都落 [0,1]。
      expect(await rk.kernelProgressOf(handle: h, chapter: id, byteOffset: 1 << 30),
          closeTo(1.0, 1e-6));
      final rk.RkLocation locEnd = await rk.kernelLocate(handle: h, percent: 2);
      expect(locEnd.chapter, id);
      await rk.kernelClose(handle: h);
    });

    test('UTF-16 偏移映射：代理对双向 + 中间取对首', () async {
      if (!await _ensureKernel()) {
        markTestSkipped('原生库不可用，跳过偏移映射');
        return;
      }
      final BigInt h = await rk.kernelOpenBytes(name: 'a.epub', data: _sampleEpub());
      final int id = (await rk.kernelChapters(handle: h)).first.id;
      final String text =
          (await rk.kernelLoadChapter(handle: h, chapterId: id)).text;
      final List<int> bytes = utf8.encode(text);

      final Uint32List ends = await rk.kernelMapOffsets(
          handle: h, chapter: id, toUtf16: true, offsets: <int>[0, bytes.length]);
      expect(ends[0], 0);
      expect(ends[1], text.length);

      final int emojiU16 = text.indexOf('😀');
      expect(emojiU16, greaterThanOrEqualTo(0), reason: '样本应含代理对字符');
      final int emojiByte = utf8.encode(text.substring(0, emojiU16)).length;
      final Uint32List u = await rk.kernelMapOffsets(
          handle: h,
          chapter: id,
          toUtf16: true,
          offsets: <int>[emojiByte, emojiByte + 4]);
      expect(u[0], emojiU16);
      expect(u[1] - u[0], 2); // 😀 = 4 字节 / 2 UTF-16 单元

      // UTF-16 → 字节：落在代理对中间取对首。
      final Uint32List back = await rk.kernelMapOffsets(
          handle: h, chapter: id, toUtf16: false, offsets: <int>[u[0] + 1]);
      expect(back[0], emojiByte);
      await rk.kernelClose(handle: h);
    });

    test('选区取文：字符边界两头夹齐 + 越界返回空', () async {
      if (!await _ensureKernel()) {
        markTestSkipped('原生库不可用，跳过选区取文');
        return;
      }
      final BigInt h = await rk.kernelOpenBytes(name: 'a.epub', data: _sampleEpub());
      final int id = (await rk.kernelChapters(handle: h)).first.id;
      final String text =
          (await rk.kernelLoadChapter(handle: h, chapterId: id)).text;
      final int emojiU16 = text.indexOf('😀');
      final int emojiByte = utf8.encode(text.substring(0, emojiU16)).length;

      // 😀 中间的半个字节区间 → 两头夹齐返回整字符。
      final String s = await rk.kernelSliceText(
          handle: h, chapter: id, start: emojiByte + 1, end: emojiByte + 2);
      expect(s, '😀');

      expect(
        await rk.kernelSliceText(
            handle: h, chapter: id, start: 1 << 30, end: (1 << 30) + 10),
        isEmpty,
      );
      await rk.kernelClose(handle: h);
    });

    test('图片缩略图：等比缩放 + 不缩仅解码 + 坏字节报错', () async {
      if (!await _ensureKernel()) {
        markTestSkipped('原生库不可用，跳过缩略图');
        return;
      }
      final rki.RkThumbnail small =
          await rki.imageThumbnail(data: _pngRgba(2, 2), maxEdge: 1);
      expect(small.width, 1);
      expect(small.height, 1);
      expect(small.rgba, hasLength(4));

      final rki.RkThumbnail same =
          await rki.imageThumbnail(data: _pngRgba(2, 2), maxEdge: 100);
      expect(same.width, 2);
      expect(same.height, 2);
      expect(same.rgba, hasLength(2 * 2 * 4));

      await expectLater(
        rki.imageThumbnail(data: Uint8List.fromList(<int>[1, 2, 3]), maxEdge: 8),
        throwsA(anything),
      );
    });

    test('内容缓存统计含 open 命中段（open 索引持久化）', () async {
      if (!await _ensureKernel()) {
        markTestSkipped('原生库不可用，跳过 open 缓存统计');
        return;
      }
      final Directory dir = await Directory.systemTemp.createTemp('rk_open_cache');
      try {
        rk.kernelCacheConfigure(dir: dir.path, memBytes: BigInt.from(1 << 20));
        final Uint8List bytes = _sampleEpub();
        final BigInt h1 = await rk.kernelOpenBytes(name: 'a.epub', data: bytes);
        await rk.kernelClose(handle: h1);
        final BigInt h2 = await rk.kernelOpenBytes(name: 'a.epub', data: bytes);
        await rk.kernelClose(handle: h2);
        final rk.RkCacheStats s = rk.kernelCacheStats();
        expect(s.openHits + s.openMisses, greaterThan(BigInt.zero),
            reason: '应有 open 索引计数');
        expect(s.openHits, greaterThanOrEqualTo(BigInt.one),
            reason: '同内容重开应命中 open 缓存');
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
