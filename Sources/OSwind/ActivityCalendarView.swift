import SwiftUI
import OSwindCore

struct ActivityCalendarView:View {
    @EnvironmentObject var app:AppModel
    @ObservedObject var model:ActivityCalendarModel
    @FocusState private var focusedDay:String?
    var body:some View {
        GeometryReader {viewport in
        let compact=viewport.size.height<650
        ScrollView {
            VStack(alignment:.leading,spacing:compact ? 12:16) {
                VStack(alignment:.leading,spacing:7) {
                    Text("A day worth revisiting.").font(.system(size:compact ? 26:32,weight:.medium,design:.rounded))
                    Text("Browse saved sources by date. Counts are not time spent at work.").foregroundStyle(.secondary)
                }
                HStack(spacing:14) {
                    Picker("Application",selection:$model.app) {Text("All apps").tag(String?.none);ForEach(appNames,id:\.self) {Text($0).tag(String?.some($0))}}.labelsHidden().frame(width:185)
                    Picker("Source type",selection:$model.kind) {Text("All types").tag(MemoryKind?.none);ForEach(MemoryKind.allCases,id:\.self) {Text(typeName($0)).tag(MemoryKind?.some($0))}}.labelsHidden().frame(width:150)
                    Toggle("Saved only",isOn:$model.favoritesOnly).toggleStyle(.checkbox)
                    Spacer(minLength:0)
                }
                HStack {
                    Text(monthTitle).font(.title2.weight(.medium))
                    if model.busy {ProgressView().controlSize(.small)}
                    Spacer()
                    Button {model.moveMonth(-1)} label:{Image(systemName:"chevron.left")}.accessibilityLabel("Previous month")
                    Button("This month") {model.thisMonth()}
                    Button {model.moveMonth(1)} label:{Image(systemName:"chevron.right")}.accessibilityLabel("Next month")
                }
                if let error=model.error {HStack {Label(error,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange);Spacer();Button("Retry") {model.reload()}}}
                if let snapshot=model.snapshot,snapshot.month==model.month {
                    HStack(spacing:28) {
                        summary(snapshot.totalSources.formatted(),"saved sources",compact:compact)
                        summary(snapshot.recordedDays.formatted(),"days with sources",compact:compact)
                        Spacer();Label(snapshot.timeZone,systemImage:"globe").font(.caption).foregroundStyle(.secondary)
                    }
                    if viewport.size.width>=700 {
                        HStack(alignment:.top,spacing:16) {monthCard(snapshot,compact:compact).frame(maxWidth:.infinity);dayCard(snapshot,compact:compact).frame(width:compact ? 230:280)}
                    }else {VStack(spacing:16) {monthCard(snapshot,compact:compact);dayCard(snapshot,compact:compact)}}
                }else if model.busy {ProgressView("Loading saved-source counts…").frame(maxWidth:.infinity,minHeight:300)}
            }.padding(compact ? 24:30)
        }.controlSize(compact ? .small:.regular)
        }
        .onAppear {model.activate()}
        .onDisappear {model.deactivate()}
        .onReceive(NotificationCenter.default.publisher(for:NSNotification.Name.NSSystemTimeZoneDidChange).receive(on:RunLoop.main)) {_ in model.updateTimeZone(.current)}
    }
    private var appNames:[String] {Array(Set(app.stats.apps.keys.filter {!$0.isEmpty}).union(model.app.map {[$0]} ?? [])).sorted()}
    private var monthTitle:String {
        let formatter=DateFormatter();formatter.calendar=Calendar(identifier:.gregorian);formatter.locale = .current;formatter.timeZone=model.timeZone;formatter.dateFormat="LLLL yyyy"
        if let start=model.snapshot?.start,model.snapshot?.month==model.month {return formatter.string(from:start)}
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=model.timeZone
        if let year=Int(model.month.prefix(4)),let month=Int(model.month.suffix(2)),let date=calendar.date(from:DateComponents(year:year,month:month,day:15,hour:12)) {return formatter.string(from:date)}
        return model.month
    }
    private func summary(_ count:String,_ title:String,compact:Bool)->some View {VStack(alignment:.leading,spacing:3) {Text(count).font(.system(size:compact ? 21:25,weight:.medium,design:.rounded)).monospacedDigit();Text(title).font(.caption).foregroundStyle(.secondary)}}
    private func monthCard(_ snapshot:ActivityCalendarSnapshot,compact:Bool)->some View {
        let columns=Array(repeating:GridItem(.flexible(minimum:36),spacing:6),count:7),maximum=max(1,snapshot.days.map(\.sources).max() ?? 1),total=snapshot.leadingEmptyDays+snapshot.days.count,slots=((total+6)/7)*7
        return VStack(alignment:.leading,spacing:14) {
            LazyVGrid(columns:columns,spacing:6) {
                ForEach(0..<7,id:\.self) {index in Text(weekday(index,snapshot:snapshot)).font(.caption.weight(.medium)).foregroundStyle(.secondary).frame(maxWidth:.infinity).padding(.bottom,4)}
                ForEach(0..<slots,id:\.self) {slot in
                    let index=slot-snapshot.leadingEmptyDays
                    if snapshot.days.indices.contains(index) {
                        let day=snapshot.days[index],selected=model.selectedDay==day.key
                        Button {model.selectedDay=day.key} label:{
                            VStack(alignment:.leading,spacing:7) {
                                Text(day.day.formatted()).font(.caption.weight(.medium))
                                Text(day.sources==0 ? "—":day.sources.formatted(.number.notation(.compactName))).font(.system(size:10,design:.monospaced)).foregroundStyle(day.sources==0 ? .secondary:.primary)
                            }.frame(maxWidth:.infinity,alignment:.leading).frame(minHeight:compact ? 28:42).padding(compact ? 5:7)
                                .background(RoundedRectangle(cornerRadius:7).fill(day.sources==0 ? Color.primary.opacity(0.035):OSwindTheme.accent.opacity(0.10+0.35*log1p(Double(day.sources))/log1p(Double(maximum)))))
                                .overlay(RoundedRectangle(cornerRadius:7).stroke(selected ? OSwindTheme.accent:.clear,lineWidth:2))
                        }.buttonStyle(.plain).disabled(!day.available).focused($focusedDay,equals:day.key)
                            .accessibilityLabel(day.key+", "+(day.available ? "\(day.sources) saved sources":"date unavailable in this time zone"))
                            .help(day.available ? "\(day.sources) saved sources · select to inspect hours":"This civil date did not occur in the selected time zone")
                    }else {Color.clear.frame(minHeight:compact ? 38:56).accessibilityHidden(true)}
                }
            }
            HStack(spacing:6) {Text("Fewer");ForEach(0..<5,id:\.self) {level in RoundedRectangle(cornerRadius:2).fill(level==0 ? Color.primary.opacity(0.035):OSwindTheme.accent.opacity(0.10+0.35*Double(level)/4)).frame(width:15,height:9)};Text("More sources");Spacer()}.font(.caption2).foregroundStyle(.secondary)
            Text("Counts include every matching saved source, including imports and recaps. A replay clip counts once at its start time.").font(.caption2).foregroundStyle(.secondary)
        }.padding(compact ? 16:20).background(.background,in:RoundedRectangle(cornerRadius:12))
            .onMoveCommand {direction in
                guard let key=focusedDay ?? model.selectedDay,let index=snapshot.days.firstIndex(where:{$0.key==key}) else {return}
                let step=direction == .left ? -1:direction == .right ? 1:direction == .up ? -7:7,next=index+step
                guard snapshot.days.indices.contains(next),snapshot.days[next].available else {return};model.selectedDay=snapshot.days[next].key;focusedDay=snapshot.days[next].key
            }
    }
    @ViewBuilder private func dayCard(_ snapshot:ActivityCalendarSnapshot,compact:Bool)->some View {
        VStack(alignment:.leading,spacing:compact ? 10:15) {
            if let key=model.selectedDay,let day=snapshot.days.first(where:{$0.key==key}) {
                Text(dayTitle(day,snapshot:snapshot)).font(.headline)
                if snapshot.selectedDay==key {
                    Text("\(day.sources.formatted()) saved sources").font(.caption).foregroundStyle(.secondary)
                    let maximum=max(1,snapshot.hours.map(\.sources).max() ?? 1)
                    ScrollView {
                        VStack(spacing:5) {ForEach(snapshot.hours) {hour in
                            Button {app.browseActivity(start:hour.start,end:hour.end,snapshot:snapshot)} label:{
                                HStack(spacing:7) {
                                    Text(hourTitle(hour,snapshot:snapshot)).font(.system(size:9,design:.monospaced)).frame(width:88,alignment:.leading)
                                    GeometryReader {space in RoundedRectangle(cornerRadius:2).fill(OSwindTheme.accent.opacity(hour.sources==0 ? 0.08:0.65)).frame(width:max(2,space.size.width*Double(hour.sources)/Double(maximum)))}.frame(height:7)
                                    Text(hour.sources.formatted(.number.notation(.compactName))).font(.system(size:9,design:.monospaced)).frame(width:33,alignment:.trailing)
                                }.padding(.vertical,2)
                            }.buttonStyle(.plain).accessibilityLabel(hourTitle(hour,snapshot:snapshot)+", \(hour.sources) saved sources; browse this interval")
                        }}
                    }.frame(height:compact ? 180:250)
                    Text("Each row is an interval of up to one hour. Offsets distinguish repeated clock hours. Select a row to browse its sources.").font(.caption2).foregroundStyle(.secondary)
                    if let start=day.start,let end=day.end {Button("Browse this day") {app.browseActivity(start:start,end:end,snapshot:snapshot)}.buttonStyle(.borderedProminent)}
                }else {ProgressView("Loading intervals…").font(.caption).frame(maxWidth:.infinity,minHeight:160)}
            }else {
                Image(systemName:"calendar").font(.title).foregroundStyle(OSwindTheme.accent)
                Text("Pick a day.").font(.headline)
                Text("See when sources were saved, then open a day or hour without loading the whole archive.").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth:.infinity,alignment:.leading).padding(compact ? 16:20).background(.background,in:RoundedRectangle(cornerRadius:12))
    }
    private func weekday(_ index:Int,snapshot:ActivityCalendarSnapshot)->String {let formatter=DateFormatter();formatter.calendar=Calendar(identifier:.gregorian);formatter.locale = .current;let names=formatter.shortStandaloneWeekdaySymbols ?? ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];return names[(snapshot.firstWeekday-1+index)%7]}
    private func dayTitle(_ day:ActivityCalendarDay,snapshot:ActivityCalendarSnapshot)->String {guard let date=day.start else {return day.key};let formatter=DateFormatter();formatter.calendar=Calendar(identifier:.gregorian);formatter.timeZone=TimeZone(identifier:snapshot.timeZone);formatter.dateStyle = .full;return formatter.string(from:date)}
    private func hourTitle(_ hour:ActivityCalendarHour,snapshot:ActivityCalendarSnapshot)->String {let formatter=DateFormatter();formatter.calendar=Calendar(identifier:.gregorian);formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone=TimeZone(identifier:snapshot.timeZone);formatter.dateFormat="HH:mm XXX";return formatter.string(from:hour.start)}
    private func typeName(_ kind:MemoryKind)->String {switch kind {case .screen:return "Screens";case .audio:return "Audio";case .note:return "Notes";case .summary:return "Recaps"}}
}
struct ActivityCalendarFooter:View {
    @ObservedObject var model:ActivityCalendarModel
    var body:some View {HStack(spacing:6) {if model.busy {ProgressView().controlSize(.mini)};Text(model.error != nil ? "Calendar unavailable":model.snapshot==nil ? "Loading calendar…":"\((model.snapshot?.totalSources ?? 0).formatted()) saved sources · "+model.timeZone.identifier)}}
}
