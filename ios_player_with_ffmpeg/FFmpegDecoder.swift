//
//  FFmpegDecoder.swift
//  ios_player_with_ffmpeg
//
//  Created by liebentwei on 2026/1/20.
//

import Foundation
import UIKit
import Accelerate

class FFmpegDecoder {
    
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var swsContext: OpaquePointer?
    private var videoStreamIndex: Int32 = -1
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var rgbFrame: UnsafeMutablePointer<AVFrame>?
    private var rgbBuffer: UnsafeMutablePointer<UInt8>?
    
    var width: Int32 = 0
    var height: Int32 = 0
    var duration: Double = 0
    var fps: Double = 0
    
    private var isInitialized = false
    
    private var frameQueue: [UIImage] = []
    private let maxQueueSize: Int
    private var decodeThread: Thread?
    private var isDecoding = false
    private var isEndOfFile = false
    
    private let queueCondition = NSCondition()
    
    /// - Parameter cacheSize: 30 frames
    init(cacheSize: Int = 30) {
        self.maxQueueSize = cacheSize
        packet = av_packet_alloc()
        frame = av_frame_alloc()
        rgbFrame = av_frame_alloc()
    }
    
    deinit {
        stopDecoding()
        cleanup()
    }
    
    func openVideo(url: String) -> Bool {
        // Stop decoding before
        stopDecoding()
        cleanup()
        
        // Empty the frame queue
        queueCondition.lock()
        frameQueue.removeAll()
        isEndOfFile = false
        queueCondition.unlock()
        
        // Re-allocate frames after cleanup
        packet = av_packet_alloc()
        frame = av_frame_alloc()
        rgbFrame = av_frame_alloc()
        
        // Initialize FFmpeg network
        avformat_network_init()
        
        // Allocate format context
        var formatCtx: UnsafeMutablePointer<AVFormatContext>?
        
        guard avformat_open_input(&formatCtx, url, nil, nil) == 0,
              let formatContext = formatCtx else {
            print("Failed to open video file: \(url)")
            return false
        }
        
        self.formatContext = formatContext
        
        // Retrieve stream information
        guard avformat_find_stream_info(formatContext, nil) >= 0 else {
            print("Failed to find stream information")
            return false
        }
        
        // Find video stream
        videoStreamIndex = -1
        for i in 0..<Int32(formatContext.pointee.nb_streams) {
            let stream = formatContext.pointee.streams[Int(i)]!
            if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                videoStreamIndex = i
                break
            }
        }
        
        guard videoStreamIndex >= 0 else {
            print("Failed to find video stream")
            return false
        }
        
        // Get codec parameters
        let stream = formatContext.pointee.streams[Int(videoStreamIndex)]!
        guard let codecParameters = stream.pointee.codecpar else {
            print("Failed to get codec parameters")
            return false
        }
        
        // Find decoder
        guard let codec = avcodec_find_decoder(codecParameters.pointee.codec_id) else {
            print("Failed to find codec")
            return false
        }
        
        // Allocate codec context
        guard let codecCtx = avcodec_alloc_context3(codec) else {
            print("Failed to allocate codec context")
            return false
        }
        
        self.codecContext = codecCtx
        
        // Copy codec parameters to context
        guard avcodec_parameters_to_context(codecCtx, codecParameters) >= 0 else {
            print("Failed to copy codec parameters")
            return false
        }
        
        // Open codec
        guard avcodec_open2(codecCtx, codec, nil) >= 0 else {
            print("Failed to open codec")
            return false
        }
        
        // Store video information
        width = codecCtx.pointee.width
        height = codecCtx.pointee.height
        
        // Calculate duration
        let noPtsValue = Int64.min
        if stream.pointee.duration != noPtsValue {
            let timeBase = stream.pointee.time_base
            duration = Double(stream.pointee.duration) * Double(timeBase.num) / Double(timeBase.den)
        } else if formatContext.pointee.duration != noPtsValue {
            duration = Double(formatContext.pointee.duration) / Double(AV_TIME_BASE)
        }
        
        // Calculate FPS
        let frameRate = stream.pointee.avg_frame_rate
        if frameRate.den > 0 {
            fps = Double(frameRate.num) / Double(frameRate.den)
        }
        
        // Initialize sws context for color conversion - use BGRA format，iOS support
        swsContext = sws_getContext(
            width, height, codecCtx.pointee.pix_fmt,
            width, height, AV_PIX_FMT_BGRA,
            SWS_FAST_BILINEAR, nil, nil, nil
        )
        
        guard swsContext != nil else {
            print("Failed to initialize sws context")
            return false
        }
        
        // Allocate RGB frame buffer - use BGRA
        guard let rgbFrame = rgbFrame else {
            print("Failed to allocate RGB frame")
            return false
        }
        
        let numBytes = av_image_get_buffer_size(AV_PIX_FMT_BGRA, width, height, 32)
        guard numBytes > 0 else {
            print("Failed to calculate buffer size")
            return false
        }
        
        guard let buffer = av_malloc(Int(numBytes)) else {
            print("Failed to allocate RGB buffer")
            return false
        }
        
        rgbBuffer = buffer.assumingMemoryBound(to: UInt8.self)
        
        let ret = av_image_fill_arrays(
            &rgbFrame.pointee.data.0,
            &rgbFrame.pointee.linesize.0,
            rgbBuffer,
            AV_PIX_FMT_BGRA,
            width, height, 32
        )
        
        guard ret >= 0 else {
            print("Failed to fill image arrays, error: \(ret)")
            av_free(buffer)
            rgbBuffer = nil
            return false
        }
        
        isInitialized = true
        print("Video opened successfully: \(width)x\(height), duration: \(duration)s, fps: \(fps)")
        
        startDecoding()
        
        return true
    }
    
    private func startDecoding() {
        guard isInitialized else { return }
        
        isDecoding = true
        decodeThread = Thread { [weak self] in
            self?.decodeLoop()
        }
        decodeThread?.name = "FFmpegDecoderThread"
        decodeThread?.qualityOfService = .userInitiated
        decodeThread?.start()
    }
    
    private func stopDecoding() {
        queueCondition.lock()
        isDecoding = false
        queueCondition.broadcast()
        queueCondition.unlock()
        
        decodeThread?.cancel()
        decodeThread = nil
    }
    
    private func decodeLoop() {
        while !Thread.current.isCancelled {
            queueCondition.lock()
            
            if !isDecoding {
                queueCondition.unlock()
                break
            }
            
            while frameQueue.count >= maxQueueSize && isDecoding {
                queueCondition.wait()
            }
            
            if !isDecoding {
                queueCondition.unlock()
                break
            }
            
            queueCondition.unlock()
            
            if let image = decodeNextFrame() {
                queueCondition.lock()
                frameQueue.append(image)
                queueCondition.signal()
                queueCondition.unlock()
            } else {
                queueCondition.lock()
                isEndOfFile = true
                queueCondition.broadcast()
                queueCondition.unlock()
                break
            }
        }
    }
    
    private func decodeNextFrame() -> UIImage? {
        guard isInitialized,
              let formatContext = formatContext,
              let codecContext = codecContext,
              let packet = packet,
              let frame = frame,
              let rgbFrame = rgbFrame,
              let swsContext = swsContext else {
            return nil
        }
        
        while av_read_frame(formatContext, packet) >= 0 {
            defer { av_packet_unref(packet) }
            
            if packet.pointee.stream_index == videoStreamIndex {
                let sendResult = avcodec_send_packet(codecContext, packet)
                if sendResult < 0 {
                    continue
                }
                
                let receiveResult = avcodec_receive_frame(codecContext, frame)
                if receiveResult == 0 {
                    // Convert to BGRA
                    withUnsafePointer(to: &frame.pointee.data) { srcData in
                        withUnsafePointer(to: &frame.pointee.linesize) { srcLinesize in
                            withUnsafePointer(to: &rgbFrame.pointee.data) { dstData in
                                withUnsafePointer(to: &rgbFrame.pointee.linesize) { dstLinesize in
                                    let srcDataPtr = UnsafePointer<UnsafePointer<UInt8>?>(OpaquePointer(srcData))
                                    let srcLinesizePtr = UnsafePointer<Int32>(OpaquePointer(srcLinesize))
                                    let dstDataPtr = UnsafePointer<UnsafeMutablePointer<UInt8>?>(OpaquePointer(dstData))
                                    let dstLinesizePtr = UnsafePointer<Int32>(OpaquePointer(dstLinesize))
                                    
                                    sws_scale(
                                        swsContext,
                                        srcDataPtr,
                                        srcLinesizePtr,
                                        0, height,
                                        dstDataPtr,
                                        dstLinesizePtr
                                    )
                                }
                            }
                        }
                    }
                    
                    return convertFrameToUIImage(rgbFrame: rgbFrame)
                }
            }
        }
        
        return nil
    }
    
    func readFrame(blocking: Bool = true) -> UIImage? {
        queueCondition.lock()
        defer { queueCondition.unlock() }
        
        if blocking {
            while frameQueue.isEmpty && !isEndOfFile && isDecoding {
                queueCondition.wait()
            }
        }
        
        if !frameQueue.isEmpty {
            let image = frameQueue.removeFirst()
            queueCondition.signal()
            return image
        }
        
        return nil
    }
    
    var cachedFrameCount: Int {
        queueCondition.lock()
        defer { queueCondition.unlock() }
        return frameQueue.count
    }
    
    var hasReachedEnd: Bool {
        queueCondition.lock()
        defer { queueCondition.unlock() }
        return isEndOfFile && frameQueue.isEmpty
    }
    
    func seekToTime(_ time: Double) -> Bool {
        guard isInitialized,
              let formatContext = formatContext,
              let codecContext = codecContext else {
            return false
        }
        
        let wasDecoding = isDecoding
        stopDecoding()
        
        queueCondition.lock()
        frameQueue.removeAll()
        isEndOfFile = false
        queueCondition.unlock()
        
        let stream = formatContext.pointee.streams[Int(videoStreamIndex)]!
        let timeBase = stream.pointee.time_base
        let timestamp = Int64(time * Double(timeBase.den) / Double(timeBase.num))
        
        let seekResult = av_seek_frame(formatContext, videoStreamIndex, timestamp, AVSEEK_FLAG_BACKWARD)
        
        if seekResult >= 0 {
            avcodec_flush_buffers(codecContext)
        }
        
        if wasDecoding {
            startDecoding()
        }
        
        return seekResult >= 0
    }
    
    private func convertFrameToUIImage(rgbFrame: UnsafeMutablePointer<AVFrame>) -> UIImage? {
        let width = Int(self.width)
        let height = Int(self.height)
        let bytesPerRow = Int(rgbFrame.pointee.linesize.0)
        
        guard let data = rgbFrame.pointee.data.0 else {
            print("convertFrameToUIImage: data is nil")
            return nil
        }
        
        // 使用 CGContext 直接绘制，这是最可靠的方式
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        // 创建位图上下文
        guard let context = CGContext(
            data: nil,  // 让系统分配内存
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,  // 让系统计算
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            print("Failed to create CGContext")
            return nil
        }
        
        // 获取 context 的数据指针并复制数据
        guard let contextData = context.data else {
            print("Failed to get context data")
            return nil
        }
        
        let contextBytesPerRow = context.bytesPerRow
        let srcPtr = data
        let dstPtr = contextData.assumingMemoryBound(to: UInt8.self)
        
        // 逐行复制，处理可能的行对齐差异
        for row in 0..<height {
            let srcRow = srcPtr + row * bytesPerRow
            let dstRow = dstPtr + row * contextBytesPerRow
            memcpy(dstRow, srcRow, min(bytesPerRow, contextBytesPerRow))
        }
        
        // 从 context 创建 CGImage
        guard let cgImage = context.makeImage() else {
            print("Failed to make CGImage")
            return nil
        }
        
        return UIImage(cgImage: cgImage)
    }
    
    private func cleanup() {
        isInitialized = false
        
        if let swsContext = swsContext {
            sws_freeContext(swsContext)
            self.swsContext = nil
        }
        
        if let rgbBuffer = rgbBuffer {
            av_free(rgbBuffer)
            self.rgbBuffer = nil
        }
        
        if codecContext != nil {
            avcodec_free_context(&self.codecContext)
        }
        
        if formatContext != nil {
            avformat_close_input(&self.formatContext)
        }
        
        if frame != nil {
            av_frame_free(&self.frame)
        }
        
        if rgbFrame != nil {
            av_frame_free(&self.rgbFrame)
        }
        
        if packet != nil {
            av_packet_free(&self.packet)
        }
    }
}
