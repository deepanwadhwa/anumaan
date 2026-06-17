import Foundation

// AnumaanSim — platform-agnostic recovery simulator.
// Runs on macOS, Linux, and Windows. No Apple frameworks.
//
//   swift run AnumaanSim                                           # synthetic world
//   swift run AnumaanSim clemson                                   # real area (default route)
//   swift run AnumaanSim clemson 34.674,-82.840 34.685,-82.828     # specific A→B (finds road path)
//   swift run AnumaanSim clemson --path '[[34.674,-82.840],...]'   # drawn path (used by web app)
//   Add --json to any real-area run for machine-readable output

func parseLatLon(_ s: String) -> (Double, Double)? {
    let parts = s.split(separator: ",")
    guard parts.count == 2,
          let lat = Double(parts[0].trimmingCharacters(in: .whitespaces)),
          let lon = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
    return (lat, lon)
}

func parsePathJSON(_ s: String) -> [(Double, Double)]? {
    guard let data = s.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[Double]],
          arr.count >= 2 else { return nil }
    return arr.compactMap { pair -> (Double, Double)? in
        guard pair.count >= 2 else { return nil }
        return (pair[0], pair[1])
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let jsonMode = args.contains("--json")
let positional = args.filter { !$0.hasPrefix("--") }

if !positional.isEmpty {
    let areaName = positional[0]
    // --path overrides A→B routing
    var pathLL: [(Double, Double)]? = nil
    if let pi = args.firstIndex(of: "--path"), pi + 1 < args.count {
        pathLL = parsePathJSON(args[pi + 1])
    }

    var mode = "road"
    if let mi = args.firstIndex(of: "--mode"), mi + 1 < args.count {
        mode = args[mi + 1]
    }

    var bbox: RealArea.BBox? = nil
    if let bi = args.firstIndex(of: "--bbox"), bi + 1 < args.count {
        let parts = args[bi + 1].split(separator: ",")
        if parts.count == 4,
           let s = Double(parts[0]), let w = Double(parts[1]),
           let n = Double(parts[2]), let e = Double(parts[3]) {
            bbox = RealArea.BBox(south: s, west: w, north: n, east: e)
        }
    }

    let coordArgs = positional.filter { $0 != areaName }
    let fromLL = pathLL == nil && coordArgs.count >= 1 ? parseLatLon(coordArgs[0]) : nil
    let toLL   = pathLL == nil && coordArgs.count >= 2 ? parseLatLon(coordArgs[1]) : nil

    do { try await RealArea.run(bbox, name: areaName, fromLL: fromLL, toLL: toLL, pathLL: pathLL, mode: mode, json: jsonMode) }
    catch { FileHandle.standardError.write(Data("AnumaanSim error: \(error)\n".utf8)) }
} else {
    runSyntheticDemo()
}
