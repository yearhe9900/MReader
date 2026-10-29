// 架构文档 / 排期声明的 `lib/meta/book_meta.dart` 路径。
//
// **仅一行 re-export**（架构 §N.1）：`BookMeta`（连同 `MetaOrigin` / `CoverFormat` /
// `CoverRef` 一族 / `BookMetaAuto`）的**唯一物理定义**在 `lib/model/book_meta.dart`，
// 本文件**不是第二定义**（与 `chapter.dart` 的既有做法同构）。
export '../model/book_meta.dart';
