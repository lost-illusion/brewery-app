// render-icon.swift <source.png> <out.png> [bodyPx]
// Crops the source to its opaque artwork, scales it so the icon *body* is
// bodyPx wide/tall inside a transparent square canvas (Apple's macOS grid has
// the rounded-rect body inset from the canvas), and centers it.
import CoreGraphics
import ImageIO
import Foundation

let args = CommandLine.arguments
guard args.count >= 3,
      let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
else { fputs("usage: render-icon.swift <source.png> <out.png> [bodyPx]\n", stderr); exit(1) }

let bodyPx = args.count > 3 ? Int(args[3]) ?? 824 : 824
let w = img.width, h = img.height
var data = [UInt8](repeating: 0, count: w * h * 4)
guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fputs("decode failed\n", stderr); exit(1) }
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

func alpha(_ x: Int, _ y: Int) -> Int { Int(data[((h - 1 - y) * w + x) * 4 + 3]) }

// Opaque bounding box of the artwork (skip fully transparent margins).
var minX = w, maxX = 0, minY = h, maxY = 0
for y in 0..<h { for x in 0..<w where alpha(x, y) > 8 {
    if x < minX { minX = x }; if x > maxX { maxX = x }
    if y < minY { minY = y }; if y > maxY { maxY = y }
}}
let bw = maxX - minX + 1, bh = maxY - minY + 1

let canvas = 1024
guard let out = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fputs("canvas failed\n", stderr); exit(1) }
out.interpolationQuality = .high

let scale = Double(bodyPx) / Double(max(bw, bh))
let drawW = Double(bw) * scale, drawH = Double(bh) * scale
// Crop the source to its bbox, then center the crop on the canvas.
guard let crop = img.cropping(to: CGRect(x: minX, y: minY, width: bw, height: bh))
else { fputs("crop failed\n", stderr); exit(1) }
out.draw(crop, in: CGRect(x: (Double(canvas) - drawW) / 2,
                          y: (Double(canvas) - drawH) / 2, width: drawW, height: drawH))

guard let png = out.makeImage(),
      let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                                "public.png" as CFString, 1, nil)
else { fputs("encode failed\n", stderr); exit(1) }
CGImageDestinationAddImage(dst, png, nil)
guard CGImageDestinationFinalize(dst) else { fputs("write failed\n", stderr); exit(1) }
print("body \(bw)x\(bh) -> \(Int(drawW))x\(Int(drawH)) on \(canvas)x\(canvas) canvas")
