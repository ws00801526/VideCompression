//
//  VideoCompression.swift
//  VideoCompression
//
//  Created by Fraker.XM on 2021/3/2.
//

import Foundation
import AVFoundation

public class VideoCompression {
    
    fileprivate static let miniVideoBitrate = 500 * 1024
    fileprivate static let preferredTimeScale = CMTimeScale(600)
    fileprivate static let compressQueue = DispatchQueue(label: "VideoCompress.Queue")
    
    /// Compress H264 Video.
    /// - Parameters:
    ///   - videoURL:       The video file url.
    ///   - destinationURL: The url which compressed video will be placed. It's will be placed in ~/temp/xxx.extension if the value is nil.
    ///   - fileType:       The output file type. Default is .mp4.
    ///   - cache:          The cache mode. Default is .none.
    ///   - preferred:      The preferred compress configuration. Default is .i720p
    ///   - profile:        The compress video format profile. Default is .highAutoLevel
    ///   - transform:      The video transform will be applied. Default is .keep
    ///   - processor:      The video sample buffer processor, rewrite the buffer if you need. Default is nil
    ///   - progress:       The video compress progress, !!!  it will be called on background queue
    ///   - completion:     The completion. called after compress finished or some error happened.
    ///
    /// - Important: progress & completion called on background queue.
    ///
    /// - Returns: An Cancallabled instance, you can cancel the compress process if you want.
    @discardableResult
    static func compressh264Video(from videoURL: URL,
                                  to destinationURL: URL? = nil,
                                  fileType: AVFileType = .mp4,
                                  cache: Cache = .none,
                                  preferred: Preferred = .i720p,
                                  profile: Profile = .highAutoLevel,
                                  transform: Transform = .keep,
                                  processor: VideoCompressionProcessor? = nil,
                                  progress: ((Progress) -> Void)? = nil,
                                  completion: @escaping ((URL?, Error?) -> Void)) -> Cancellable {
        return compressh264Video(from: AVURLAsset(url: videoURL),
                                 to: destinationURL,
                                 fileType: fileType,
                                 cache: cache,
                                 preferred: preferred,
                                 profile: profile,
                                 transform: transform,
                                 processor: processor,
                                 progress: progress,
                                 completion: completion)
    }
    
    /// Compress H264 Video.
    /// - Parameters:
    ///   - asset:          The video file asset.
    ///   - destinationURL: The url which compressed video will be placed. It's will be placed in ~/temp/xxx.extension if the value is nil.
    ///   - fileType:       The output file type. Default is .mp4.
    ///   - cache:          The cache mode. Default is .none.
    ///   - preferred:      The preferred compress configuration. Default is .i720p
    ///   - profile:        The compress video format profile. Default is .highAutoLevel
    ///   - transform:      The video transform will be applied. Default is .keep
    ///   - processor:      The video sample buffer processor, rewrite the buffer if you need. Default is nil
    ///   - progress:       The video compress progress, !!!  it will be called on background queue
    ///   - completion:     The completion. called after compress finished or some error happened.
    ///
    /// - Important: progress & completion called on background queue.
    ///
    /// - Returns: An Cancallabled instance, you can cancel the compress process if you want.
    @discardableResult
    static func compressh264Video(from asset: AVAsset,
                                  to destinationURL: URL? = nil,
                                  fileType: AVFileType = .mp4,
                                  cache: Cache = .none,
                                  preferred: Preferred = .i720p,
                                  profile: Profile = .highAutoLevel,
                                  transform: Transform = .keep,
                                  processor: VideoCompressionProcessor? = nil,
                                  progress: ((Progress) -> Void)? = nil,
                                  completion: @escaping ((URL?, Error?) -> Void)) -> Cancellable {
        
        func randomDestintationURL() -> URL {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            guard let asset = asset as? AVURLAsset else {
                let name = "\(UUID.init().uuidString)_\(preferred.resolution.width)x\(preferred.resolution.height)_\(profile.rawValue)"
                return dir.appendingPathComponent(name).appendingPathExtension(fileType.extension)
            }
            let name = "\(asset.url.absoluteString.SHA256)_\(preferred.resolution.width)x\(preferred.resolution.height)_\(profile.rawValue)"
            return dir.appendingPathComponent(name).appendingPathExtension(fileType.extension)
        }
        
        guard [AVFileType.mp4, .mov].contains(fileType) else {
            completion(nil, VideoCompressionError(message: "Filetype should only be one of [.mp4, .mov]"))
            return Cancellable(isCancelled: true)
        }
        
        // Create OutputURL and check if it's exists
        let outputuRL = destinationURL ?? randomDestintationURL()
        if FileManager.default.fileExists(atPath: outputuRL.absoluteString) {
            switch cache {
            case .none:
                completion(nil, VideoCompressionError(message: "File exists at outputURL: \(outputuRL)"))
                return Cancellable(isCancelled: true)
            case .useCache:
                completion(outputuRL, nil)
                return Cancellable(isCancelled: true)
            case .forceDelete:
                guard let _ = try? FileManager.default.removeItem(at: outputuRL) else {
                    completion(nil, VideoCompressionError(message: "File exists at outputURL: \(outputuRL)"))
                    return Cancellable(isCancelled: true)
                }
            }
        }
        
        do {
            // Reader and Writer
            let writer = try AVAssetWriter(outputURL: outputuRL, fileType: fileType)
            let reader = try AVAssetReader(asset: asset)
            
            // Tracks
            let videoTrack = asset.tracks(withMediaType: AVMediaType.video).first!
            let audioTrack = asset.tracks(withMediaType: AVMediaType.audio).first!
            
            // Calculate correct size
            let origin: CGSize = videoTrack.naturalSize
            var resolution = preferred.resolution
            if case .quantity = preferred { resolution = origin }
            else { resolution = origin.aspect(to: origin.isPortrait ? resolution.reversed() : resolution) }
            
            // Video Input Configuration
            var videoCompressionProps: [String : Any] = [
                AVVideoAverageBitRateKey : preferred.videoBitrate,
                AVVideoMaxKeyFrameIntervalKey : preferred.frameRate,
                AVVideoProfileLevelKey : profile.rawValue
            ]
            if case .quantity(let ratio) = preferred {
                // Get the origin bitrate.  kb/s
                let bitrate = Double(videoTrack.estimatedDataRate) / 1000
                assert(ratio <= 1.0 && ratio > 0.0, "ratio should be in range (0.0, 1.0]")
                videoCompressionProps[AVVideoAverageBitRateKey] = max(Int((bitrate * ratio).rounded()), miniVideoBitrate)
            }
            var videoInputSettings: [String : Any] = [
                AVVideoWidthKey : resolution.width,
                AVVideoHeightKey : resolution.height,
                AVVideoCompressionPropertiesKey : videoCompressionProps
            ]
            if #available(iOS 11.0, *) { videoInputSettings[AVVideoCodecKey] = AVVideoCodecType.h264 }
            else { videoInputSettings[AVVideoCodecKey] = AVVideoCodecH264 }
            
            let videoInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: videoInputSettings)
            videoInput.expectsMediaDataInRealTime = false
            videoInput.performsMultiPassEncodingIfSupported = true
            videoInput.transform = transform == .keep ? videoTrack.preferredTransform : transform.value
            
            // Add VideoInput Into Writer
            guard writer.canAdd(videoInput) else {
                completion(nil, VideoCompressionError(message: "Cannot add video input"))
                return Cancellable(isCancelled: true)
            }
            writer.add(videoInput)
            
            // Audio Output Configuration
            var acl = AudioChannelLayout()
            acl.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            acl.mChannelBitmap = AudioChannelBitmap(rawValue: UInt32(0))
            acl.mNumberChannelDescriptions = UInt32(0)
            
            let acll = MemoryLayout<AudioChannelLayout>.size
            let audioOutputSettings: [String : Any] = [
                AVFormatIDKey : UInt(kAudioFormatMPEG4AAC),
                AVNumberOfChannelsKey : UInt(2),
                AVSampleRateKey : 22050,
                AVEncoderBitRateKey : preferred.audioBitrate,
                AVChannelLayoutKey : NSData(bytes:&acl, length: acll)
            ]
            let audioInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: audioOutputSettings)
            audioInput.expectsMediaDataInRealTime = false
            
            guard writer.canAdd(audioInput) else {
                completion(nil, VideoCompressionError(message: "Cannot add audio input"))
                return Cancellable(isCancelled: true)
            }
            writer.add(audioInput)
            
            // Video Output Configuration
            let videoOutputSettings: [String : Any] = [
                kCVPixelBufferPixelFormatTypeKey as String : UInt(kCVPixelFormatType_422YpCbCr8_yuvs),
                kCVPixelBufferIOSurfacePropertiesKey as String : [:]
            ]
            let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoOutputSettings)
            videoOutput.alwaysCopiesSampleData = false
            
            /// Add VideoOutput Into Reader
            guard reader.canAdd(videoOutput) else {
                completion(nil, VideoCompressionError(message: "Cannot add video output"))
                return Cancellable(isCancelled: true)
            }
            reader.add(videoOutput)
            
            // Audio Output Configuration
            let decompressionAudioSettings: Dictionary<String, Any> = [
                AVFormatIDKey: UInt(kAudioFormatLinearPCM)
            ]
            let readerAudioTrackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: decompressionAudioSettings)
            
            readerAudioTrackOutput.alwaysCopiesSampleData = false
            
            guard reader.canAdd(readerAudioTrackOutput) else {
                completion(nil, VideoCompressionError(message: "Cannot add audio output"))
                return Cancellable(isCancelled: true)
            }
            reader.add(readerAudioTrackOutput)
            
            // Begin Compression
            reader.timeRange = .init(start: .zero, end: asset.duration)
            writer.shouldOptimizeForNetworkUse = true
            reader.startReading()
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            
            // Compress in Background
            let cancelable = Cancellable()
            let duration = asset.duration.convertScale(VideoCompression.preferredTimeScale, method: .default)
            let progressObject = Progress(totalUnitCount: duration.value * Int64(duration.timescale))
            compressQueue.async {
                
                var videoDone = false
                var audioDone = false
                
                while !videoDone || !audioDone {
                    // Check for Writer Errors (out of storage etc.)
                    if writer.status == .failed {
                        reader.cancelReading()
                        writer.cancelWriting()
                        if let e = writer.error { return completion(nil, e) }
                    }
                    
                    // Check for Reader Errors (source file corruption etc.)
                    if reader.status == .failed {
                        reader.cancelReading()
                        writer.cancelWriting()
                        if let e = reader.error { return completion(nil, e) }
                    }
                    
                    // Check for Cancel
                    if cancelable.isCancelled {
                        reader.cancelReading()
                        writer.cancelWriting()
                        return completion(nil, nil)
                    }
                    
                    // Check if enough data is ready for encoding a single frame
                    if videoInput.isReadyForMoreMediaData {
                        // Copy a single frame from source to destination with applied transforms
                        if let vBuffer = videoOutput.copyNextSampleBuffer(), CMSampleBufferDataIsReady(vBuffer) {
                            _ = videoInput.append(processor?.process(buffer: vBuffer, of: .video) ?? vBuffer)
                            let presentationTime = CMSampleBufferGetPresentationTimeStamp(vBuffer)
                                .convertScale(preferredTimeScale, method: .default)
                            progressObject.completedUnitCount = presentationTime.value * Int64(presentationTime.timescale)
                            if let progress = progress { progress(progressObject) }
                        } else {
                            // Video source is depleted, mark as finished
                            if !videoDone { videoInput.markAsFinished() }
                            videoDone = true
                        }
                    }
                    
                    if audioInput.isReadyForMoreMediaData {
                        // Copy a single audio sample from source to destination
                        if let aBuffer = readerAudioTrackOutput.copyNextSampleBuffer(), CMSampleBufferDataIsReady(aBuffer) {
                            _ = audioInput.append(processor?.process(buffer: aBuffer, of: .audio) ?? aBuffer)
                        } else {
                            // Audio source is depleted, mark as finished
                            if !audioDone {
                                audioInput.markAsFinished()
                            }
                            audioDone = true
                        }
                    }
                }
                
                // Write everything to output file
                writer.finishWriting {
                    progressObject.completedUnitCount = progressObject.totalUnitCount
                    if let progress = progress { progress(progressObject) }
                    completion(outputuRL, nil)
                }
            }
            
            // Return a cancel wrapper for users to let them interrupt the compression
            return cancelable
        } catch {
            // Error During Reader or Writer Creation
            completion(nil, error)
            return Cancellable(isCancelled: true)
        }
    }
}

protocol VideoCompressionProcessor {
    func process(buffer: CMSampleBuffer, of type: AVMediaType) -> CMSampleBuffer
}

public extension VideoCompression {
    
    typealias Resolution = CGSize
    
    enum Preferred {
        /// Recommend Compresion. Resolution (1920 x 1080) bitrate(4992~>7552kb/s) frameRate(30fps)
        case i1080p
        /// Recommend Compresion. Resolution (1920 x 1080) bitrate(2496~>2496 kb/s) frameRate(30fps)
        case i720p
        /// Recommend Compresion. Resolution (1920 x 1080) bitrate(1856~>2176 kb/s) frameRate(30fps)
        case i576
        /// Recommend Compresion. Resolution (1920 x 1080) bitrate(1216~>1536 kb/s) frameRate(30fps)
        case i480
        /// Recommend Compresion. Resolution (480 x 360) bitrate(896 kb/s) frameRate(30 fps)
        case i360
        /// Recommend Compresion. Resolution unchanged bitrate( origin * ratio ). The ratio should be 0...1.
        case quantity(ratio: Double)
        /// Custom Compresion.
        case custom((resulution: Resolution, videoBitrate: Int, frameRate: Int, audioBitrate: Int))
    }
    
    enum Profile {
        
        case high40
        case high41
        case highAutoLevel
        
        case main30
        case main31
        case main32
        case main41
        case mainAutoLevel
        
        case baseline30
        case baseline31
        case baseline41
        case baselineAutoLevel
    }
    
    enum Transform {
        case keep
        case fixBackCamera
        case fixFrontCamera
        case custom(CGAffineTransform)
    }
    
    enum Cache {
        case none
        case useCache
        case forceDelete
    }
    
    class Cancellable {
        fileprivate var isCancelled: Bool = false
        
        convenience init(isCancelled: Bool) {
            self.init()
            self.isCancelled = isCancelled
        }
        
        func cancell() { isCancelled = true }
    }
    
    
    // Compression Error Messages
    struct VideoCompressionError: LocalizedError {
        var message: String
        init(message: String = "Compression Error") {
            self.message = message
        }
        
        public var failureReason: String? { message }
        public var errorDescription: String? { "VideCompression: \(message)" }
    }
}

extension VideoCompression.Profile {
    
    public var rawValue: String {
        switch self {
        case .baseline30: return AVVideoProfileLevelH264Baseline30
        case .baseline31: return AVVideoProfileLevelH264Baseline31
        case .baseline41: return AVVideoProfileLevelH264Baseline41
        case .baselineAutoLevel: return AVVideoProfileLevelH264BaselineAutoLevel
            
        case .main30: return AVVideoProfileLevelH264Main30
        case .main31: return AVVideoProfileLevelH264Main31
        case .main32: return AVVideoProfileLevelH264Main32
        case .main41: return AVVideoProfileLevelH264Main41
        case .mainAutoLevel: return AVVideoProfileLevelH264MainAutoLevel
            
        case .high40: return AVVideoProfileLevelH264High40
        case .high41: return AVVideoProfileLevelH264High41
        case .highAutoLevel: return AVVideoProfileLevelH264HighAutoLevel
        }
    }
    
    public typealias RawValue = String
    public init(rawValue: String) {
        switch rawValue {
        case AVVideoProfileLevelH264High40: self = .high40
        case AVVideoProfileLevelH264High41: self = .high41
        case AVVideoProfileLevelH264HighAutoLevel: self = .highAutoLevel
            
        case AVVideoProfileLevelH264Main30: self = .main30
        case AVVideoProfileLevelH264Main31: self = .main31
        case AVVideoProfileLevelH264Main32: self = .main32
        case AVVideoProfileLevelH264Main41:  self = .main41
        case AVVideoProfileLevelH264MainAutoLevel: self = .mainAutoLevel
            
        case AVVideoProfileLevelH264Baseline30: self = .baseline30
        case AVVideoProfileLevelH264Baseline31: self = .baseline31
        case AVVideoProfileLevelH264Baseline41: self = .baseline41
        case AVVideoProfileLevelH264BaselineAutoLevel: self = .baselineAutoLevel
            
        default: self = .highAutoLevel
        }
    }
}

extension VideoCompression.Preferred: Equatable {
    
    public static func == (lhs: VideoCompression.Preferred, rhs: VideoCompression.Preferred) -> Bool {
        guard lhs.resolution != rhs.resolution else { return false }
        guard lhs.videoBitrate != rhs.videoBitrate else { return false }
        guard lhs.audioBitrate != rhs.audioBitrate else { return false }
        guard lhs.frameRate != rhs.frameRate else { return false }
        return true
    }
    
    var resolution: VideoCompression.Resolution  {
        switch self {
        case .i1080p: return .init(width: 1920, height: 1080)
        case .i720p: return .init(width: 1280, height: 720)
        case .i576: return .init(width: 1024, height: 576)
        case .i480: return .init(width: 960, height: 480)
        case .i360: return .init(width: 640, height: 360)
        case .custom(let video): return video.resulution
            
        // Unused value.
        case .quantity(let ratio):
            return .init(width: Double(1920) * ratio, height: Double(1080) * ratio)
        }
    }
    
    var videoBitrate: Int {
        switch self {
        case .i1080p: return 4992 * 1024
        case .i720p: return 2496 * 1024
        case .i576: return 1856 * 1024
        case .i480: return 1216 * 1024
        case .i360: return 896 * 1024
        case .custom(let video): return video.videoBitrate
        // Unused value.
        case .quantity(let ratio): return Int(Double(4992 * 1024) * ratio)
        }
    }
    
    var audioBitrate: Int {
        switch self {
        case .i1080p: return 128 * 1024
        case .i720p: return 64 * 1024
        case .i576: return 64 * 1024
        case .i480: return 64 * 1024
        case .i360: return 64 * 1024
        case .custom(let video): return video.audioBitrate
        case .quantity: return 64 * 1024
        }
    }
    
    var frameRate: Int {
        if case .custom(let video) = self { return video.frameRate }
        return 30
    }
}

extension VideoCompression.Transform: Equatable {
    var value: CGAffineTransform {
        switch self {
        case .fixBackCamera:
            return CGAffineTransform(rotationAngle: 270.degreesToRadiansCGFloat)
        case .fixFrontCamera:
            return CGAffineTransform(rotationAngle: 90.degreesToRadiansCGFloat).scaledBy(x:-1.0, y:1.0)
        case .keep:
            return CGAffineTransform.identity
        case .custom(let transform): return transform
        }
    }
}

// Filetype Extension Conversion Utility
fileprivate extension AVFileType {
    var `extension`: String {
        switch self {
        case .mp4: return "mp4"
        case .mov: return "mov"
        case .jpg: return "jpg"
        case .mp3: return "mp3"
        default: return ""
        }
    }
}

// Angle Conversion Utility
fileprivate extension Int {
    var degreesToRadiansCGFloat: CGFloat { return CGFloat(Double(self) * Double.pi / 180) }
}

// Size Conversion Utility
fileprivate extension CGSize {
    
    var isPortrait: Bool { width < height }
    
    func reversed() -> CGSize { .init(width: height, height: width) }
    
    func aspect(to target: CGSize) -> CGSize {
        
        if target.width <= 0 || target.height <= 0 { return self }
        let wratio = width / target.width, hratio = height / target.height
        
        switch (wratio, hratio) {
        
        // Fit Height
        case (let w, let h) where w <= 1.0 && h > 1.0: fallthrough
        case (let w, let h) where w > 1.0 && h > 1.0 && w < h:
            return .init(width: width / hratio, height: target.height)
            
        // Fit Width
        case (let w, let h) where w > 1.0 && h <= 1.0: fallthrough
        case (let w, let h) where w > 1.0 && h > 1.0 && w > h:
            return .init(width: target.width, height: height / wratio)
            
        // Just return current video size.
        default: return self
        }
    }
}

import CommonCrypto
fileprivate extension String {
    var SHA256: String {
        let utf8 = cString(using: .utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256(utf8, CC_LONG(utf8!.count - 1), &digest)
        return digest.reduce("") { $0 + String(format:"%02X", $1) }
    }
}
