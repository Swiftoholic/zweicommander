import AppKit

guard CommandLine.arguments.count == 2 else { exit(1) }
let destination = URL(fileURLWithPath:CommandLine.arguments[1])
try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
func render(_ size:Int)->Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
    let scale = CGFloat(size)/1024
    let transform = NSAffineTransform(); transform.scale(by:scale); transform.concat()
    let outline = NSBezierPath(roundedRect:NSRect(x:70,y:70,width:884,height:884),xRadius:196,yRadius:196)
    let gradient = NSGradient(starting:NSColor(srgbRed:0.10,green:0.20,blue:0.34,alpha:1),ending:NSColor(srgbRed:0.035,green:0.07,blue:0.14,alpha:1))!
    gradient.draw(in:outline,angle:90)
    let blue = NSColor(srgbRed:0.18,green:0.62,blue:1,alpha:1),pale = NSColor(srgbRed:0.78,green:0.88,blue:1,alpha:1)
    for (x,color) in [(CGFloat(180),blue),(CGFloat(546),pale)] {
        let pane = NSBezierPath(roundedRect:NSRect(x:x,y:250,width:298,height:524),xRadius:35,yRadius:35)
        color.withAlphaComponent(0.13).setFill(); pane.fill(); color.withAlphaComponent(0.85).setStroke(); pane.lineWidth = 12; pane.stroke()
        color.setFill(); NSBezierPath(roundedRect:NSRect(x:x+35,y:682,width:124,height:27),xRadius:11,yRadius:11).fill()
        for index in 0..<4 {
            color.withAlphaComponent(index == 0 ? 1 : 0.5).setFill()
            NSBezierPath(roundedRect:NSRect(x:x+35,y:570-CGFloat(index)*68,width:index%2 == 0 ? 218 : 166,height:22),xRadius:9,yRadius:9).fill()
        }
    }
    blue.setStroke()
    let arrow = NSBezierPath(); arrow.move(to:NSPoint(x:382,y:174)); arrow.line(to:NSPoint(x:648,y:174)); arrow.line(to:NSPoint(x:613,y:207)); arrow.move(to:NSPoint(x:648,y:174)); arrow.line(to:NSPoint(x:613,y:141)); arrow.lineWidth = 18; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using:.png,properties:[:])!
}
for size in [16,32,128,256,512] {
    try render(size).write(to:destination.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size*2).write(to:destination.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
