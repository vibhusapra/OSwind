import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect:NSRect(x:200,y:200,width:900,height:560),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
window.title = "OSwind capture verification"
let view = NSView(frame:NSRect(x:0,y:0,width:900,height:560)); view.wantsLayer = true; view.layer?.backgroundColor = NSColor.white.cgColor
let secret = Bundle.main.bundleIdentifier?.hasSuffix(".secret") == true
let content = secret ? "OSwind secret redaction fixture\n\npassword=synthetic-secret-value\nSECRETFRAME7429" : "OSwind controlled capture fixture\n\nMaya owns the Friday release checklist.\nThe unique marker is WINDCAPTURE7429.\n\nThis is synthetic test content."
let label = NSTextField(wrappingLabelWithString:content)
label.frame = NSRect(x:60,y:80,width:780,height:410); label.font = NSFont.systemFont(ofSize:28); label.textColor = .black; view.addSubview(label)
window.contentView = view
let menu = NSMenu(); let item = NSMenuItem(); let submenu = NSMenu(); submenu.addItem(withTitle:"Quit",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"); item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps:true); app.run()
