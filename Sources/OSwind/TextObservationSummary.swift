import SwiftUI
import OSwindCore

struct TextObservationSummary:View {
    let memory:Memory,observation:TextObservationSpan
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Label("\(observation.samples) sampled text observation\(observation.samples==1 ? "":"s")",systemImage:"clock.badge.checkmark").font(.headline)
            Text("First \(stamp(memory.timestamp))\nLast \(stamp(memory.endTimestamp ?? memory.timestamp))").font(.caption).foregroundStyle(.secondary)
            if observation.samples>1 {Text("Largest gap between samples: \(observation.largestGapSeconds.formatted(.number.precision(.fractionLength(1)))) seconds.").font(.caption)}
            Text("Gaps are unobserved. This range does not establish continuous presence, attention or time spent.").font(.caption).foregroundStyle(.secondary)
            Text("Inspection and answers keep this extent fixed; later observations are saved separately.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(14).background(OSwindTheme.accent.opacity(0.06),in:RoundedRectangle(cornerRadius:8))
    }
    private func stamp(_ date:Date)->String {date.formatted(date:.abbreviated,time:.standard)+" "+(TimeZone.current.abbreviation(for:date) ?? TimeZone.current.identifier)}
}

struct CaptureHealthSummary:View {
    let metrics:CaptureMetrics
    var body:some View {
        LazyVGrid(columns:[GridItem(.adaptive(minimum:140),alignment:.leading)],alignment:.leading,spacing:8) {
            Text("\(metrics.saved) sources saved")
            Text("\(metrics.coalesced) text samples joined")
            Text("\(max(0,metrics.unchanged-metrics.coalesced)) duplicates skipped")
            Text("\(metrics.excluded) excluded")
            Text("\(metrics.errors) errors")
        }.font(.caption).foregroundStyle(.secondary)
    }
}
