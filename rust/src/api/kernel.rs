//! 解析内核桥：vendored `rrk-kernel`（图书解析核心）→ FRB → Dart（`RustKernelSource`）。
//!
//! 职责边界（`NF-D8` 只读链路）：打开 / 查询 / 逐章加载 / 资源读取，**不写盘**。
//! panic 经 [`ffi_guard`] 收敛为 [`HighPerfError`]，绝不跨边界（`RUST-04` 口径）。
//!
//! 边界纪律：正文**按章单次拉取**（`RkChapterText`），资源字节按需取，
//! 不做整本搬运；结构面（meta/toc/chapters/weights）都是小结构。
//!
//! **映射口径唯一来源 = `rrk_model::flatten_blocks`**（内核 #4 修复批次定案）：
//! 本桥不自造「块→文本」映射，只做透传——块文本里的行内图片标记是内核格式
//! `\u{FFFC}<key>\u{FFFC}`，内链以**区间列表**单独给出（[`RkLink`]）。把它们织成
//! 宿主段落标记（`\x00IMG:` / `\x00A:`）是**宿主适配层**的事，见
//! `lib/format/rust_kernel_source.dart`。

use std::sync::Mutex;

use rrk_kernel::Kernel;
use rrk_model::{flatten_blocks, PlainBlock, RrkError, RrkErrorKind, RrkResult};

use crate::api::error::{HighPerfError, HighPerfErrorKind};
use crate::api::guard::ffi_guard;

/// 冘核实例（句柄表托管）；进程内一份。
static KERNEL: Mutex<Option<Kernel>> = Mutex::new(None);

fn with_kernel<T>(f: impl FnOnce(&mut Kernel) -> RrkResult<T>) -> Result<T, HighPerfError> {
    let mut guard = KERNEL.lock().map_err(|_| HighPerfError {
        kind: HighPerfErrorKind::Internal,
        message_zh: "解析内核锁中毒".to_string(),
    })?;
    let kernel = guard.get_or_insert_with(Kernel::new);
    f(kernel).map_err(map_err)
}

/// 内核错误 → 加速层错误（类别是契约、文案是表达）。
fn map_err(e: RrkError) -> HighPerfError {
    let kind = match e.kind {
        RrkErrorKind::Io => HighPerfErrorKind::Io,
        // DRM / 明确拒绝的格式都走 Encrypted（RD-05「不破解、给中文原因」）。
        RrkErrorKind::UnsupportedFormat => {
            if e.message.contains("加密") || e.message.contains("DRM") {
                HighPerfErrorKind::Encrypted
            } else {
                HighPerfErrorKind::FormatInvalid
            }
        }
        // EPUB 缺 container.xml 单列一类（与 Dart 侧错误分类对齐）。
        RrkErrorKind::CorruptData if e.message.contains("container.xml") => {
            HighPerfErrorKind::MissingContainer
        }
        RrkErrorKind::CorruptData | RrkErrorKind::InvalidParam | RrkErrorKind::ResourceLimit => {
            HighPerfErrorKind::FormatInvalid
        }
        RrkErrorKind::Cancelled => HighPerfErrorKind::Cancelled,
        RrkErrorKind::Internal => HighPerfErrorKind::Internal,
    };
    HighPerfError { kind, message_zh: e.message }
}

// ---------------------------------------------------------------------------
// 镜像类型（FRB 生成 Dart 类；命名 Rk* 前缀避免与宿主模型混淆）
// ---------------------------------------------------------------------------

/// 书目元数据。
pub struct RkMeta {
    pub title: String,
    pub authors: Vec<String>,
    pub language: Option<String>,
    /// 简介（EPUB `dc:description` / MOBI EXTH 103·104）；无则 `None`。
    pub description: Option<String>,
    /// 格式名：`EPUB` / `TXT` / `MOBI` / `AZW3` / `CBZ` / `PDF`。
    pub format: String,
    /// 封面资源 key（包内绝对路径）；无封面为 `None`（内核含三级回退）。
    pub cover_key: Option<String>,
}

/// 章索引项。
pub struct RkChapter {
    pub id: u32,
    pub title: Option<String>,
    /// 稳定定位串（进度/同步的章节身份键）：EPUB = 包内路径、TXT = `txt:<字符偏移>`、
    /// MOBI = `mobi:<序号>`。
    pub href: String,
    /// 估算字数（进度权重用）。
    pub char_len: u32,
    /// `text` / `image`。
    pub kind: String,
    /// 逻辑块分片号（巨章切块；普通章 0）。
    pub part: u32,
}

/// 目录节点（树形；`anchor` = 章内字节偏移，惰性解析，取不到为 `None`）。
pub struct RkTocNode {
    pub title: String,
    pub chapter: u32,
    pub anchor: Option<u32>,
    pub children: Vec<RkTocNode>,
}

/// 内容块（`rrk_model::flatten_blocks` 的透传：引用块已摊平、分割线已丢弃）。
///
/// 文本里的行内图片标记是**内核格式** `\u{FFFC}<key>\u{FFFC}`（宿主适配层转换）。
pub struct RkBlock {
    /// `h`（标题）/ `p`（段落）/ `img`（块级图片，[Self::text] 即标记串）。
    pub kind: String,
    /// 块级纯文本；行内图片以 `\u{FFFC}<key>\u{FFFC}` 内嵌。
    pub text: String,
    /// 标题级别（仅 `h`）。
    pub level: u8,
    /// 首行缩进（仅 `p`）。
    pub indent: bool,
    /// 图片 key（仅 `img`；包内绝对路径）。
    pub key: Option<String>,
    pub alt: Option<String>,
}

/// 正文内链区间（清洗后章文本的字节区间 → 目标 href）。
///
/// 与 [`RkChapterText::text`] 同坐标系；宿主按区间把可点标记织回段落文本。
pub struct RkLink {
    pub start: u32,
    pub end: u32,
    pub href: String,
}

/// 一章的正文（整章 UTF-8 文本 + 扁平块表 + 内链区间）。
pub struct RkChapterText {
    pub text: String,
    pub blocks: Vec<RkBlock>,
    pub links: Vec<RkLink>,
}

/// 二进制资源。
pub struct RkResource {
    pub mime: String,
    pub data: Vec<u8>,
}

/// 章权重（廉价估算）。
pub struct RkWeight {
    pub id: u32,
    pub char_len: u32,
}

// ---------------------------------------------------------------------------
// 内核模型 → 镜像类型（薄映射，语义归 rrk_model）
// ---------------------------------------------------------------------------

fn toc_nodes(nodes: &[rrk_model::TocNode]) -> Vec<RkTocNode> {
    nodes
        .iter()
        .map(|n| RkTocNode {
            title: n.title.clone(),
            chapter: n.chapter,
            anchor: n.anchor,
            children: toc_nodes(&n.children),
        })
        .collect()
}

/// `rrk_model::flatten_blocks`（唯一降维口径）→ 镜像块表；纯透传不改语义。
fn plain_blocks(text: &str, blocks: &[rrk_model::Block]) -> Vec<RkBlock> {
    flatten_blocks(text, blocks)
        .iter()
        .map(|b| match b {
            PlainBlock::Heading { level, text } => RkBlock {
                kind: "h".to_string(),
                text: text.clone(),
                level: *level,
                indent: false,
                key: None,
                alt: None,
            },
            PlainBlock::Paragraph { text, indent } => RkBlock {
                kind: "p".to_string(),
                text: text.clone(),
                level: 0,
                indent: *indent,
                key: None,
                alt: None,
            },
            PlainBlock::Image { key, alt } => RkBlock {
                kind: "img".to_string(),
                text: format!(
                    "{}{}{}",
                    rrk_model::INLINE_IMAGE_MARKER,
                    key.0,
                    rrk_model::INLINE_IMAGE_MARKER
                ),
                level: 0,
                indent: false,
                key: Some(key.0.clone()),
                alt: alt.clone(),
            },
        })
        .collect()
}

// ---------------------------------------------------------------------------
// 调用面
// ---------------------------------------------------------------------------

/// 按路径打开一本书；返回书句柄（≥1）。
pub fn kernel_open_path(path: String) -> Result<u64, HighPerfError> {
    ffi_guard(|| {
        with_kernel(|k| {
            let src = rrk_format::ContentSource::from_path(path);
            k.open(&src)
        })
    })
}

/// 按内存字节打开一本书（无路径可用时的入口）。
pub fn kernel_open_bytes(name: String, data: Vec<u8>) -> Result<u64, HighPerfError> {
    ffi_guard(|| {
        with_kernel(|k| {
            let src = rrk_format::ContentSource::from_bytes(Some(name), data);
            k.open(&src)
        })
    })
}

/// 关闭一本书（幂等；非法句柄报错）。
pub fn kernel_close(handle: u64) -> Result<(), HighPerfError> {
    ffi_guard(|| with_kernel(|k| k.close(handle)))
}

/// 书目元数据。
pub fn kernel_meta(handle: u64) -> Result<RkMeta, HighPerfError> {
    ffi_guard(|| {
        with_kernel(|k| {
            let book = k.book(handle)?;
            let m = book.meta();
            Ok(RkMeta {
                title: m.title.clone(),
                authors: m.authors.clone(),
                language: m.language.clone(),
                description: m.description.clone(),
                format: m.format.to_string(),
                cover_key: m.cover.as_ref().map(|c| c.0.clone()),
            })
        })
    })
}

/// 目录树。
pub fn kernel_toc(handle: u64) -> Result<Vec<RkTocNode>, HighPerfError> {
    ffi_guard(|| {
        with_kernel(|k| {
            let book = k.book(handle)?;
            Ok(toc_nodes(&book.toc()?))
        })
    })
}

/// 章索引（O(结构) 可得，不解压正文）。
pub fn kernel_chapters(handle: u64) -> Result<Vec<RkChapter>, HighPerfError> {
    ffi_guard(|| {
        with_kernel(|k| {
            let book = k.book(handle)?;
            Ok(book
                .chapters()?
                .iter()
                .map(|e| RkChapter {
                    id: e.id,
                    title: e.title.clone(),
                    href: e.href.clone(),
                    char_len: e.char_len,
                    kind: match e.kind {
                        rrk_model::ChapterKind::Text => "text",
                        rrk_model::ChapterKind::ImageGallery => "image",
                    }
                    .to_string(),
                    part: e.part,
                })
                .collect())
        })
    })
}

/// 加载一章（整章文本 + 扁平块表 + 内链区间）。
pub fn kernel_load_chapter(handle: u64, chapter_id: u32) -> Result<RkChapterText, HighPerfError> {
    ffi_guard(|| {
        with_kernel(|k| {
            let book = k.book(handle)?;
            let content = book.load_chapter(chapter_id)?;
            Ok(RkChapterText {
                blocks: plain_blocks(&content.text, &content.blocks),
                links: content
                    .link_ranges
                    .iter()
                    .map(|l| RkLink {
                        start: l.range.start,
                        end: l.range.end,
                        href: l.href.clone(),
                    })
                    .collect(),
                text: content.text.to_string(),
            })
        })
    })
}

/// 封面（无封面返回 `None`；内核含显式封面 → spine 首图 → manifest 首图回退）。
pub fn kernel_cover(handle: u64) -> Result<Option<RkResource>, HighPerfError> {
    ffi_guard(|| {
        with_kernel(|k| {
            let book = k.book(handle)?;
            Ok(book.cover()?.map(|r| RkResource {
                mime: r.mime,
                data: r.data.to_vec(),
            }))
        })
    })
}

/// 按 key（包内绝对路径）读资源；不存在返回 `None`。
pub fn kernel_load_resource(handle: u64, key: String) -> Result<Option<RkResource>, HighPerfError> {
    ffi_guard(|| {
        with_kernel(|k| {
            let book = k.book(handle)?;
            let rk = rrk_model::ResourceKey(key);
            match book.load_resource(&rk) {
                Ok(r) => Ok(Some(RkResource { mime: r.mime, data: r.data.to_vec() })),
                // 资源不存在 = 软结果 None（调用方回落占位），不当错误抛。
                Err(e) if e.kind == RrkErrorKind::InvalidParam => Ok(None),
                Err(e) => Err(e),
            }
        })
    })
}

/// 每章权重估算（零解压；阅读页进度百分比用）。
pub fn kernel_weights(handle: u64) -> Result<Vec<RkWeight>, HighPerfError> {
    ffi_guard(|| {
        with_kernel(|k| {
            let book = k.book(handle)?;
            Ok(book
                .estimate_weights()?
                .iter()
                .map(|(id, char_len)| RkWeight { id: *id, char_len: *char_len })
                .collect())
        })
    })
}

#[cfg(test)]
mod tests {
    use rrk_model::{Block, Inline, ResourceKey, StyleFlags, TextRange};

    use super::*;

    fn text_range(start: u32, end: u32) -> Inline {
        Inline::Text { range: TextRange::new(start, end), style: StyleFlags::default() }
    }

    #[test]
    fn bridge_passes_through_flatten_contract() {
        // 共享正文缓冲：「前文」= 0..6，「引」= 6..9（UTF-8 字节偏移）。
        let text = "前文引";
        let blocks = vec![
            Block::Paragraph {
                inlines: vec![
                    text_range(0, 6),
                    Inline::Image { key: ResourceKey("OEBPS/a.png".into()) },
                ],
                indent: true,
            },
            Block::Image {
                key: ResourceKey("OEBPS/b.png".into()),
                alt: Some("图".into()),
                size_hint: None,
            },
            Block::Divider,
            Block::Quote {
                blocks: vec![Block::Paragraph {
                    inlines: vec![text_range(6, 9)],
                    indent: false,
                }],
            },
        ];
        let out = plain_blocks(text, &blocks);

        // 判据即 rrk_model::flatten_blocks 契约的透传：分割线丢弃、引用块摊平、
        // 行内图片内嵌 U+FFFC 标记、块级图片单列（text = 标记串）。
        assert_eq!(out.len(), 3);
        assert_eq!(out[0].kind, "p");
        assert!(out[0].indent);
        assert_eq!(out[0].text, "前文\u{FFFC}OEBPS/a.png\u{FFFC}");
        assert_eq!(out[1].kind, "img");
        assert_eq!(out[1].text, "\u{FFFC}OEBPS/b.png\u{FFFC}");
        assert_eq!(out[1].key.as_deref(), Some("OEBPS/b.png"));
        assert_eq!(out[2].kind, "p");
        assert_eq!(out[2].text, "引");
    }
}
