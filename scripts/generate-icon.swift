import AppKit
let size = NSSize(width:1024,height:1024)
let image = NSImage(size:size)
image.lockFocus()
NSColor(red:0.075,green:0.17,blue:0.15,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:30,y:30,width:964,height:964),xRadius:215,yRadius:215).fill()
let color = NSColor(red:0.61,green:0.9,blue:0.76,alpha:1)
func stroke(_ draw: (NSBezierPath)->Void) {
    color.setStroke(); let path = NSBezierPath(); path.lineWidth = 42; path.lineCapStyle = .round; path.lineJoinStyle = .round; draw(path); path.stroke()
}
stroke { p in p.move(to:NSPoint(x:245,y:605)); p.line(to:NSPoint(x:615,y:605)); p.curve(to:NSPoint(x:610,y:770),controlPoint1:NSPoint(x:740,y:605),controlPoint2:NSPoint(x:740,y:770)); p.curve(to:NSPoint(x:550,y:719),controlPoint1:NSPoint(x:565,y:770),controlPoint2:NSPoint(x:550,y:750)) }
stroke { p in p.move(to:NSPoint(x:245,y:485)); p.line(to:NSPoint(x:715,y:485)); p.curve(to:NSPoint(x:755,y:625),controlPoint1:NSPoint(x:825,y:485),controlPoint2:NSPoint(x:840,y:625)) }
stroke { p in p.move(to:NSPoint(x:245,y:365)); p.line(to:NSPoint(x:585,y:365)); p.curve(to:NSPoint(x:610,y:235),controlPoint1:NSPoint(x:715,y:365),controlPoint2:NSPoint(x:715,y:235)); p.curve(to:NSPoint(x:560,y:278),controlPoint1:NSPoint(x:575,y:235),controlPoint2:NSPoint(x:560,y:253)) }
image.unlockFocus()
let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
