import SwiftUI
import CoreLocation

struct NavigateView: View {
    @StateObject private var vm = NavViewModel()
    @FocusState private var focusedField: NavViewModel.SearchContext?
    @State private var showDetails = false
    @State private var confirmNewArea = false

    var body: some View {
        ZStack(alignment: .bottom) {
            MapView(center: vm.center, recenterTrigger: vm.recenterTrigger,
                    recenterZoom: vm.recenterZoom, follow: vm.follow,
                    routeCoords: vm.routeCoords, vehicle: vm.vehicle,
                    nextMilestone: vm.nextMilestone, coverageRects: vm.coverageRects,
                    plannedRects: vm.plannedRects,
                    home: vm.home, start: vm.startPin, dest: vm.destPin,
                    onTap: { c in focusedField = nil; vm.clearSuggestions(); vm.handleTap(c) },
                    onRegion: { vm.regionChanged(s: $0, w: $1, n: $2, e: $3) })
                .ignoresSafeArea()

            VStack(spacing: 8) {
                // suggestions only while a field is focused
                if focusedField != nil, !vm.suggestions.isEmpty { suggestionsList }
                card
            }
            .padding(12)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil; vm.clearSuggestions() }
            }
        }
        .onChange(of: focusedField) { if $0 == nil { vm.clearSuggestions() } }
    }

    @ViewBuilder private var suggestionsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(vm.suggestions) { s in
                    Button {
                        focusedField = nil          // dismiss before picking (no re-trigger)
                        vm.pick(s)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title).foregroundStyle(.primary)
                            if !s.subtitle.isEmpty {
                                Text(s.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 9)
                    }
                    Divider()
                }
            }.padding(.horizontal, 12)
        }
        .frame(maxHeight: 200)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch vm.phase {
            case .area:       areaStep
            case .home:       homeStep
            case .route:      routeStep
            case .navigating: navStep
            }
            // Status only when it carries active info — not a permanent "Loaded …".
            if !vm.status.isEmpty, vm.busy || vm.phase == .area || vm.phase == .navigating {
                Text(vm.status).font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12).frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private var areaStep: some View {
        Text("Step 1 · Download your area").font(.headline)
        if vm.planActive {
            planPanel
        } else {
            field("Search city / state / country", text: $vm.areaQuery, ctx: .area)
            Button(action: vm.downloadRoads) {
                Label(vm.busy ? "Downloading…" : "Download this view", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(vm.busy)
            Button(action: vm.planArea) {
                Label("Cover a large region…", systemImage: "square.grid.3x3").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).controlSize(.large).disabled(vm.busy)
            Text("Zoom out to frame a big area (a park, a county), then tap “Cover a large region” — it splits it into grid-aligned downloads and fetches them one at a time.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var planPanel: some View {
        Text(vm.planText.isEmpty ? "Planning…" : vm.planText)
            .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
        if vm.planRunning {
            HStack {
                ProgressView()
                Button("Stop") { vm.stopPlanned() }.buttonStyle(.bordered).tint(.red).controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
        } else {
            HStack(spacing: 10) {
                Button { vm.cancelPlan() } label: {
                    Label("Cancel", systemImage: "xmark").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).controlSize(.large)
                Button(action: vm.downloadPlanned) {
                    Label("Download all", systemImage: "square.and.arrow.down.on.square").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large)
            }
            Text("Orange = queued · green = already offline. Downloads run one at a time with a short pause between, to be gentle on the free servers. Keep the app open.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var homeStep: some View {
        Text("Step 2 · Set a home?").font(.headline)
        Text("Tap the map to drop your home pin — or skip.").font(.subheadline).foregroundStyle(.secondary)
        HStack {
            Button("Skip") { vm.skipHome() }.buttonStyle(.bordered).controlSize(.large).frame(maxWidth: .infinity)
            Button("Save home") { vm.saveHomeAndContinue() }
                .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                .disabled(vm.home == nil)
        }
    }

    @ViewBuilder private var routeStep: some View {
        HStack(spacing: 10) {
            Text("Where to?").font(.headline)
            Spacer()
            Image(systemName: "mountain.2.fill").font(.caption)
                .foregroundStyle(vm.offlineElevReady ? .green : .secondary.opacity(0.35))
            Image(systemName: "map.fill").font(.caption)
                .foregroundStyle(vm.offlineMapReady ? .green : .secondary.opacity(0.35))
            Image(systemName: "drop.fill").font(.caption)
                .foregroundStyle(vm.offlineFeatReady ? .green : .secondary.opacity(0.35))
            Button { vm.addArea() } label: {
                Label("Add area", systemImage: "plus.map").font(.caption2)
            }
            .buttonStyle(.bordered).controlSize(.small)
            Button(role: .destructive) { confirmNewArea = true } label: {
                Image(systemName: "trash").font(.caption2)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .confirmationDialog("Erase ALL downloaded offline areas?",
                                isPresented: $confirmNewArea, titleVisibility: .visible) {
                Button("Erase all offline maps", role: .destructive) { vm.clearAllAreas() }
                Button("Cancel", role: .cancel) {}
            }
        }
        HStack {
            field("Start — type or tap map", text: $vm.startQuery, ctx: .start, icon: "circle.fill", tint: .green)
            Button { vm.useHomeAsStart() } label: { Image(systemName: "house.fill") }.buttonStyle(.bordered)
        }
        field("Destination — type or tap map", text: $vm.destQuery, ctx: .dest, icon: "mappin.circle.fill", tint: .red)
        Button(action: vm.start) {
            Label("Start", systemImage: "location.north.line.fill").frame(maxWidth: .infinity)
        }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!vm.canStart)
    }

    @ViewBuilder private var navStep: some View {
        if vm.sensing.motionDenied {
            Label("Enable Motion & Fitness for Anumaan in Settings to count steps.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange).lineLimit(2)
        }
        if !vm.approachLabel.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(vm.approachLabel).font(.subheadline).bold().lineLimit(1)
                if !vm.approachDetail.isEmpty {
                    Text(vm.approachDetail).font(.caption2)
                        .foregroundStyle(vm.calibrated ? Color.secondary : Color.orange)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        // Same two buttons throughout: the first Reached sets your pace under the
        // hood; later ones keep refining it.
        HStack(spacing: 10) {
            Button { vm.advance() } label: {
                Label("Reached", systemImage: "checkmark").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large).tint(.green)
            Button { vm.notYet() } label: {
                Label("Not yet", systemImage: "xmark").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large).tint(vm.autoPaused ? .gray : .orange)
        }
        HStack {
            Button { withAnimation { showDetails.toggle() } } label: {
                Image(systemName: showDetails ? "chevron.up" : "chevron.down").font(.caption2)
            }
            Spacer()
            Button("Stop") { vm.stopNav() }.buttonStyle(.bordered).tint(.red).controlSize(.small)
        }
        if showDetails {
            HStack(spacing: 10) {
                hud("speed", String(format: "%.1f m/s", vm.speed))
                hud("limit", vm.limitText)
                hud("node", vm.nodeText)
                hud("heading", vm.headingText)
            }
        }
    }

    @ViewBuilder private func field(_ prompt: String, text: Binding<String>, ctx: NavViewModel.SearchContext,
                                    icon: String? = nil, tint: Color = .secondary) -> some View {
        HStack {
            Image(systemName: icon ?? "magnifyingglass").foregroundStyle(tint)
            TextField(prompt, text: text)
                .focused($focusedField, equals: ctx)
                .autocorrectionDisabled()
                .onChange(of: text.wrappedValue) { if focusedField == ctx { vm.updateSuggestions($0, ctx) } }
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = ""; vm.clearSuggestions() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func hud(_ k: String, _ v: String) -> some View {
        VStack(spacing: 2) {
            if !k.isEmpty { Text(k).font(.caption2).foregroundStyle(.secondary) }
            Text(v).font(.subheadline).bold().monospacedDigit()
        }
        .padding(8).frame(maxWidth: .infinity).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
