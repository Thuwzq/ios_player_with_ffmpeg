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
    
    init() {
        packet = av_packet_alloc()
        frame = av_frame_alloc()
        rgbFrame = av_frame_alloc()
    }
    
    deinit {
        cleanup()
    }
    
    func openVideo(url: String) -> Bool {
        cleanup()
        
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
        
        // Initialize sws context for color conversion (use SWS_FAST_BILINEAR for better performance)
        swsContext = sws_getContext(
            width, height, codecCtx.pointee.pix_fmt,
            width, height, AV_PIX_FMT_RGB24,
            SWS_FAST_BILINEAR, nil, nil, nil
        )
        
        guard swsContext != nil else {
            print("Failed to initialize sws context")
            return false
        }
        
        // Allocate RGB frame buffer
        guard let rgbFrame = rgbFrame else {
            print("Failed to allocate RGB frame")
            return false
        }
        
        let numBytes = av_image_get_buffer_size(AV_PIX_FMT_RGB24, width, height, 32)
        guard numBytes > 0 else {
            print("Failed to calculate buffer size")
            return false
        }
        
        // Use av_malloc to allocate aligned buffer
        guard let buffer = av_malloc(Int(numBytes)) else {
            print("Failed to allocate RGB buffer")
            return false
        }
        
        rgbBuffer = buffer.assumingMemoryBound(to: UInt8.self)
        
        // Fill the RGB frame arrays
        let ret = av_image_fill_arrays(
            &rgbFrame.pointee.data.0,
            &rgbFrame.pointee.linesize.0,
            rgbBuffer,
            AV_PIX_FMT_RGB24,
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
        return true
    }
    
    func readFrame() -> UIImage? {
        guard isInitialized,
              let formatContext = formatContext,
              let codecContext = codecContext,
              let packet = packet,
              let frame = frame,
              let rgbFrame = rgbFrame,
              let swsContext = swsContext else {
            print("readFrame: decoder not properly initialized")
            return nil
        }
        
        while av_read_frame(formatContext, packet) >= 0 {
            defer { av_packet_unref(packet) }
            
            // Check if packet is from video stream
            if packet.pointee.stream_index == videoStreamIndex {
                // Send packet to decoder
                let sendResult = avcodec_send_packet(codecContext, packet)
                if sendResult < 0 {
                    continue
                }
                
                // Receive decoded frame
                let receiveResult = avcodec_receive_frame(codecContext, frame)
                if receiveResult == 0 {
                    // Convert to RGB
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
                    
                    // Convert to UIImage
                    return convertFrameToUIImage(rgbFrame: rgbFrame)
                }
            }
        }
        
        return nil
    }
    
    func seekToTime(_ time: Double) -> Bool {
        guard isInitialized,
              let formatContext = formatContext,
              let codecContext = codecContext else {
            return false
        }
        
        let stream = formatContext.pointee.streams[Int(videoStreamIndex)]!
        let timeBase = stream.pointee.time_base
        let timestamp = Int64(time * Double(timeBase.den) / Double(timeBase.num))
        
        if av_seek_frame(formatContext, videoStreamIndex, timestamp, AVSEEK_FLAG_BACKWARD) < 0 {
            return false
        }
        
        avcodec_flush_buffers(codecContext)
        return true
    }
    
    private func convertFrameToUIImage(rgbFrame: UnsafeMutablePointer<AVFrame>) -> UIImage? {
        let width = Int(self.width)
        let height = Int(self.height)
        let linesize = Int(rgbFrame.pointee.linesize.0)
        
        guard let data = rgbFrame.pointee.data.0 else {
            print("convertFrameToUIImage: data is nil")
            return nil
        }
        
        // Create CGImage from RGB data
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        
        // Copy data to ensure it's valid during image creation
        let dataSize = linesize * height
        let dataCopy = UnsafeMutablePointer<UInt8>.allocate(capacity: dataSize)
        dataCopy.initialize(from: data, count: dataSize)
        
        let cfData = CFDataCreateWithBytesNoCopy(
            kCFAllocatorDefault,
            dataCopy,
            dataSize,
            kCFAllocatorDefault
        )
        
        guard let cfData = cfData,
              let provider = CGDataProvider(data: cfData) else {
            dataCopy.deallocate()
            return nil
        }
        
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: linesize,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
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
