# Converting side-by-side 3D video to multiview HEVC

Create video content for visionOS by converting an existing 3D HEVC file to a multiview HEVC format.

## Overview

In visionOS, 3D video uses the _Multiview High Efficiency Video Encoding_ (MV-HEVC) format, supported by MPEG4 and QuickTime. Unlike other 3D media, MV-HEVC stores a single track containing multiple layers for the video, where the track and layers share a frame size. This track frame size is different from other 3D video types, such as _side-by-side video_. Side-by-side videos use a single track, and place the left and right eye images next to each other as part of a single video frame.

To convert side-by-side video to MV-HEVC, you load the source video, extract each frame, and then split the frame horizontally. Then copy the left and right sides of the split frame into the left eye and right eye layers, writing a frame containing both layers to the output.

This sample app demonstrates the process for converting side-by-side video files to MV-HEVC, encoding the output as a QuickTime file. The output is placed in the same directory as the input file, with `_MVHEVC` appended to the original filename.

You can verify this sample's MV-HEVC output by opening it with the sample project from [Reading multiview 3D video files][1].

For the full details of the MV-HEVC format, see [Apple HEVC Stereo Video - Interoperability Profile (PDF)](https://developer.apple.com/av-foundation/HEVC-Stereo-Video-Profile.pdf) and [ISO Base Media File Format and Apple HEVC Stereo Video (PDF)](https://developer.apple.com/av-foundation/Stereo-Video-ISOBMFF-Extensions.pdf).

## Configure the sample code project

You need your own side-by-side source video, which has the track containing side-by-side frames as its first available video media track. The app takes the input file as a single command-line argument. To run the app in Xcode, add the input file as an argument with Select Product &gt; Scheme &gt; Edit Scheme (Command-&lt;), and add the path to your file to Arguments Passed On Launch.

## Load the side-by-side video

The app starts by loading the side-by-side video, creating an [`AVAssetReader`][2]. The app calls [`loadTracks(withMediaCharacteristic:)`][3] to load video tracks, and then selects the first track available as the side-by-side input.

``` swift
let asset = AVURLAsset(url: url)
reader = try AVAssetReader(asset: asset)

// Get the side-by-side video track.
guard let videoTrack = try await asset.loadTracks(withMediaCharacteristic: .visual).first else {
          fatalError("Error loading side-by-side video input")
}
```
[View in Source][ReadInputVideo]

The app also stores the frame size for the side-by-side video, and calculates the size of the output frames.

``` swift
sideBySideFrameSize = try await videoTrack.load(.naturalSize)
eyeFrameSize = CGSize(width: sideBySideFrameSize.width / 2, height: sideBySideFrameSize.height)
```
[View in Source][ReadInputVideo]

To finish loading the video, the app creates an [`AVAssetReaderTrackOutput`][4] and then adds this output stream to the `AVAssetReader`.

``` swift
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
```
[View in Source][ReadInputVideo]

When creating the reader track output, the app specifies the file's pixel format and [`IOSurface`][5] settings in the `readerSettings` dictionary. The app indicates that output goes to a 32-bit ARGB pixel buffer, using [`kCVPixelBufferPixelFormatTypeKey`][6] with a value of [`kCVPixelFormatType_32ARGB`][7]. The sample app also manages its own pixel buffer allocations, passing an empty array as the value for [`kCVPixelBufferIOSurfacePropertiesKey`][8].

## Configure the output MV-HEVC file

With the reader initialized, the app calls the `async` method [`convertFrame(fromSideBySide:with:in:)`][TranscodeVideo] to generate the output file. First, the app creates a new [`AVAssetWriter`][9] pointing to the video output location, and then configures the necessary information on the output to indicate that the file contains MV-HEVC video.

``` swift
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
```
[View in Source][TranscodeVideo]

[`kVTCompressionPropertyKey_HasLeftStereoEyeView`][10] and [`kVTCompressionPropertyKey_HasRightStereoEyeView`][11] are `true`, because the output contains a layer for each eye. These video track IDs are in the output metadata through the [`kVTCompressionPropertyKey_MVHEVCVideoLayerIDs`][12], [`kVTCompressionPropertyKey_MVHEVCViewIDs`][13], and [`kVTCompressionPropertyKey_MVHEVCLeftAndRightViewIDs`][14] settings keys. In the sample app, these are all the same, for consistency.

The sample app uses `0` for the left eye layer and `1` for the right eye layer.

``` swift
let MVHEVCVideoLayerIDs = [0, 1]
```
[View in Source][VideoLayers]

## Configure the MV-HEVC input source

The app transcodes video by directly copying pixels from the source frame. Writing track data to a video file requires an [`AVAssetWriterInput`][15]. The sample app uses an [`AVAssetWriterInputTaggedPixelBufferGroupAdaptor`][16] to provide pixel data from the source, writing to the output.

``` swift
let frameInput = AVAssetWriterInput(mediaType: .video, outputSettings: multiviewSettings)

let sourcePixelAttributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                                        kCVPixelBufferWidthKey as String: self.sideBySideFrameSize.width,
                                                        kCVPixelBufferHeightKey as String: self.sideBySideFrameSize.height
]

let bufferInputAdapter = AVAssetWriterInputTaggedPixelBufferGroupAdaptor(assetWriterInput: frameInput, sourcePixelBufferAttributes: sourcePixelAttributes)
```
[View in Source][TranscodeVideo]

The `AVAssetWriterInput` source uses the same `outputSettings` as `videoWriter`, and the created pixel buffer adapter has the same frame size as the source. The app follows the best practice of calling [`canAdd(_:)`][17] to check the input adapter compatibility before calling [`add(_:)`][18] to use it as a source.

``` swift
guard multiviewWriter.canAdd(frameInput) else {
	fatalError("Error adding side-by-side video frames as input")
}
multiviewWriter.add(frameInput)
```
[View in Source][TranscodeVideo]

## Process input as it becomes available

The app calls [`startWriting()`][19] and [`startSession(atSourceTime:)`][20] in sequence to start the video writing process, and then iterates over available frame inputs with [`requestMediaDataWhenReady(on:using:)`][21].

``` swift
guard multiviewWriter.startWriting() else {
	fatalError("Failed to start writing multiview output file")
}
multiviewWriter.startSession(atSourceTime: CMTime.zero)

            // The dispatch queue executes the closure when media reads from the input file are available.
frameInput.requestMediaDataWhenReady(on: DispatchQueue(label: "Multiview HEVC Writer")) {
```
[View in Source][TranscodeVideo]

The closure argument of `requestMediaDataWhenReady(on:using:)` runs on the provided [`DispatchQueue`][22] when the first data read is available. The closure itself is responsible for managing resources that process the media data, and running a loop to process data efficiently.

## Create the video frame transfer session and output pixel buffer pool

To perform the data transfer from the source track, the pixel input adapter requires a pixel buffer as a source. The app creates a [`VTPixelTransferSession`][23] to allow for reading data from the video source, and then creates a [`CVPixelBufferPool`][24] to allocate pixel buffers for the new multiview eye layers.

``` swift
var session: VTPixelTransferSession? = nil
guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr, let session else {
    fatalError("Failed to create pixel transfer")
}
var pixelBufferPool: CVPixelBufferPool? = nil
```
[View in Source][TranscodeVideo]

The app copies frames with temporary buffers allocated from the buffer pool that holds the eye images before writing to output. Creating a buffer pool before looping over available data and then using it to create individual eye images later reduces the amount of memory the app uses, as well as the amount of time it takes to process each frame.

## Copy frame images from input to output

After preparing resources, the app then begins a loop to process frames until there's no more data, or the input read has stopped to buffer data. The [`isReadyForMoreMediaData`][26] property of an input source is `true` if another frame is immediately available to process. When a frame is ready, a [`CVImageBuffer`][27] instance is created from it.

The app is now ready to handle sampling. If there's an available sample, the app processes it in the [`convertFrame`][ConvertFrame] method, then calls [`appendTaggedBuffers(_:withPresentationTime:)`][28], copying the side-by-side sample buffer's [`outputPresentationTimestamp`][29] timestamp to the new multiview timestamp.

``` swift
while frameInput.isReadyForMoreMediaData && bufferInputAdapter.assetWriterInput.isReadyForMoreMediaData {
                   if let sampleBuffer = self.sideBySideTrack.copyNextSampleBuffer() {
                       guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                           fatalError("Failed to load source samples as an image buffer")
                       }
                       let taggedBuffers = self.convertFrame(fromSideBySide: imageBuffer, with: pixelBufferPool, in: session)
                       let newPTS = sampleBuffer.outputPresentationTimeStamp
                       if !bufferInputAdapter.appendTaggedBuffers(taggedBuffers, withPresentationTime: newPTS) {
                           fatalError("Failed to append tagged buffers to multiview output")
                       }
```
[View in Source][TranscodeVideo]

Input reading finishes when there are no more sample buffers to process from the input stream. The app calls [`markAsFinished()`][30] to close the stream, and [`finishWriting(completionHandler:)`][31] to complete the multiview video write. The app also calls [`resume()`][32] on its associated [`CheckedContinuation`][33], to return to the `await`ed call, then breaks from the processing loop.

``` swift
frameInput.markAsFinished()
multiviewWriter.finishWriting {
    continuation.resume()
}

break
```
[View in Source][TranscodeVideo]

## Convert side-by-side inputs into video layer outputs

In the `convertFrame` method, the app processes the left and right eye images for the frame by `layerID`, using `0` for the left eye and `1` for the right. First, the app creates a pixel buffer from the pool.

``` swift
var pixelBuffer: CVPixelBuffer?
CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBuffer)
guard let pixelBuffer else {
	fatalError("Failed to create pixel buffer for layer \(layerID)")
}
```
[View in Source][ConvertFrame]

The method then uses its passed `VTPixelTransferSession` to copy the pixels from the side-by-side source, placing them into the created output sample buffer by cropping the frame to include only one eye's image.

``` swift
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
```
[View in Source][ConvertFrame]

Setting aperture view properties on [`CVBufferSetAttachment()`][34] defines how to capture and crop input images. The aperture here is the size of an eye image, and the center of the capture frame offset with [`kCVImageBufferCleanApertureHorizontalOffsetKey`][35] by `-0.5 * width` for the left eye and `+0.5 * width` for the right eye, to capture the correct half of the side-by-side frame.

The app then calls [`VTSessionSetProperty`][36] to crop the image to the aperture frame with [`kVTScalingMode_CropSourceToCleanAperture`][37]. Next, the app calls [`VTPixelTransferSessionTransferImage`][38] to copy source pixels to the destination buffer.

The final step is to create a [`CMTaggedBuffer`][39] for the eye image to return to the calling output writer.

``` swift
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
```
[View in Source][ConvertFrame]

[1]: https://developer.apple.com/documentation/avfoundation/media_reading_and_writing/reading_multiview_3d_video_files
[2]: https://developer.apple.com/documentation/avfoundation/avassetreader
[3]: https://developer.apple.com/documentation/avfoundation/avasset/3746530-loadtracks
[4]: https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput
[5]: https://developer.apple.com/documentation/iosurface
[6]: https://developer.apple.com/documentation/corevideo/kcvpixelbufferpixelformattypekey
[7]: https://developer.apple.com/documentation/corevideo/kcvpixelformattype_32argb
[8]: https://developer.apple.com/documentation/corevideo/kcvpixelbufferiosurfacepropertieskey
[9]: https://developer.apple.com/documentation/avfoundation/avassetwriter
[10]: https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_hasleftstereoeyeview
[11]: https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_hasrightstereoeyeview
[12]: https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_mvhevcvideolayerids
[13]: https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_mvhevcviewids
[14]: https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_mvhevcleftandrightviewids
[15]: https://developer.apple.com/documentation/avfoundation/avassetwriterinput
[16]: https://developer.apple.com/documentation/avfoundation/avassetwriterinputpixelbufferadaptor
[17]: https://developer.apple.com/documentation/avfoundation/avassetwriter/1387863-canadd
[18]: https://developer.apple.com/documentation/avfoundation/avassetwriter/1390389-add
[19]: https://developer.apple.com/documentation/avfoundation/avassetwriter/1386724-startwriting
[20]: https://developer.apple.com/documentation/avfoundation/avassetwriter/1389908-startsession
[21]: https://developer.apple.com/documentation/avfoundation/avassetwriterinput/1387508-requestmediadatawhenready
[22]: https://developer.apple.com/documentation/dispatch/dispatchqueue
[23]: https://developer.apple.com/documentation/videotoolbox/vtpixeltransfersession
[24]: https://developer.apple.com/documentation/corevideo/cvpixelbufferpool
[26]: https://developer.apple.com/documentation/avfoundation/avassetwriterinput/1389084-isreadyformoremediadata
[27]: https://developer.apple.com/documentation/corevideo/cvimagebuffer
[28]: https://developer.apple.com/documentation/avfoundation/avassetwriterinputpixelbufferadaptor/1388102-append
[29]: https://developer.apple.com/documentation/coremedia/cmsamplebuffer/3242557-outputpresentationtimestamp
[30]: https://developer.apple.com/documentation/avfoundation/avassetwriterinput/1390122-markasfinished
[31]: https://developer.apple.com/documentation/avfoundation/avassetwriter/1390432-finishwriting
[32]: https://developer.apple.com/documentation/swift/checkedcontinuation/resume()
[33]: https://developer.apple.com/documentation/swift/checkedcontinuation
[34]: https://developer.apple.com/documentation/corevideo/1456974-cvbuffersetattachment
[35]: https://developer.apple.com/documentation/corevideo/kcvimagebuffercleanaperturehorizontaloffsetkey
[36]: https://developer.apple.com/documentation/videotoolbox/1536144-vtsessionsetproperty
[37]: https://developer.apple.com/documentation/videotoolbox/kvtscalingmode_cropsourcetocleanaperture
[38]: https://developer.apple.com/documentation/videotoolbox/1503548-vtpixeltransfersessiontransferim
[39]: https://developer.apple.com/documentation/coremedia/cmtaggedbuffer

[VideoLayers]:				x-source-tag://VideoLayers
[ReadInputVideo]: 			x-source-tag://ReadInputVideo
[TranscodeVideo]:           x-source-tag://TranscodeVideo
[ConvertFrame]:             x-source-tag://ConvertFrame
