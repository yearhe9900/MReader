// 架构文档 / 排期声明的 `lib/meta/book_meta.dart` 路径。
//
// **仅一行 re-export**（架构 §N.1）：`BookMeta`（连同一批类型：`MetaOrigin` /
// `CoverFormat` / `CoverRef` 一族 / `BookMetaAuto`）的**唯一物理定义**在
// `lib/model/book_meta.dart`。本文件**不是第二定义**——三处路径
// （`lib/model/book_meta.dart` / `lib/format/book_source.dart` / 本文件）
// 指向**同一份**类型，**物理上不可能再出现第二份**（与 `chapter.dart` 的既有做法同构）。
export '../model/book_meta.dart';
