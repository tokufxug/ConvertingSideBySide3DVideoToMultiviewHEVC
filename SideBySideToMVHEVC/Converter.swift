/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Reads side-by-side video input and performs conversion to a multiview QuickTime video file.
*/

import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import VideoToolbox

/// This sample uses the left eye for video layer ID 0 (the hero eye) and the right eye for layer ID 1.
/// - Tag: VideoLayers
let MVHEVCVideoLayerIDs = [0, 1]

/// Transcodes side-by-side HEVC to MV-HEVC.
final class SideBySideConverter: Sendable {
	let sideBySideFrameSize: CGSize
    let eyeFrameSize: CGSize
    
	let reader: AVAssetReader
	let sideBySideTrack: AVAssetReaderTrackOutput

    /// Loads a video to read for conversion.
	/// - Parameter url: A URL to a side-by-side HEVC file.
    /// - Tag: ReadInputVideo
	init(from url: URL) async throws {
		let asset = AVURLAsset(url: url)
		reader = try AVAssetReader(asset: asset)

		// Get the side-by-side video track.
		guard let videoTrack = try await asset.loadTracks(withMediaCharacteristic: .visual).first else {
            fatalError("Error loading side-by-side video input")
		}
        
        sideBySideFrameSize = try await videoTrack.load(.naturalSize)
        eyeFrameSize = CGSize(width: sideBySideFrameSize.width / 2, height: sideBySideFrameSize.height)

		let readerSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
										  kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
		]
		sideBySideTrack = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerSettings)

		if reader.canAdd(sideBySideTrack) {
			reader.add(sideBySideTrack)
		}

        if !reader.startReading() {
			fatalError(reader.error?.localizedDescription ?? "Unknown error during track read start")
		}
	}
    
	/// Transcodes  side-by-side HEVC media to MV-HEVC.
    /// - Parameter output: The output URL to write the MV-HEVC file to.
    /// - Tag: TranscodeVideo
	func transcodeToMVHEVC(output videoOutputURL: URL) async {
		await withCheckedContinuation { continuation in
			Task {
				let multiviewWriter = try AVAssetWriter(outputURL: videoOutputURL, fileType: AVFileType.mov)

                let multiviewCompressionProperties: [String: Any] = [kVTCompressionPropertyKey_MVHEVCVideoLayerIDs as String: MVHEVCVideoLayerIDs,
																		  kVTCompressionPropertyKey_MVHEVCViewIDs as String: MVHEVCVideoLayerIDs,
															  kVTCompressionPropertyKey_MVHEVCLeftAndRightViewIDs as String: MVHEVCVideoLayerIDs,
																   kVTCompressionPropertyKey_HasLeftStereoEyeView as String: true,
																  kVTCompressionPropertyKey_HasRightStereoEyeView as String: true
				]
				let multiviewSettings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc,
                                                     AVVideoWidthKey: self.eyeFrameSize.width,
                                                    AVVideoHeightKey: self.eyeFrameSize.height,
									  AVVideoCompressionPropertiesKey: multiviewCompressionProperties
				]
		
				guard multiviewWriter.canApply(outputSettings: multiviewSettings, forMediaType: AVMediaType.video) else {
					fatalError("Error applying output settings")
				}

				let frameInput = AVAssetWriterInput(mediaType: .video, outputSettings: multiviewSettings)

				let sourcePixelAttributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                                            kCVPixelBufferWidthKey as String: self.sideBySideFrameSize.width,
                                                            kCVPixelBufferHeightKey as String: self.sideBySideFrameSize.height
				]

				let bufferInputAdapter = AVAssetWriterInputTaggedPixelBufferGroupAdaptor(assetWriterInput: frameInput, sourcePixelBufferAttributes: sourcePixelAttributes)

				guard multiviewWriter.canAdd(frameInput) else {
					fatalError("Error adding side-by-side video frames as input")
				}
				multiviewWriter.add(frameInput)

				guard multiviewWriter.startWriting() else {
					fatalError("Failed to start writing multiview output file")
				}
				multiviewWriter.startSession(atSourceTime: CMTime.zero)

                // The dispatch queue executes the closure when media reads from the input file are available.
				frameInput.requestMediaDataWhenReady(on: DispatchQueue(label: "Multiview HEVC Writer")) {
                    var session: VTPixelTransferSession? = nil
                    guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr, let session else {
                        fatalError("Failed to create pixel transfer")
                    }
                    var pixelBufferPool: CVPixelBufferPool? = nil
                    
                    if pixelBufferPool == nil {
                        let bufferPoolSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32ARGB),
                                                                 kCVPixelBufferWidthKey as String: self.eyeFrameSize.width,
                                                                 kCVPixelBufferHeightKey as String: self.eyeFrameSize.height,
                                                                 kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
                        ]
                        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, bufferPoolSettings as NSDictionary, &pixelBufferPool)
                    }
                        
                    guard let pixelBufferPool else {
                        fatalError("Failed to create pixel buffer pool")
                    }
                   
                    // Handling all available frames within the closure improves performance.
					while frameInput.isReadyForMoreMediaData && bufferInputAdapter.assetWriterInput.isReadyForMoreMediaData {
                        if let sampleBuffer = self.sideBySideTrack.copyNextSampleBuffer() {
                            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                                fatalError("Failed to load source samples as an image buffer")
                            }
                            
                            if let taggedBuffers = self.convertFrame(fromSideBySide: imageBuffer, with: pixelBufferPool, in: session) {
                                let newPTS = sampleBuffer.outputPresentationTimeStamp
                                if !bufferInputAdapter.appendTaggedBuffers(taggedBuffers, withPresentationTime: newPTS) {
                                    fatalError("Failed to append tagged buffers to multiview output")
                                }
                            } else {
                                frameInput.markAsFinished()
                                multiviewWriter.finishWriting {
                                    continuation.resume()
                                }
                                
                                break
                            }
                        }
                    }
				}
			}
		}
	}
	
	/// Splits a side-by-side sample buffer into two tagged buffers for left and right eyes.
	/// - Parameters:
    ///   - fromSideBySide: The side-by-side sample buffer to extract individual eye buffers from.
    ///   - with: The pixel buffer pool used to create temporary buffers for pixel copies.
    ///   - in: The transfer session to perform the pixel transfer.
	/// - Returns: Group of tagged buffers for the left and right eyes.
    /// - Tag: ConvertFrame
    func convertFrame(fromSideBySide imageBuffer: CVImageBuffer, with pixelBufferPool: CVPixelBufferPool, in session: VTPixelTransferSession) -> [CMTaggedBuffer]? {
        // Output contains two tagged buffers, left eye frame first.
		var taggedBuffers: [CMTaggedBuffer] = []

		for layerID in MVHEVCVideoLayerIDs {
			var pixelBuffer: CVPixelBuffer?
			CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBuffer)
			guard let pixelBuffer else {
				fatalError("Failed to create pixel buffer for layer \(layerID)")
			}

            // Crop the transfer region to the current eye.
            let apertureOffset = -(self.eyeFrameSize.width / 2) + CGFloat(layerID) * self.eyeFrameSize.width
            let cropRectDict = [kCVImageBufferCleanApertureHorizontalOffsetKey: apertureOffset,
								  kCVImageBufferCleanApertureVerticalOffsetKey: 0,
                                           kCVImageBufferCleanApertureWidthKey: self.eyeFrameSize.width,
                                          kCVImageBufferCleanApertureHeightKey: self.eyeFrameSize.height
            ]
			CVBufferSetAttachment(imageBuffer, kCVImageBufferCleanApertureKey, cropRectDict as CFDictionary, CVAttachmentMode.shouldPropagate)
			VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_CropSourceToCleanAperture)

			// Transfer the image to the pixel buffer.
			guard VTPixelTransferSessionTransferImage(session, from: imageBuffer, to: pixelBuffer) == noErr else {
				fatalError("Error during pixel transfer session for layer \(layerID)")
			}

			// Create and append tagged buffers containing the left and right eye images.
            switch layerID {
            case 0: // Left eye buffer
                let leftTags: [CMTag] = [.videoLayerID(0), .stereoView(.leftEye)]
                let leftBuffer = CMTaggedBuffer(tags: leftTags, buffer: .pixelBuffer(pixelBuffer))
                taggedBuffers.append(leftBuffer)
            case 1: // Right eye buffer
                let rightTags: [CMTag] = [.videoLayerID(1), .stereoView(.rightEye)]
                let rightBuffer = CMTaggedBuffer(tags: rightTags, buffer: .pixelBuffer(pixelBuffer))
                taggedBuffers.append(rightBuffer)
            default:
                fatalError("Invalid video layer \(layerID)")
            }
		}
		
		return taggedBuffers
	}
}
