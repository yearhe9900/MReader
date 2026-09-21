// `META-04`：TXT 文件名规则链（命中即停）+ 清洗 + 兜底。
//
// 期望值取自 `.scratch/probe_meta.dart` 实测。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/meta/txt_meta.dart';
import 'package:mreader/model/book_meta.dart';

void main() {
  group('parseFileNameStem（规则链，命中即停）', () {
    test('① 《书名》…作者：X', () {
      final FileNameMeta m = parseFileNameStem('《三体》作者：刘慈欣');
      expect(m.title, '三体');
      expect(m.author, '刘慈欣');
    });

    test('② 《书名》…（无作者）', () {
      final FileNameMeta m = parseFileNameStem('《活着》');
      expect(m.title, '活着');
      expect(m.author, '');
    });

    test('③ 书名 作者：X', () {
      final FileNameMeta m = parseFileNameStem('斗破苍穹 作者：天蚕土豆');
      expect(m.title, '斗破苍穹');
      expect(m.author, '天蚕土豆');
    });

    test('④ 书名 by X', () {
      final FileNameMeta m = parseFileNameStem('活着 by 余华');
      expect(m.title, '活着');
      expect(m.author, '余华');
    });

    test('书名与作者恰好等长的构造用例不被误丢弃', () {
      // 「书名占位被移除后作者候选非空且与原文不同」——不得用长度判据。
      final FileNameMeta m = parseFileNameStem('书名作者：书名');
      expect(m.title, '书名');
      expect(m.author, '书名');
    });

    test('⑤ 清洗兜底：剥「… 著」尾巴', () {
      expect(parseFileNameStem('余华著').title, '余华');
      expect(parseFileNameStem('红楼梦').title, '红楼梦');
    });
  });

  group('buildTxtMeta（META-04 + META-01）', () {
    test('《三体》作者：刘慈欣.txt -> 书名/作者均来自 filename', () {
      final BookMeta m = buildTxtMeta(fileName: '《三体》作者：刘慈欣.txt');
      expect(m.title, '三体');
      expect(m.titleOrigin, MetaOrigin.filename);
      expect(m.author, '刘慈欣');
      expect(m.authorOrigin, MetaOrigin.filename);
    });

    test('活着 by 余华.txt', () {
      final BookMeta m = buildTxtMeta(fileName: '活着 by 余华.txt');
      expect(m.title, '活着');
      expect(m.author, '余华');
    });

    test('红楼梦.txt：作者缺失 -> 未知作者 且来源 none', () {
      final BookMeta m = buildTxtMeta(fileName: '红楼梦.txt');
      expect(m.title, '红楼梦');
      expect(m.author, '未知作者');
      expect(m.authorOrigin, MetaOrigin.none);
    });

    test('带目录的路径也能解析（Windows 反斜杠）', () {
      final BookMeta m =
          buildTxtMeta(fileName: r'D:\books\斗破苍穹 作者：天蚕土豆.txt');
      expect(m.title, '斗破苍穹');
      expect(m.author, '天蚕土豆');
    });

    test('.txt（无有效书名）：书名兜底「未命名书籍」', () {
      final BookMeta m = buildTxtMeta(fileName: '.txt');
      expect(m.title, '未命名书籍');
      expect(m.titleOrigin, MetaOrigin.none);
      expect(m.author, '未知作者');
    });

    test('TXT 无内嵌封面 / 简介：cover = NoCover，intro 空且来源 none', () {
      final BookMeta m = buildTxtMeta(fileName: '红楼梦.txt');
      expect(m.cover, isA<NoCover>());
      expect(m.coverOrigin, MetaOrigin.none);
      expect(m.intro, '');
      expect(m.introOrigin, MetaOrigin.none);
      expect(m.language, '');
    });

    test('auto 快照由解析写入且恒非空', () {
      final BookMeta m = buildTxtMeta(fileName: '《三体》作者：刘慈欣.txt');
      expect(m.auto, isNotNull);
      expect(m.auto!.title, '三体');
      expect(m.auto!.author, '刘慈欣');
    });
  });
}
