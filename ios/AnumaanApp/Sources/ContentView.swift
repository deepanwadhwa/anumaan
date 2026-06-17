import SwiftUI
import UIKit
import CoreLocation
import AnumaanCore

struct ContentView: View {
    var body: some View {
        TabView {
            NavigateView()
                .tabItem { Label("Navigate", systemImage: "location.north.line") }
            TrackView()
                .tabItem { Label("Track Back", systemImage: "point.topleft.down.curvedto.point.bottomright.up") }
            LostView()
                .tabItem { Label("Recover", systemImage: "exclamationmark.triangle") }
            SensorsView()
                .tabItem { Label("Sensors", systemImage: "gauge.with.dots.needle.bottom.50percent") }
        }
    }
}

/// Phase-1 sensing readout — proves CoreMotion drives the engine on-device.
struct SensorsView: View {
    @StateObject private var sensing = SensingService()
    @ObservedObject private var dbg = DebugLog.shared
    @State private var shareItem: ShareItem?

    var body: some View {
        VStack(spacing: 16) {
            Text("Anumaan — sensing").font(.title2).bold()
            if !sensing.available {
                Text("CoreMotion not available (simulator?).")
                    .foregroundStyle(.red).multilineTextAlignment(.center)
            }
            let s = sensing.state
            Grid(horizontalSpacing: 16, verticalSpacing: 12) {
                row("moving", s.isStationary ? "STOPPED" : "MOVING", s.isStationary ? .orange : .green)
                row("heading", String(format: "%.0f°", s.headingDeg), .primary)
                row("Δheading (leg)", String(format: "%+.0f°", s.headingChangeDeg), .primary)
                row("yaw rate", String(format: "%+.1f °/s", s.yawRateDps), .primary)
                row("compass", s.hasMag ? "ok" : "calibrating…", s.hasMag ? .green : .orange)
            }
            .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 14))

            debugRecorder
            Spacer()
        }
        .padding()
        .onAppear { sensing.start() }
        .onDisappear { sensing.stop() }
        .sheet(item: $shareItem) { item in ShareSheet(items: item.urls) }
    }

    @ViewBuilder private var debugRecorder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $dbg.autoRecord) {
                Label("Auto-record every session (+ GPS truth)", systemImage: "record.circle")
            }
            if dbg.recording {
                Text("● Recording \(dbg.currentName) — \(dbg.lineCount) lines")
                    .font(.caption).foregroundStyle(.red)
            } else if dbg.autoRecord {
                Text("Armed — recording starts when you tap Start (navigate) or I’m Lost (recover).")
                    .font(.caption2).foregroundStyle(.green)
            } else if let latest = dbg.logs().first {
                Text("Latest: \(latest.lastPathComponent)").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Auto-record is off — turn it on before heading out.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if dbg.recording {
                Button { dbg.stop() } label: {
                    Label("Stop & save", systemImage: "stop.circle.fill")
                }.buttonStyle(.borderedProminent).tint(.red)
            } else if !dbg.logs().isEmpty {
                // Share ONE log at a time. The newest is on top and pre-flagged;
                // tap any row's arrow to send just that file.
                let logs = dbg.logs()
                Button { shareItem = ShareItem(urls: [logs[0]]) } label: {
                    Label("Share latest log", systemImage: "square.and.arrow.up")
                }.buttonStyle(.borderedProminent)
                VStack(spacing: 0) {
                    ForEach(Array(logs.prefix(12).enumerated()), id: \.element) { i, url in
                        HStack {
                            Text(prettyLog(url) + (i == 0 ? "  ·  newest" : ""))
                                .font(.caption2).foregroundStyle(i == 0 ? .primary : .secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { shareItem = ShareItem(urls: [url]) } label: {
                                Image(systemName: "square.and.arrow.up")
                            }.buttonStyle(.borderless)
                        }
                        .padding(.vertical, 6)
                        if url != logs.prefix(12).last { Divider() }
                    }
                }
                HStack {
                    Button { shareItem = ShareItem(urls: logs) } label: {
                        Text("Share all (\(logs.count))").font(.caption)
                    }.buttonStyle(.bordered)
                    Spacer()
                    Button(role: .destructive) { dbg.clear() } label: {
                        Label("Clear", systemImage: "trash").font(.caption)
                    }.buttonStyle(.bordered)
                }
            } else {
                Text("No logs yet.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    /// "anumaan-2026-06-06T20-26-45Z.jsonl" → "Jun 6, 20:26" for the share list.
    private func prettyLog(_ url: URL) -> String {
        let s = url.lastPathComponent
            .replacingOccurrences(of: "anumaan-", with: "")
            .replacingOccurrences(of: ".jsonl", with: "")
        // "2026-06-06T20-26-45Z" → date + HH:MM
        let parts = s.split(separator: "T")
        guard parts.count == 2 else { return s }
        let d = parts[0].split(separator: "-"), t = parts[1].split(separator: "-")
        guard d.count == 3, t.count >= 2 else { return s }
        let months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let mi = Int(d[1]) ?? 0
        return "\(mi < months.count ? months[mi] : d[1].description) \(Int(d[2]) ?? 0), \(t[0]):\(t[1])"
    }

    @ViewBuilder private func row(_ k: String, _ v: String, _ color: Color) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            Text(v).bold().foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .trailing).monospacedDigit()
        }
    }
}

struct ShareItem: Identifiable { let id = UUID(); let urls: [URL] }

/// Wraps UIActivityViewController so a log file can be AirDropped / saved to Files.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

#Preview { ContentView() }
