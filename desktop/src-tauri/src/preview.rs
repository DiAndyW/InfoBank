use std::{
    path::{Path, PathBuf},
    time::Duration,
};

pub const TIMEOUT: Duration = Duration::from_secs(10);

pub async fn make(path: PathBuf) -> Option<Vec<u8>> {
    bounded(move || generate(&path), TIMEOUT).await
}

pub(crate) async fn bounded(
    work: impl FnOnce() -> Option<Vec<u8>> + Send + 'static,
    limit: Duration,
) -> Option<Vec<u8>> {
    tokio::time::timeout(limit, tokio::task::spawn_blocking(work))
        .await
        .ok()?
        .ok()?
}

fn encode(image: image::RgbaImage) -> Option<Vec<u8>> {
    let mut rgb = image::RgbImage::new(image.width(), image.height());
    for (out, pixel) in rgb.pixels_mut().zip(image.pixels()) {
        let alpha = u32::from(pixel[3]);
        for channel in 0..3 {
            out[channel] =
                ((u32::from(pixel[channel]) * alpha + 255 * (255 - alpha) + 127) / 255) as u8;
        }
    }
    let rgb = if rgb.width().max(rgb.height()) > 400 {
        image::DynamicImage::ImageRgb8(rgb)
            .resize(400, 400, image::imageops::FilterType::Lanczos3)
            .to_rgb8()
    } else {
        rgb
    };
    let mut bytes = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut bytes, 80)
        .encode_image(&rgb)
        .ok()?;
    (bytes.len() as u64 <= crate::cache::MAX_THUMBNAIL_BYTES).then_some(bytes)
}

#[cfg(target_os = "macos")]
fn generate(path: &Path) -> Option<Vec<u8>> {
    use objc2::AllocAnyThread;
    use objc2_core_graphics::{
        CGBitmapContextCreate, CGColorSpace, CGContext, CGImage, CGImageAlphaInfo,
    };
    use objc2_foundation::{NSError, NSPoint, NSRect, NSSize, NSString, NSURL};
    use objc2_quick_look_thumbnailing::{
        QLThumbnailGenerationRequest, QLThumbnailGenerationRequestRepresentationTypes,
        QLThumbnailGenerator, QLThumbnailRepresentation,
    };

    objc2::rc::autoreleasepool(|_| unsafe {
        let url = NSURL::fileURLWithPath(&NSString::from_str(path.to_str()?));
        let request =
            QLThumbnailGenerationRequest::initWithFileAtURL_size_scale_representationTypes(
                QLThumbnailGenerationRequest::alloc(),
                &url,
                NSSize::new(400.0, 400.0),
                1.0,
                QLThumbnailGenerationRequestRepresentationTypes::Thumbnail,
            );
        let (sender, receiver) = std::sync::mpsc::channel();
        let completion = block2::RcBlock::new(
            move |representation: *mut QLThumbnailRepresentation, _: *mut NSError| {
                let result = representation
                    .as_ref()
                    .map(|representation| representation.CGImage());
                let _ = sender.send(result);
            },
        );
        QLThumbnailGenerator::sharedGenerator()
            .generateBestRepresentationForRequest_completionHandler(&request, &completion);
        let image = receiver.recv_timeout(TIMEOUT).ok()??;
        let width = CGImage::width(Some(&image));
        let height = CGImage::height(Some(&image));
        let mut pixels = image::RgbaImage::from_pixel(
            u32::try_from(width).ok()?,
            u32::try_from(height).ok()?,
            image::Rgba([255; 4]),
        );
        let space = CGColorSpace::new_device_rgb()?;
        let context = CGBitmapContextCreate(
            pixels.as_mut_ptr().cast(),
            width,
            height,
            8,
            width * 4,
            Some(&space),
            CGImageAlphaInfo::NoneSkipLast.0,
        )?;
        CGContext::draw_image(
            Some(&context),
            NSRect::new(
                NSPoint::new(0.0, 0.0),
                NSSize::new(width as f64, height as f64),
            ),
            Some(&image),
        );
        drop(context);
        encode(pixels)
    })
}

#[cfg(target_os = "windows")]
fn generate(path: &Path) -> Option<Vec<u8>> {
    use std::os::windows::ffi::OsStrExt;
    use windows::{
        Win32::{Graphics::Gdi::*, System::Com::*, UI::Shell::*},
        core::PCWSTR,
    };

    unsafe {
        CoInitializeEx(None, COINIT_APARTMENTTHREADED).ok().ok()?;
        let result = (|| {
            // Shell parsing rejects forward slashes and verbatim disk prefixes.
            let path = std::path::absolute(path).ok()?;
            let path: Vec<u16> = dunce::simplified(&path)
                .as_os_str()
                .encode_wide()
                .chain(Some(0))
                .collect();
            let item: IShellItem = SHCreateItemFromParsingName(PCWSTR(path.as_ptr()), None).ok()?;
            let provider: IThumbnailProvider =
                item.BindToHandler(None, &BHID_ThumbnailHandler).ok()?;
            let mut bitmap = HBITMAP::default();
            let mut alpha = WTS_ALPHATYPE::default();
            provider.GetThumbnail(400, &mut bitmap, &mut alpha).ok()?;
            let result = (|| {
                let mut details = BITMAP::default();
                if GetObjectW(
                    HGDIOBJ(bitmap.0),
                    size_of::<BITMAP>() as i32,
                    Some((&mut details as *mut BITMAP).cast()),
                ) == 0
                {
                    return None;
                }
                let width = u32::try_from(details.bmWidth).ok()?;
                let height = details.bmHeight.unsigned_abs();
                let mut pixels = image::RgbaImage::new(width, height);
                let mut info = BITMAPINFO {
                    bmiHeader: BITMAPINFOHEADER {
                        biSize: size_of::<BITMAPINFOHEADER>() as u32,
                        biWidth: details.bmWidth,
                        biHeight: -(i32::try_from(height).ok()?),
                        biPlanes: 1,
                        biBitCount: 32,
                        biCompression: BI_RGB.0,
                        ..Default::default()
                    },
                    ..Default::default()
                };
                let dc = GetDC(None);
                if dc.0.is_null() {
                    return None;
                }
                let rows = GetDIBits(
                    dc,
                    bitmap,
                    0,
                    height,
                    Some(pixels.as_mut_ptr().cast()),
                    &mut info,
                    DIB_RGB_COLORS,
                );
                ReleaseDC(None, dc);
                if rows != height as i32 {
                    return None;
                }
                for pixel in pixels.pixels_mut() {
                    pixel.0.swap(0, 2);
                    if alpha != WTSAT_ARGB {
                        pixel[3] = 255;
                    }
                }
                encode(pixels)
            })();
            let _ = DeleteObject(HGDIOBJ(bitmap.0));
            result
        })();
        CoUninitialize();
        result
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn generate(_: &Path) -> Option<Vec<u8>> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::GenericImageView;
    use std::{path::PathBuf, time::Duration};

    #[tokio::test]
    #[cfg_attr(
        target_os = "windows",
        ignore = "Windows CI lacks Media Foundation; run with --ignored on a PC"
    )]
    async fn a_video_gets_an_upright_red_poster() {
        let bytes = make(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures/clip.mp4"))
            .await
            .unwrap();
        assert!(bytes.starts_with(&[0xff, 0xd8]));
        assert!(bytes.len() <= crate::cache::MAX_THUMBNAIL_BYTES as usize);
        let image = image::load_from_memory(&bytes).unwrap();
        assert!(image.width().abs_diff(400) <= 1);
        assert!(image.height().abs_diff(225) <= 1);
        let p = image.get_pixel(image.width() / 2, image.height() / 2);
        assert!(p[0] > 200 && p[1] < 60 && p[2] < 60);
    }

    #[tokio::test]
    #[cfg_attr(
        target_os = "windows",
        ignore = "Windows CI lacks Media Foundation; run with --ignored on a PC"
    )]
    async fn a_portrait_video_gets_a_portrait_poster() {
        let bytes = make(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures/portrait.mp4"))
            .await
            .unwrap();
        let image = image::load_from_memory(&bytes).unwrap();
        assert!(image.height() > image.width());
        assert!(image.height() <= 400);
    }

    #[tokio::test]
    async fn an_image_is_scaled_to_400_px() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("red.png");
        image::RgbaImage::from_pixel(1200, 600, image::Rgba([255, 0, 0, 255]))
            .save(&path)
            .unwrap();
        let bytes = make(path).await.unwrap();
        let image = image::load_from_memory(&bytes).unwrap();
        assert!(image.width().abs_diff(400) <= 1);
        assert!(image.height().abs_diff(200) <= 1);
        let p = image.get_pixel(image.width() / 2, image.height() / 2);
        assert!(p[0] > 200 && p[1] < 60 && p[2] < 60);
    }

    #[tokio::test]
    async fn transparency_becomes_white() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("transparent.png");
        image::RgbaImage::new(100, 100).save(&path).unwrap();
        let bytes = make(path).await.unwrap();
        let image = image::load_from_memory(&bytes).unwrap();
        let p = image.get_pixel(0, 0);
        assert!(p[0] > 240 && p[1] > 240 && p[2] > 240);
    }

    #[tokio::test]
    async fn a_corrupt_video_gets_none() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("broken.mp4");
        std::fs::write(&path, [0xab; 4096]).unwrap();
        assert!(make(path).await.is_none());
    }

    #[tokio::test]
    async fn bounded_returns_the_work_result() {
        assert_eq!(
            bounded(|| Some(vec![1]), Duration::from_secs(1)).await,
            Some(vec![1])
        );
    }

    #[tokio::test]
    async fn bounded_gives_up_at_the_limit() {
        let (sender, receiver) = std::sync::mpsc::channel::<()>();
        assert_eq!(
            bounded(
                move || {
                    receiver.recv().ok()?;
                    Some(vec![1])
                },
                Duration::from_millis(50)
            )
            .await,
            None
        );
        drop(sender);
    }
}
