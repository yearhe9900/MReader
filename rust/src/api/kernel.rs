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
pub(crate) fn map_err(e: RrkError) -> HighPerfError {
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
    /// 内容哈希（内容级缓存的 key 前缀；`0` = 未提供）：删书时用它整本失效
    /// 内容缓存（`rrk-cache`，上游 issue #12）。
    pub content_hash: u64,
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

/// 章标题块（issue #13 轻量出口）。
pub struct RkHeading {
    /// 标题级别（1–6）。
    pub level: u8,
    pub text: String,
}

/// 语义定位坐标（进度 ↔ 位置互转的公共形态）。
pub struct RkLocation {
    pub chapter: u32,
    /// 章内字节偏移（章文本 UTF-8 坐标系）。
    pub byte_offset: u32,
}

/// 单章搜索命中（与全书搜索同源坐标：章文本字节偏移）。
pub struct RkSearchHit {
    pub chapter: u32,
    /// 章正文 UTF-8 字节偏移（与锚点/内链同坐标系）。
    pub offset: u32,
    /// 命中长度（字节）。
    pub len: u32,
    /// 上下文片段（超长时两端带 `…`）。
    pub snippet: String,
    /// 片段在所属段落文本中的起点（字节），供宿主局部高亮。
    pub snippet_offset: u32,
}

/// 单章搜索结果页（同步扫完即全量；字段与全书会话批次同形）。
pub struct RkSearchPage {
    pub hits: Vec<RkSearchHit>,
    /// 已扫完的章数（单章搜索恒 ≤ 1）。
    pub scanned: u32,
    /// 全书章数。
    pub total: u32,
    /// 是否已扫完（拉模式批次结构同形字段）。单章搜索是一次性同步调用，
    /// 结果即本批全量（`max_hits` 截断归上限语义），此字段不作判据。
    pub done: bool,
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
                content_hash: m.content_hash,
            })
        })
    })
}

/// 内容级缓存命中统计快照（体检 / 日志用；未配置缓存时全 0）。
#[derive(Debug, Default, Clone, Copy)]
pub struct RkCacheStats {
    pub toc_hits: u64,
    pub toc_misses: u64,
    pub chapter_hits: u64,
    pub chapter_misses: u64,
    pub outline_hits: u64,
    pub outline_misses: u64,
    /// open 索引命中/未命中（章级/页级缓存持久化：open 期免重建）。
    pub open_hits: u64,
    pub open_misses: u64,
}

/// 配置内容级缓存（目录 + 内存上限字节；空目录 = 关闭）。幂等，可重复调用。
///
/// key = `content_hash`（内容级，不随样式/视口变）：同文件重开命中，内容变了整本
/// 失效；payload 自带 schema 号，内核升级 / 损坏自动丢弃重算。
#[flutter_rust_bridge::frb(sync)]
pub fn kernel_cache_configure(dir: String, mem_bytes: u64) -> Result<(), HighPerfError> {
    ffi_guard(|| {
        with_kernel(|k| {
            k.configure_content_cache(&dir, mem_bytes as usize)?;
            Ok(())
        })
    })
}

/// 内容级缓存命中统计快照（只读、无 IO，适合体检页 / 日志）。
#[flutter_rust_bridge::frb(sync)]
pub fn kernel_cache_stats() -> RkCacheStats {
    ffi_guard(|| {
        with_kernel(|k| {
            let s = k.content_cache_stats();
            Ok(RkCacheStats {
                toc_hits: s.toc_hits,
                toc_misses: s.toc_misses,
                chapter_hits: s.chapter_hits,
                chapter_misses: s.chapter_misses,
                outline_hits: s.outline_hits,
                outline_misses: s.outline_misses,
                open_hits: s.open_hits,
                open_misses: s.open_misses,
            })
        })
    })
    .unwrap_or_default()
}

/// 按内容哈希整本失效（删书时调用）；返回删除条数（内存 + 磁盘）。
///
/// 幂等：哈希不存在 = 返回 0；缓存未配置同样返回 0。
#[flutter_rust_bridge::frb(sync)]
pub fn kernel_cache_invalidate(content_hash: u64) -> u64 {
    ffi_guard(|| with_kernel(|k| k.invalidate_content_cache(content_hash).map(|n| n as u64)))
        .unwrap_or(0)
}

/// 目录树。
pub fn kernel_toc(handle: u64) -> Result<Vec<RkTocNode>, HighPerfError> {
    ffi_guard(|| {
        with_kernel(|k| {
            // 内容级缓存（`rrk-cache`，上游 issue #12）：命中免 nav/NCX 解析；
            // 未配置缓存时行为与直调 `toc()` 逐字节一致。
            Ok(toc_nodes(&k.toc_cached(handle)?))
        })
    })
}

/// 章索引（O(结构) 可得，不解压正文）。
pub fn kernel_chapters(handle: u64) -> Result<Vec<RkChapter>, HighPerfError> {
    ffi_guard(|| {
        with_kernel(|k| {
            // 内容级缓存：命中免分章扫描（TXT 大纲重建受益最大）。
            let entries = k.chapters_cached(handle)?;
            Ok(entries
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
            // 内容级缓存：命中免 inflate + 清洗 + 分块。
            let content = k.load_chapter_cached(handle, chapter_id)?;
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

// ---------------------------------------------------------------------------
// ABI 8/9/10 新出口（进度 / 坐标映射 / 选区 / 章标题块 / 单章搜索）。
// 语义归 vendored `rrk-*`，本段只做镜像透传（与上方同口径）。
// ---------------------------------------------------------------------------

/// 章标题块列表（issue #13 轻量出口）：走章内容级缓存（命中免解析），
/// 且免整章文本跨边界搬运；无标题/图片章返回空表。
pub fn kernel_chapter_headings(
    handle: u64,
    chapter_id: u32,
) -> Result<Vec<RkHeading>, HighPerfError> {
    ffi_guard(|| {
        with_kernel(|k| {
            Ok(k
                .chapter_headings(handle, chapter_id)?
                .into_iter()
                .map(|(level, text)| RkHeading { level, text })
                .collect())
        })
    })
}

/// 轻量**单章**搜索：不注册会话、同步扫完即弃，扫描/坐标/snippet 与全书
/// 检索同源。`context_chars = 0` 取默认 30；`max_hits = 0` 取默认上限 1000。
pub fn kernel_search_chapter(
    handle: u64,
    chapter_id: u32,
    query: String,
    case_sensitive: bool,
    context_chars: u32,
    max_hits: u32,
) -> Result<RkSearchPage, HighPerfError> {
    ffi_guard(|| {
        with_kernel(|k| {
            let opts = rrk_search::SearchOptions {
                case_sensitive,
                context_chars: if context_chars == 0 { 30 } else { context_chars },
            };
            let page = k.search_chapter(handle, chapter_id, &query, opts, max_hits)?;
            Ok(RkSearchPage {
                hits: page
                    .hits
                    .iter()
                    .map(|h| RkSearchHit {
                        chapter: h.chapter,
                        offset: h.offset,
                        len: h.len,
                        snippet: h.snippet.clone(),
                        snippet_offset: h.snippet_offset,
                    })
                    .collect(),
                scanned: page.scanned,
                total: page.total,
                done: page.done,
            })
        })
    })
}

/// 语义坐标 → 全书进度百分比 [0, 1]（估算口径：按章权重线性插值，越界夹取；
/// 精确定位走 `page_at` 链路）。进度条与跨设备同步用。
pub fn kernel_progress_of(
    handle: u64,
    chapter: u32,
    byte_offset: u32,
) -> Result<f32, HighPerfError> {
    ffi_guard(|| with_kernel(|k| k.progress_of(handle, chapter, byte_offset)))
}

/// 进度百分比 [0, 1] → 语义坐标（[`kernel_progress_of`] 的逆；同为估算口径）。
pub fn kernel_locate(handle: u64, percent: f32) -> Result<RkLocation, HighPerfError> {
    ffi_guard(|| {
        with_kernel(|k| {
            let (chapter, byte_offset) = k.locate(handle, percent)?;
            Ok(RkLocation { chapter, byte_offset })
        })
    })
}

/// 批量偏移映射：章文本 UTF-8 字节偏移 ↔ UTF-16 code unit 偏移。
///
/// `to_utf16 = true`：字节 → UTF-16（越界夹取、非字符边界向下取整）；
/// `false`：UTF-16 → 字节（代理对中间取对首）。Dart `String` 是 UTF-16，
/// 标注 / 选区必经。
pub fn kernel_map_offsets(
    handle: u64,
    chapter: u32,
    to_utf16: bool,
    offsets: Vec<u32>,
) -> Result<Vec<u32>, HighPerfError> {
    ffi_guard(|| with_kernel(|k| k.map_offsets(handle, chapter, to_utf16, &offsets)))
}

/// 选区取文：`[start, end)` 夹到字符边界后返回章文本切片（免整章拉回）。
pub fn kernel_slice_text(
    handle: u64,
    chapter: u32,
    start: u32,
    end: u32,
) -> Result<String, HighPerfError> {
    ffi_guard(|| with_kernel(|k| k.slice_text(handle, chapter, start, end)))
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
