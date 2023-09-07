/*
See LICENSE folder for this sample’s licensing information.

Abstract:
An object that captures a stream of captured sample buffers containing screen and audio content.
*/

import Foundation
import AVFAudio
import ScreenCaptureKit
import OSLog
import Combine
import Vision
import SwiftUI
import CoreImage
import CoreVideo
import VideoToolbox

/// A structure that contains the video data to render.
struct CapturedFrame {
    static let invalid = CapturedFrame(surface: nil, contentRect: .zero, contentScale: 0, scaleFactor: 0)
    
    let surface: IOSurface?
    let contentRect: CGRect
    let contentScale: CGFloat
    let scaleFactor: CGFloat
    var size: CGSize { contentRect.size }
}

/// An object that wraps an instance of `SCStream`, and returns its results as an `AsyncThrowingStream`.
class CaptureEngine: NSObject, @unchecked Sendable {
    
    private let logger = Logger()
    private var stream: SCStream?
    private let videoSampleBufferQueue = DispatchQueue(label: "com.example.apple-samplecode.VideoSampleBufferQueue")
    private let audioSampleBufferQueue = DispatchQueue(label: "com.example.apple-samplecode.AudioSampleBufferQueue")
    
    // Performs average and peak power calculations on the audio samples.
    private let powerMeter = PowerMeter()
    var audioLevels: AudioLevels { powerMeter.levels }
    
    // Store the the startCapture continuation, so that you can cancel it when you call stopCapture().
    private var continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation?
    
    /// - Tag: StartCapture
    func startCapture(configuration: SCStreamConfiguration, filter: SCContentFilter) -> AsyncThrowingStream<CapturedFrame, Error> {
        AsyncThrowingStream<CapturedFrame, Error> { continuation in
            // The stream output object.
            let streamOutput = CaptureEngineStreamOutput(continuation: continuation)
            streamOutput.capturedFrameHandler = { continuation.yield($0) }
            streamOutput.pcmBufferHandler = { self.powerMeter.process(buffer: $0) }
            
            do {
                stream = SCStream(filter: filter, configuration: configuration, delegate: streamOutput)
                
                // Add a stream output to capture screen content.
                try stream?.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: videoSampleBufferQueue)
                try stream?.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: audioSampleBufferQueue)
                stream?.startCapture()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
    
    func stopCapture() async {
        do {
            try await stream?.stopCapture()
            continuation?.finish()
        } catch {
            continuation?.finish(throwing: error)
        }
        powerMeter.processSilence()
    }
    
    /// - Tag: UpdateStreamConfiguration
    func update(configuration: SCStreamConfiguration, filter: SCContentFilter) async {
        do {
            try await stream?.updateConfiguration(configuration)
            try await stream?.updateContentFilter(filter)
        } catch {
            logger.error("Failed to update the stream session: \(String(describing: error))")
        }
    }
}

/// A class that handles output from an SCStream, and handles stream errors.
private class CaptureEngineStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    
    var pcmBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    var capturedFrameHandler: ((CapturedFrame) -> Void)?
    
    var windSpeed = WindSpeed()
    // Store the the startCapture continuation, so you can cancel it if an error occurs.
    private var continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation?
    
    init(continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation?) {
        self.continuation = continuation
    }
    
    /// - Tag: DidOutputSampleBuffer
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        
        // Return early if the sample buffer is invalid.
        guard sampleBuffer.isValid else { return }
        
        // Determine which type of data the sample buffer contains.
        switch outputType {
        case .screen:
            // Create a CapturedFrame structure for a video sample buffer.
            guard let frame = createFrame(for: sampleBuffer) else { return }
            
            capturedFrameHandler?(frame)
        case .audio:
            // Create an AVAudioPCMBuffer from an audio sample buffer.
            guard let samples = createPCMBuffer(for: sampleBuffer) else { return }
            pcmBufferHandler?(samples)
        @unknown default:
            fatalError("Encountered unknown stream output type: \(outputType)")
        }
    }
    
    /// Create a `CapturedFrame` for the video sample buffer.
    private func createFrame(for sampleBuffer: CMSampleBuffer) -> CapturedFrame? {
        
        // Retrieve the array of metadata attachments from the sample buffer.
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                             createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first else { return nil }
        
        // Validate the status of the frame. If it isn't `.complete`, return nil.
        guard let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue),
              status == .complete else { return nil }
        
        // Get the pixel buffer that contains the image data.
        guard let buff  = sampleBuffer.imageBuffer else { return nil}
        guard let timageBuffer : CVPixelBuffer = CIImage(cvImageBuffer: buff)
            .pixelBuffer else { return nil }
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(timageBuffer, options: nil, imageOut: &cgImage)
        guard let resimage : CGImage = cgImage?.cropping(to: CGRect(x:500, y: 280, width: 90, height: 140)) else { return nil}
        guard let afterPointmage : CGImage = cgImage?.cropping(to: CGRect(x:720, y: 280, width: 90, height: 140)) else { return nil}
        // two range
//        guard let secondDigitImage : CGImage = cgImage?.cropping(to: CGRect(x:330, y: 280, width: 290, height: 140)) else { return nil}
        guard let secondDigitImage : CGImage = cgImage?.cropping(to: CGRect(x:330, y: 280, width: 130, height: 140)) else { return nil}
        let convImage = timageBuffer as CVPixelBuffer
        let pixelBuffer : CVImageBuffer = convImage
        let handler = VNImageRequestHandler(cgImage: resimage)
        let afterPointHandler = VNImageRequestHandler(cgImage: afterPointmage)
        let secondDigitHandler = VNImageRequestHandler(cgImage: secondDigitImage)
        var firstDigit : String = ""
        let firstDigitRequest = VNRecognizeTextRequest { (request, error) in
            if let results = request.results as? [VNRecognizedTextObservation] {
                firstDigit = results.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }.first ?? ""
                self.windSpeed.firstDigit = firstDigit
            }
        }
        
        firstDigitRequest.recognitionLevel = .accurate
        let afterPoingDigitRequest = VNRecognizeTextRequest { (request, error) in
            if let results = request.results as? [VNRecognizedTextObservation] {
                self.windSpeed.subZeroFirstDigit = results.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }.first ?? ""
                
            }
        }
        do {
            
        }
        let secondDigitRequest = VNRecognizeTextRequest { (request, error) in
            if let error = error {
                self.windSpeed.secondDigit = "0"
            }
            if let results = request.results as? [VNRecognizedTextObservation] {
                if results.count == 0 {
                    self.windSpeed.secondDigit = "0"
                } else {
                    self.windSpeed.secondDigit = results.first?.topCandidates(1).first?.string ?? ""
                }
                    
            }
        }
        secondDigitRequest.recognitionLevel = .accurate
        afterPoingDigitRequest.recognitionLevel = .accurate
        afterPoingDigitRequest.recognitionLanguages = ["ja-JP"]
        DispatchQueue.global(qos: .userInteractive).async {
            do {
                try handler.perform([firstDigitRequest])
                try afterPointHandler.perform([afterPoingDigitRequest])
                try secondDigitHandler.perform([secondDigitRequest])
            } catch {
            }
        }
        
        
        // Get the backing IOSurface.
        guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return nil }
        
        let surface = unsafeBitCast(surfaceRef, to: IOSurface.self)
        
        // Retrieve the content rectangle, scale, and scale factor.
        guard let contentRectDict = attachments[.contentRect],
              let contentRect = CGRect(dictionaryRepresentation: contentRectDict as! CFDictionary),
              let contentScale = attachments[.contentScale] as? CGFloat,
              let scaleFactor = attachments[.scaleFactor] as? CGFloat else { return nil }
        // Create a new frame with the relevant data.
        let frame = CapturedFrame(surface: surface,
                                  contentRect: contentRect,
                                  contentScale: contentScale,
                                  scaleFactor: scaleFactor)
        
        
        print(windSpeed.showSpeed())
        getItemInfoTapped(windSpeed.showSpeed())
        return frame
    }
    
    
    func getItemInfoTapped(_ speedString: String) {

        let url = URL(string: "https://mysite-906r.onrender.com/wind_speed_hayamas/1.json")!

        let data: [String: Any] = ["wind_speed_hayama": ["speed_string" : speedString]]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: data, options: []) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue( //3
            "Bearer",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = httpBody

        URLSession.shared.dataTask(with: request) {(data, response, error) in

            if let error = error {
                print("Failed to get item info: \(error)")
                return;
            }

            guard let data = data else { return }
            do {
                let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] 
            } catch let error {
                print(error)
            }

        }.resume()
    }
    
    // Creates an AVAudioPCMBuffer instance on which to perform an average and peak audio level calculation.
    private func createPCMBuffer(for sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        var ablPointer: UnsafePointer<AudioBufferList>?
        try? sampleBuffer.withAudioBufferList { audioBufferList, blockBuffer in
            ablPointer = audioBufferList.unsafePointer
        }
        guard let audioBufferList = ablPointer,
              let absd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(standardFormatWithSampleRate: absd.mSampleRate, channels: absd.mChannelsPerFrame) else { return nil }
        return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList)
    }
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        continuation?.finish(throwing: error)
    }
    

}

struct WindSpeed{
    var firstDigit: String = "0"
    var subZeroFirstDigit: String = "0"
    var secondDigit: String = "0"
    func showSpeed() -> String{
        secondDigit + firstDigit + "." + subZeroFirstDigit
    }
}
