// Render SVG → 1024px-per-viewBox PNG, trimmed to opaque bounds (+2px margin).
import AppKit
let args = CommandLine.arguments
let inDir = args[1], outDir = args[2]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for f in try! FileManager.default.contentsOfDirectory(atPath: inDir).filter({ $0.hasSuffix(".svg") }).sorted() {
  guard let im = NSImage(contentsOfFile: inDir + "/" + f) else { print("fail", f); continue }
  let S = Int(ProcessInfo.processInfo.environment["RENDER_SIZE"] ?? "1024")!
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: S*4, bitsPerPixel: 32)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSColor.clear.set(); NSRect(x: 0, y: 0, width: S, height: S).fill()
  im.draw(in: NSRect(x: 0, y: 0, width: S, height: S))
  NSGraphicsContext.restoreGraphicsState()
  let data = rep.bitmapData!
  var minX = S, minY = S, maxX = -1, maxY = -1
  for y in 0..<S { for x in 0..<S where data[(y*S+x)*4+3] > 8 { minX = min(minX,x); maxX = max(maxX,x); minY = min(minY,y); maxY = max(maxY,y) } }
  guard maxX >= 0 else { print("empty", f); continue }
  let m = 2
  let r = CGRect(x: max(minX-m,0), y: max(minY-m,0), width: min(maxX+m,S-1)-max(minX-m,0)+1, height: min(maxY+m,S-1)-max(minY-m,0)+1)
  let cg = rep.cgImage!.cropping(to: r)!
  let out = NSBitmapImageRep(cgImage: cg)
  let name = (f as NSString).deletingPathExtension
  try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
  print(name, Int(r.width), Int(r.height))
}
