import Foundation
import WatchCore

var settings = WatchSettings()
settings.socketPath = ChainReader.suggestedSocket()
settings.chainEnabled = CommandLine.arguments.contains("--chain")
settings.geoEnabled = !CommandLine.arguments.contains("--no-geo")
let sample = await Detector().collect(settings: settings)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
encoder.dateEncodingStrategy = .iso8601
do { print(String(decoding: try encoder.encode(sample), as: UTF8.self)) }
catch { fputs("无法编码检测结果\n", stderr); exit(2) }
exit(sample.canBaseline(settings: settings) ? 0 : 1)
