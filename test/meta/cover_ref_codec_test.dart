// `lib/meta/cover_ref_codec.dart` 单测：封面引用的 round-trip + PendingCover 护栏。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/meta/cover_ref_codec.dart';
import 'package:mreader/model/book_meta.dart';

void main() {
  test('round-trip（经 JSON encode/decode）保持类型与载荷', () {
    final String fileJson =
        jsonEncode(encodeCoverRef(const StoredCover('ab.cover.png')));
    final StoredCover file = decodeCoverRef(jsonDecode(fileJson)) as StoredCover;
    expect(file.fileName, 'ab.cover.png');

    final SyntheticCover synth = decodeCoverRef(
      jsonDecode(jsonEncode(encodeCoverRef(const SyntheticCover('sc_1'))))) as SyntheticCover;
    expect(synth.cacheKey, 'sc_1');

    expect(
      decodeCoverRef(jsonDecode(jsonEncode(encodeCoverRef(const NoCover())))),
      isA<NoCover>(),
    );
  });

  test('JSON 形状：kind ∈ {file, synthetic, none}', () {
    expect(encodeCoverRef(const StoredCover('x.cover.png')),
        <String, Object?>{'kind': 'file', 'fileName': 'x.cover.png'});
    expect(encodeCoverRef(const SyntheticCover('k')),
        <String, Object?>{'kind': 'synthetic', 'cacheKey': 'k'});
    expect(encodeCoverRef(const NoCover()), <String, Object?>{'kind': 'none'});
  });

  test('持久化不得含 PendingCover：序列化器直接抛 StateError（§N.5）', () {
    final PendingCover pending =
        PendingCover(Uint8List.fromList(<int>[1, 2, 3]), CoverFormat.png);
    expect(() => encodeCoverRef(pending), throwsStateError);
  });

  test('未知 kind 抛 FormatException', () {
    expect(
      () => decodeCoverRef(<String, Object?>{'kind': 'wat'}),
      throwsFormatException,
    );
    expect(() => decodeCoverRef('not-a-map'), throwsFormatException);
  });
}
