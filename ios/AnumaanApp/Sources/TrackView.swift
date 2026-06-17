import SwiftUI
import CoreLocation

/// Breadcrumb tracker: mark your start, walk, then get a compass arrow home.
struct TrackView: View {
    @StateObject private var vm = TrackViewModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            MapView(center: vm.center, recenterTrigger: vm.recenter, recenterZoom: 15,
                    follow: vm.follow, routeCoords: vm.crumbs, vehicle: vm.here,
                    coverageRects: vm.coverageRects, home: vm.startPin,
                    onTap: { vm.tapStart($0) },
                    onRegion: { vm.regionChanged(s: $0, w: $1, n: $2, e: $3) })
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                Text(vm.status).font(.callout).frame(maxWidth: .infinity, alignment: .leading)

                switch vm.mode {
                case .idle:
                    Button { vm.start() } label: {
                        Label("Start here", systemImage: "mappin.and.ellipse").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                    Text("Tip: pan the map so your trailhead/car is centered (or tap it), then Start. Works with no signal once the area is downloaded.")
                        .font(.caption2).foregroundStyle(.secondary)

                case .tracking:
                    HStack(spacing: 10) {
                        stat("walked", String(format: "%.0f m", vm.distWalked))
                        stat("from start", String(format: "%.0f m", vm.distFromStart))
                        stat("elevation", String(format: "%+.0f m", vm.elevFromStart))
                    }
                    Button { vm.takeMeBack() } label: {
                        Label("Take me back", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large).tint(.green)
                    Button("Stop tracking") { vm.stop() }.buttonStyle(.bordered).tint(.secondary).controlSize(.small)

                case .returning:
                    arrow
                    Button("Stop") { vm.stop() }.buttonStyle(.bordered).tint(.red).controlSize(.large).frame(maxWidth: .infinity)
                }
            }
            .padding(16).frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding(12)
        }
    }

    /// Big compass arrow that points at the start in the REAL world as you turn.
    @ViewBuilder private var arrow: some View {
        VStack(spacing: 6) {
            Image(systemName: "location.north.fill")
                .font(.system(size: 76))
                .foregroundStyle(.green)
                .rotationEffect(.degrees(vm.backBearingTrue - vm.liveHeading))
                .animation(.easeInOut(duration: 0.2), value: vm.backBearingTrue - vm.liveHeading)
            Text(String(format: "%.0f m of your path left", vm.distFromStart))
                .font(.title3).bold().monospacedDigit()
            Text("Walk where the arrow points — it follows your own breadcrumb trail back, segment by segment (robust to compass drift). The line on the map is your exact route.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder private func stat(_ k: String, _ v: String) -> some View {
        VStack(spacing: 2) {
            Text(k).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.subheadline).bold().monospacedDigit()
        }
        .padding(8).frame(maxWidth: .infinity).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
