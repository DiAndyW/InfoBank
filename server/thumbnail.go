package server

import (
	"bytes"
	"encoding/binary"
	"image"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
	"io"

	"golang.org/x/image/draw"
	_ "golang.org/x/image/webp"
)

// thumbnailJPEG returns an upright JPEG at most thumbnailEdgePixels on its long edge,
// or nil if f isn't an image Go can decode within maxThumbnailSourcePixels.
func thumbnailJPEG(f io.ReadSeeker) []byte {
	// The header alone gives the dimensions, so a small file claiming huge ones is refused before decoding.
	cfg, format, err := image.DecodeConfig(f)
	if err != nil || cfg.Width <= 0 || cfg.Height <= 0 || cfg.Width*cfg.Height > maxThumbnailSourcePixels {
		return nil
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return nil
	}
	src, _, err := image.Decode(f)
	if err != nil {
		return nil
	}

	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	if long := max(w, h); long > thumbnailEdgePixels {
		w, h = max(1, w*thumbnailEdgePixels/long), max(1, h*thumbnailEdgePixels/long)
	}
	thumb := image.NewRGBA(image.Rect(0, 0, w, h))
	// JPEG has no transparency; white behind it looks like the image did on a page.
	draw.Draw(thumb, thumb.Bounds(), image.White, image.Point{}, draw.Src)
	draw.CatmullRom.Scale(thumb, thumb.Bounds(), src, b, draw.Over, nil)

	if format == "jpeg" {
		if _, err := f.Seek(0, io.SeekStart); err != nil {
			return nil
		}
		thumb = orient(thumb, exifOrientation(f))
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, thumb, &jpeg.Options{Quality: thumbnailJPEGQuality}); err != nil {
		return nil
	}
	return buf.Bytes()
}

// exifOrientation reads a JPEG's EXIF Orientation tag (1–8), returning 1 (as stored) if there is none.
func exifOrientation(r io.Reader) int {
	head := make([]byte, 64<<10) // EXIF lives in one segment, and a segment is at most 64 KiB
	n, _ := io.ReadFull(r, head)
	head = head[:n]
	if len(head) < 4 || head[0] != 0xFF || head[1] != 0xD8 {
		return 1
	}
	for i := 2; i+4 <= len(head) && head[i] == 0xFF; {
		marker, size := head[i+1], int(binary.BigEndian.Uint16(head[i+2:]))
		end := min(i+2+size, len(head))
		if marker == 0xDA || end < i+4 { // start of image data, or a corrupt length
			break
		}
		if seg := head[i+4 : end]; marker == 0xE1 && bytes.HasPrefix(seg, []byte("Exif\x00\x00")) {
			return tiffOrientation(seg[6:])
		}
		i = end
	}
	return 1
}

// tiffOrientation finds tag 0x0112 in the first IFD of an EXIF TIFF block.
func tiffOrientation(t []byte) int {
	if len(t) < 8 {
		return 1
	}
	var order binary.ByteOrder
	switch string(t[:2]) {
	case "II":
		order = binary.LittleEndian
	case "MM":
		order = binary.BigEndian
	default:
		return 1
	}
	ifd := int(order.Uint32(t[4:]))
	if ifd+2 > len(t) {
		return 1
	}
	for e := ifd + 2; e+12 <= len(t) && e < ifd+2+12*int(order.Uint16(t[ifd:])); e += 12 {
		if order.Uint16(t[e:]) == 0x0112 {
			if o := int(order.Uint16(t[e+8:])); o >= 1 && o <= 8 {
				return o
			}
			return 1
		}
	}
	return 1
}

// orient applies an EXIF orientation: 2–4 flip or turn 180°, 5–8 also swap width and height.
func orient(img *image.RGBA, o int) *image.RGBA {
	if o < 2 || o > 8 {
		return img
	}
	w, h := img.Rect.Dx(), img.Rect.Dy()
	dw, dh := w, h
	if o >= 5 {
		dw, dh = h, w
	}
	out := image.NewRGBA(image.Rect(0, 0, dw, dh))
	for y := range dh {
		for x := range dw {
			var sx, sy int
			switch o {
			case 2:
				sx, sy = w-1-x, y
			case 3:
				sx, sy = w-1-x, h-1-y
			case 4:
				sx, sy = x, h-1-y
			case 5:
				sx, sy = y, x
			case 6:
				sx, sy = y, h-1-x
			case 7:
				sx, sy = w-1-y, h-1-x
			case 8:
				sx, sy = w-1-y, x
			}
			out.SetRGBA(x, y, img.RGBAAt(sx, sy))
		}
	}
	return out
}
