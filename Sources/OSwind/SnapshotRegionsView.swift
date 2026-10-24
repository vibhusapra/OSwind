import SwiftUI
import AppKit
import OSwindCore

struct SnapshotDisplayChoice:Identifiable {
    var id:String
    var name:String
    var size:CGSize
    @MainActor static func attached()->[Self] {
        var seen=Set<String>()
        return NSScreen.screens.compactMap {screen in
            guard let number=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,let id=SnapshotRegionSettings.displayID(number.uint32Value),seen.insert(id).inserted else {return nil}
            return Self(id:id,name:screen.localizedName,size:screen.frame.size)
        }
    }
}
struct SnapshotRegionsView:View {
    @Binding var configuration:SnapshotRegionSettings
    var displayMode:Bool
    var replay:Bool
    @State private var displays:[SnapshotDisplayChoice]
    @State private var expandedCrops:Set<String>
    private let suppliedDisplays:Bool
    init(configuration:Binding<SnapshotRegionSettings>,displayMode:Bool,replay:Bool,displays:[SnapshotDisplayChoice]?=nil) {
        _configuration=configuration;_expandedCrops=State(initialValue:Set(configuration.wrappedValue.displayCrops.keys));self.displayMode=displayMode;self.replay=replay;suppliedDisplays=displays != nil;_displays=State(initialValue:displays ?? SnapshotDisplayChoice.attached())
    }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            if !configuration.valid {
                Label("Capture area settings are invalid. Fix the crop dimensions or choose a new area.",systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                Button(displayMode ? "Choose displays again":"Use the full focused window") {configuration=SnapshotRegionSettings();if displayMode {configuration.selectedDisplays=[]}}
            }
            if displayMode {
                Picker("Displays",selection:Binding(get:{configuration.selectedDisplays==nil},set:{configuration.selectedDisplays = $0 ? nil:[]})) {
                    Text("All attached displays").tag(true)
                    Text("Only selected displays").tag(false)
                }
                if configuration.selectedDisplays?.isEmpty == true {Label("Choose at least one display. Capture waits until then.",systemImage:"display.trianglebadge.exclamationmark").font(.caption).foregroundStyle(.orange)}
                ForEach(displays) {display in
                    VStack(alignment:.leading,spacing:10) {
                        HStack {
                            Image(systemName:"display").foregroundStyle(OSwindTheme.accent)
                            Text(display.name).font(.subheadline.weight(.medium))
                            Spacer()
                            if configuration.selectedDisplays != nil {Toggle("Include",isOn:selection(display.id)).labelsHidden().accessibilityLabel("Include "+display.name)}
                            else {Image(systemName:"checkmark.circle.fill").foregroundStyle(OSwindTheme.accent).accessibilityLabel("Included")}
                        }
                        if configuration.selectedDisplays.map({$0.contains(display.id)}) ?? true {
                            DisclosureGroup("Crop this display",isExpanded:Binding(get:{expandedCrops.contains(display.id)},set:{if $0 {expandedCrops.insert(display.id)}else {expandedCrops.remove(display.id)}})) {
                                SnapshotCropEditor(region:crop(display.id),aspectRatio:display.size.width/max(1,display.size.height))
                            }.font(.caption)
                        }
                    }.padding(12).background(.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
                }
                ForEach((configuration.selectedDisplays ?? []).filter {id in !displays.contains {$0.id==id}},id:\.self) {id in
                    HStack {Label("Disconnected display · "+String(id.suffix(6)),systemImage:"display.trianglebadge.exclamationmark");Spacer();Button("Remove") {configuration.selectedDisplays?.removeAll {$0==id}}}.font(.caption)
                }
                Text("Selected displays are never replaced when disconnected. Crops follow the display identity and scale with its size. Display snapshots keep OCR from their selected pixels, without full-window accessibility text. App and URL metadata remain attached.").font(.caption).foregroundStyle(.secondary)
            } else {
                SnapshotCropEditor(region:$configuration.focusedWindowCrop,aspectRatio:16.0/10.0)
                Text("The crop follows the focused window as it moves or resizes. Only cropped pixels enter OCR and retained images; full-window accessibility text is omitted when cropping. App and URL metadata remain attached.").font(.caption).foregroundStyle(.secondary)
            }
            if replay && (displayMode || configuration.focusedWindowCrop != nil) {
                Label("This area uses snapshots. Clear the window crop and turn off display capture for continuous replay.",systemImage:"photo.on.rectangle").font(.caption).foregroundStyle(.secondary)
            }
        }.onReceive(NotificationCenter.default.publisher(for:NSApplication.didChangeScreenParametersNotification)) {_ in if !suppliedDisplays {displays=SnapshotDisplayChoice.attached()}}
    }
    private func selection(_ id:String)->Binding<Bool> {
        Binding(get:{configuration.selectedDisplays?.contains(id) ?? true},set:{enabled in
            var values=configuration.selectedDisplays ?? []
            values.removeAll {$0==id};if enabled {values.append(id)};configuration.selectedDisplays=values
        })
    }
    private func crop(_ id:String)->Binding<SnapshotRegion?> {Binding(get:{configuration.displayCrops[id]},set:{configuration.displayCrops[id]=$0})}
}
struct SnapshotCropEditor:View {
    @Binding var region:SnapshotRegion?
    var aspectRatio:Double
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Toggle("Crop to a region",isOn:Binding(get:{region != nil},set:{region = $0 ? SnapshotRegion(x:0.1,y:0.1,width:0.8,height:0.8):nil}))
            if let region {
                SnapshotCropDiagram(region:region).aspectRatio(max(0.5,min(3,aspectRatio)),contentMode:.fit).frame(maxHeight:150).frame(maxWidth:.infinity,alignment:.center)
                HStack(alignment:.top,spacing:12) {
                    field("Left %",\.x);field("Top %",\.y);field("Width %",\.width);field("Height %",\.height)
                }
                if !region.valid {Label("Keep the crop inside the source, with positive width and height. Capture waits while these values are invalid.",systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange)}
                HStack {Text("Percentages from the top-left corner. Diagram only.").font(.caption2).foregroundStyle(.secondary);Spacer();Button("Full source") {self.region=nil}.font(.caption)}
            }
        }
    }
    private func field(_ title:String,_ key:WritableKeyPath<SnapshotRegion,Double>)->some View {
        VStack(alignment:.leading,spacing:5) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField(title,value:Binding(get:{(region ?? SnapshotRegion())[keyPath:key]*100},set:{value in var next=region ?? SnapshotRegion();next[keyPath:key]=value/100;region=next}),format:.number.precision(.fractionLength(0...2))).labelsHidden().textFieldStyle(.roundedBorder).accessibilityLabel(title)
        }.frame(maxWidth:.infinity)
    }
}
private struct SnapshotCropDiagram:View {
    var region:SnapshotRegion
    var body:some View {
        GeometryReader {proxy in
            ZStack {
                RoundedRectangle(cornerRadius:8).fill(.primary.opacity(0.055))
                Path {path in
                    for fraction in [0.25,0.5,0.75] {path.move(to:CGPoint(x:proxy.size.width*fraction,y:0));path.addLine(to:CGPoint(x:proxy.size.width*fraction,y:proxy.size.height));path.move(to:CGPoint(x:0,y:proxy.size.height*fraction));path.addLine(to:CGPoint(x:proxy.size.width,y:proxy.size.height*fraction))}
                }.stroke(.primary.opacity(0.06),lineWidth:1)
                if region.valid {
                    RoundedRectangle(cornerRadius:4).fill(OSwindTheme.accent.opacity(0.17)).overlay(RoundedRectangle(cornerRadius:4).stroke(OSwindTheme.accent,lineWidth:2))
                        .frame(width:proxy.size.width*region.width,height:proxy.size.height*region.height)
                        .position(x:proxy.size.width*(region.x+region.width/2),y:proxy.size.height*(region.y+region.height/2))
                } else {Text("Invalid region").font(.caption).foregroundStyle(.orange)}
            }
        }.accessibilityLabel("Capture area schematic").allowsHitTesting(false)
    }
}
