//! 图片工具桥：vendored `rrk-image`（缩略图）→ FRB → Dart。
//!
//! 无内核句柄、无状态；panic 经 [`ffi_guard`] 收敛（`RUST-04` 口径）。

use crate::api::error::HighPerfError;
use crate::api::guard::ffi_guard;
use crate::api::kernel::map_err;

/// 缩略图结果：RGBA8 位图（宿主直接上屏或自行编码落盘；不写盘）。
pub struct RkThumbnail {
    pub width: u32,
    pub height: u32,
    /// RGBA8，长度 = `width * height * 4`。
    pub rgba: Vec<u8>,
}

/// 解码整图并等比缩到 `max_edge`（长边）以内 → RGBA。
///
/// 原图已在 `max_edge` 内则不缩仅解码；AVIF/HEIC（内核不解像素）报
/// `UnsupportedFormat`（宿主取原始字节自行解码）、已识别但损坏报
/// `CorruptData`——两类语义归 `rrk-image`，此处只做错误类别透传。
pub fn image_thumbnail(data: Vec<u8>, max_edge: u32) -> Result<RkThumbnail, HighPerfError> {
    ffi_guard(|| {
        let t = rrk_image::thumbnail(&data, max_edge).map_err(map_err)?;
        Ok(RkThumbnail { width: t.width, height: t.height, rgba: t.rgba })
    })
}
