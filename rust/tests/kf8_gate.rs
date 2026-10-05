//! `M35-T03` ③ —— `mobi` 0.8.0 crate 的 **KF8 最小验证**（gate 三项必做之一）。
//!
//! 判据（PRD §15.6.4 v2.6 补录）：合法 KF8 有两种入口，**两类文件各测一次**——
//! ① `mobiHeader.version >= 8` 直入；② KF6 的 EXTH 121 boundary 记录号跳转
//! 重读头（失败回落 KF6）。
//!
//! 样本（`tmp_book/`，gitignored 不入库；缺席则整测跳过）：
//! ① `*.azw3` —— 纯 KF8（version=8 直入；M2b-T05 基线：牧神记 24,077,744 B）；
//! ② `*.mobi` —— combo（KF6 @record0 + KF8 @ EXTH121 boundary=5281；
//!    基线：最强反派系统 24,404,252 B）。
//!
//! **性质 = 结论留档探针，不是回归护栏**：只断言稳定事实（能打开、header
//! 自洽、EXTH 121 在场）；正文解码用 `catch_unwind` 接住 crate 内 panic 并打印
//! ——crate 对 KF8 的支持现状本身就是本次要测的**结论**，由每条 `GATE[KF8]`
//! 判语行留档，不以红测形式入库。
//!
//! 配套源码实证（对照 0.8.0 源码）：crate **无 INDX/TOC 章节列表 API**、
//! **无 EXTH121 跳转逻辑**（`exth.rs` 仅把 121 映射为枚举）——运行时证据见
//! 判语行 `jumped=NO`。
//!
//! 复现：`cargo test --test kf8_gate -- --nocapture`
//! 样本目录可用环境变量 `MREADER_TMP_BOOK` 覆盖（默认 = `../tmp_book`）。

use std::path::{Path, PathBuf};

use mobi::headers::ExthRecord;
use mobi::Mobi;

fn fixture_dir() -> PathBuf {
    std::env::var("MREADER_TMP_BOOK")
        .map(PathBuf::from)
        .unwrap_or_else(|_| Path::new(env!("CARGO_MANIFEST_DIR")).join("../tmp_book"))
}

/// 取目录内指定扩展名的首个文件（排序后取一，保证可复现）。
fn find_ext(ext: &str) -> Option<PathBuf> {
    let entries = std::fs::read_dir(fixture_dir()).ok()?;
    let mut found: Vec<PathBuf> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .and_then(|e| e.to_str())
                .is_some_and(|e| e.eq_ignore_ascii_case(ext))
        })
        .collect();
    found.sort();
    found.into_iter().next()
}

/// EXTH 121 = KF8 boundary 记录号（4 字节大端 u32）。
fn kf8_boundary(book: &Mobi) -> Option<u32> {
    let records = book
        .metadata
        .exth
        .get_record(ExthRecord::KF8BoundaryOffset)?;
    let bytes = records.first()?;
    let four: [u8; 4] = bytes.as_slice().try_into().ok()?;
    Some(u32::from_be_bytes(four))
}

/// 正文解码探针：接住 crate 内 panic（KF8 支持现状即结论，不炸测试）。
fn content_probe(book: &Mobi) -> Result<String, String> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| book.content_as_string_lossy()))
        .map_err(|payload| {
            let msg = payload
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| payload.downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_else(|| "panic（无载荷）".to_string());
            msg
        })
}

/// 打印一份样本的 gate 事实，返回（正文结果, EXTH121, gen_version）。
fn dump(label: &str, path: &Path, book: &Mobi) -> (Result<String, String>, Option<u32>, u32) {
    let md = &book.metadata;
    let boundary = kf8_boundary(book);
    let version = md.mobi.gen_version;
    let content = content_probe(book);
    let size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    println!("--- {label} ---");
    println!("  file: {} ({size} B)", path.display());
    println!("  title: {:?}", book.title());
    println!("  mobiHeader.version (crate: gen_version) = {version}");
    println!(
        "  compression = {:?}, encoding = {:?}",
        book.compression(),
        book.text_encoding()
    );
    println!("  EXTH 121 KF8BoundaryOffset = {boundary:?}");
    println!(
        "  content records: first = {}, last = {}, first_non_book_index = {}",
        md.mobi.first_content_record, md.mobi.last_content_record, md.mobi.first_non_book_index
    );
    match &content {
        Ok(text) => {
            let cjk = text
                .chars()
                .filter(|c| ('\u{4e00}'..='\u{9fff}').contains(c))
                .count();
            println!(
                "  content_as_string_lossy: {} chars (CJK {})",
                text.chars().count(),
                cjk
            );
        }
        Err(msg) => println!("  content_as_string_lossy: PANIC — {msg}"),
    }
    (content, boundary, version)
}

/// 入口①：`version >= 8` 直入（纯 KF8 azw3）。
#[test]
fn entry_a_version_direct() {
    let Some(path) = find_ext("azw3") else {
        eprintln!("SKIP 入口①：{} 下无 *.azw3 样本", fixture_dir().display());
        return;
    };
    let book = Mobi::from_path(&path).expect("入口①（version>=8 直入）：azw3 应能打开");
    assert!(!book.title().trim().is_empty(), "入口①：书名应可读出");
    let (content, _boundary, version) = dump("入口① version>=8 直入（纯 KF8 azw3）", &path, &book);
    assert_eq!(version, 8, "入口①样本应为 KF8（version=8 直入分支）");
    match content {
        Ok(text) => println!(
            "GATE[KF8][entry-a] open=OK version={version} content=OK verdict=SUPPORTED ({} chars)",
            text.chars().count()
        ),
        Err(msg) => println!("GATE[KF8][entry-a] open=OK version={version} content=PANIC verdict=UNSUPPORTED ({msg})"),
    }
}

/// 入口②：KF6 的 EXTH 121 boundary 跳转（combo 文件）。
#[test]
fn entry_b_exth121_boundary() {
    let Some(path) = find_ext("mobi") else {
        eprintln!("SKIP 入口②：{} 下无 *.mobi 样本", fixture_dir().display());
        return;
    };
    let book = Mobi::from_path(&path).expect("入口②（EXTH121 boundary）：combo 文件应能打开");
    let (content, boundary, version) =
        dump("入口② EXTH 121 boundary 跳转（combo KF6+KF8）", &path, &book);
    assert_eq!(
        boundary,
        Some(5281),
        "入口②样本应带 EXTH 121 boundary（M2b-T05 基线：5281）"
    );
    // 关键判语：跳转成功的标志 = record-0 之后重读到 version=8 头；
    // crate 无跳转逻辑 → 打开后仍是 KF6 头（version=6）。
    let jumped = version == 8;
    let content_state = match &content {
        Ok(text) => format!("OK ({} chars)", text.chars().count()),
        Err(msg) => format!("PANIC ({msg})"),
    };
    println!(
        "GATE[KF8][entry-b] open=OK boundary={boundary:?} version={version} jumped={jumped} \
         content={content_state} verdict={}",
        if jumped {
            "BOUNDARY_SUPPORTED"
        } else {
            "KF6_HEADER_ONLY (未跳 boundary)"
        }
    );
}
