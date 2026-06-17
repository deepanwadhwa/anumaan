import SwiftUI
import CoreLocation
import UIKit

/// The wilderness "I'm Lost" recovery flow: panic → walk straight (siphon
/// barometer + heading) → cull ghosts → location lock.
struct LostView: View {
    @StateObject private var vm = RecoveryViewModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            MapView(center: vm.center, recenterTrigger: vm.recenter, recenterZoom: 12,
                    ghosts: vm.ghosts, candidates: vm.candidates,
                    coverageRects: vm.coverageRects, dest: vm.located,
                    onRegion: { s, w, n, e in vm.setVisibleRegion(s: s, w: w, n: n, e: e) })
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                if vm.sensing.motionDenied {
                    Label("Enable Settings ▸ Privacy ▸ Motion & Fitness ▸ Anumaan to track your walk.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(vm.status).font(.callout).frame(maxWidth: .infinity, alignment: .leading)

                if !vm.walkWarning.isEmpty {
                    Text(vm.walkWarning)
                        .font(.callout).foregroundStyle(.white)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red, in: RoundedRectangle(cornerRadius: 10))
                }

                switch vm.phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity)

                case .noData:
                    EmptyView()

                case .ready:
                    Label(vm.searchAreaSet
                          ? "Searching only the area on screen. Pan/zoom to change it."
                          : "First: pan & zoom the map to roughly where you are — the search only looks there.",
                          systemImage: vm.searchAreaSet ? "scope" : "hand.draw")
                        .font(.caption).foregroundStyle(vm.searchAreaSet ? .green : .orange)
                    Button { vm.panic() } label: {
                        Label("I’m Lost", systemImage: "exclamationmark.triangle.fill")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large).tint(.red)
                    Text("Already see a street sign or shop? Just type it.")
                        .font(.caption).foregroundStyle(.secondary)
                    nameSearch

                case .scattered:
                    if !vm.candidates.isEmpty { candidateList }
                    Text(vm.hasTrack ? "Keep walking — what are you on now?"
                                     : "What are you walking on?")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button { vm.walk(.road) } label: {
                            Label("Paved road", systemImage: "car.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                        Button { vm.walk(.trail) } label: {
                            Label("Trail", systemImage: "figure.hiking").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).controlSize(.large).tint(.green)
                    }
                    HStack(spacing: 10) {
                        Button { vm.walk(.offtrail) } label: {
                            Label("Off-trail", systemImage: "leaf.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).controlSize(.large).tint(.brown)
                        Button { vm.walk(.driving) } label: {
                            Label("Driving", systemImage: "car.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).controlSize(.large).tint(.indigo)
                    }
                    if vm.hasTrack { downhillButton }
                    nameSearch
                    Button("Restart") { vm.reset() }.buttonStyle(.bordered).tint(.secondary).controlSize(.small)

                case .walking:
                    HStack(spacing: 10) {
                        hud("heading", String(format: "%.0f°", vm.liveHeading))
                        if vm.driving {
                            hud("driving", driveClock(vm.driveSeconds))
                            hud(vm.liveMoving ? "moving" : "stopped", String(format: "%+.1f m", vm.walkClimb))
                        } else {
                            hud("steps", "\(vm.walkSteps)")
                            hud("climb", String(format: "%+.1f m", vm.walkClimb))
                        }
                    }
                    if vm.driving {
                        Text("Matching your turns, elevation and stops against the roads (assuming you drive near each section’s limit). Make a few turns and stops, then tap “Find me”.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Button { vm.finishWalk() } label: {
                        Label("Find me", systemImage: "scope")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                    nameSearch

                case .locating:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Pinpointing your location…").font(.callout)
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)

                case .interrogate:
                    Text(vm.questionText).font(.headline).multilineTextAlignment(.leading)
                    HStack(spacing: 10) {
                        Button { vm.answer(yes: true) } label: {
                            Label("Yes", systemImage: "checkmark").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                        Button { vm.answer(yes: false) } label: {
                            Label("No", systemImage: "xmark").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).controlSize(.large).tint(.teal)
                    }
                    downhillButton
                    nameSearch
                    Button("Can’t tell — walk instead") { vm.skipQuestion() }
                        .buttonStyle(.bordered).tint(.secondary)

                case .located:
                    HStack(spacing: 6) {
                        Image(systemName: vm.lockTentative ? "questionmark.circle.fill" : "checkmark.seal.fill")
                            .foregroundStyle(vm.lockTentative ? .orange : .green)
                        Text(vm.lockTentative ? "Likely here · ~\(Int((vm.lockConfidence * 100).rounded()))% sure"
                                              : "Location lock").font(.headline)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if let c = vm.located {
                        Text(String(format: "📍 %.5f, %.5f", c.latitude, c.longitude))
                            .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if vm.lockTentative {
                        Button { vm.walkMore() } label: {
                            Label("Walk more to confirm", systemImage: "figure.walk").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    HStack(spacing: 10) {
                        Button { vm.rejectLock() } label: {
                            Label("Not here", systemImage: "hand.thumbsdown").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).controlSize(.large).tint(.orange)
                        Button("Recover again") { vm.reset() }
                            .buttonStyle(.bordered).controlSize(.large).frame(maxWidth: .infinity)
                    }
                    nameSearch
                }
            }
            .padding(16).frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding(12)
        }
    }

    /// Positive identification — name any street/landmark you can see. One match
    /// localizes far better than answering "no" to street after street.
    @ViewBuilder private var nameSearch: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "signpost.right.fill").foregroundStyle(.secondary)
                TextField("See a street sign or shop? Type it",
                          text: Binding(get: { vm.nameQuery }, set: { vm.updateNameSuggestions($0) }))
                    .autocorrectionDisabled()
            }
            .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            ForEach(vm.nameSuggestions, id: \.self) { n in
                Button { vm.pickName(n) } label: {
                    Label(n, systemImage: "mappin.and.ellipse")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.font(.subheadline).padding(.vertical, 2)
            }
        }
    }

    /// Point the phone level, downhill, and tap — the heading is the fall line,
    /// which prunes candidates whose terrain slopes a different way. Free, no walk.
    @ViewBuilder private var downhillButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()   // confirm the tap landed
            vm.markDownhill()
        } label: {
            Label("Point phone downhill & tap", systemImage: "arrow.down.to.line")
                .frame(maxWidth: .infinity)
        }.buttonStyle(.bordered).controlSize(.large).tint(.indigo)
    }

    @ViewBuilder private var candidateList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Candidates").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(vm.candidates.enumerated()), id: \.offset) { _, c in
                Text(String(format: "• %.4f, %.4f", c.latitude, c.longitude))
                    .font(.caption).monospacedDigit()
            }
        }
    }

    @ViewBuilder private func hud(_ k: String, _ v: String) -> some View {
        VStack(spacing: 2) {
            Text(k).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.subheadline).bold().monospacedDigit()
        }
        .padding(8).frame(maxWidth: .infinity).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func driveClock(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}
