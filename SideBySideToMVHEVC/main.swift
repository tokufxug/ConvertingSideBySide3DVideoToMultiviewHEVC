/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Processes command-line arguments and calls the converter from side-by-side to multiview video.
*/

import Foundation

guard CommandLine.arguments.count > 1 else { fatalError("USAGE: \(CommandLine.arguments[0]) side-by-side-video-path") }
let sideBySideVideo = URL(fileURLWithPath: CommandLine.arguments[1])
let converter = try await SideBySideConverter(from: sideBySideVideo)

let fileName = sideBySideVideo.deletingPathExtension().lastPathComponent + "_MVHEVC.mov"
let mvHEVCVideo = sideBySideVideo.deletingLastPathComponent().appendingPathComponent(fileName)

if FileManager.default.fileExists(atPath: mvHEVCVideo.path(percentEncoded: true)) {
	try FileManager.default.removeItem(at: mvHEVCVideo)
}

await converter.transcodeToMVHEVC(output: mvHEVCVideo)

print("MV-HEVC video encoded to \(mvHEVCVideo)")
