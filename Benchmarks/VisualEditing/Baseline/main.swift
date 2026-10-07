import Foundation

// Baseline for B: today's regex/lexer scan (Sources/LeftBlankCore/SourcePresentation.swift),
// compiled standalone with -O by scripts/visual-editing-spike.sh. It rescans the whole
// document on every change; there is no incremental mode to compare.
for path in CommandLine.arguments.dropFirst() {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        continue
    }
    var samples: [Double] = []
    var count = 0
    for _ in 0 ..< 5 {
        let start = DispatchTime.now().uptimeNanoseconds
        count = SourcePresentation.decorations(in: text).count
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
    samples.sort()
    print(
        "{\"file\": \"\(path)\", \"decorations\": \(count), \"scan_ms_median\": \(samples[2]), \"scan_ms_max\": \(samples[4])}",
    )
}
