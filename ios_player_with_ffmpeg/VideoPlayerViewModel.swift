//
//  VideoPlayerViewModel.swift
//  ios_player_with_ffmpeg
//
//  Created by liebentwei on 2026/1/20.
//

import Foundation
import SwiftUI
import Combine

struct StutterEvent {
    let startTime: Double      // Stuttering start time
    let duration: Double       // Stuttering duration(ms)
}

@MainActor
class VideoPlayerViewModel: ObservableObject {
    @Published var currentFrame: UIImage?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    // First frame load time(ms)
    @Published var firstFrameLoadTime: Double?
    
    // Stutter statistics
    @Published var totalStutterTime: Double = 0      // Summary stuttering duration
    @Published var stutterCount: Int = 0             // Summary stuttering count
    @Published var stutterEvents: [StutterEvent] = [] // All stuttering events
    
    private var decoder: FFmpegDecoder?
    private var playbackTask: Task<Void, Never>?
    private var playbackStartTime: CFAbsoluteTime = 0
    private var playbackStartPts: Double = 0
    
    // Record loading start time
    private var loadStartTime: CFAbsoluteTime = 0
    
    // Flag to prevent printing summary multiple times
    private var hasPrintedSummary = false
    
    func openVideo(url: String) {
        isLoading = true
        errorMessage = nil
        firstFrameLoadTime = nil
        hasPrintedSummary = false

        pause()

        loadStartTime = CFAbsoluteTimeGetCurrent()
        totalStutterTime = 0
        stutterCount = 0
        stutterEvents.removeAll()
        
        let decoder = FFmpegDecoder()
        
        Task {
            let success = await Task.detached {
                decoder.openVideo(url: url)
            }.value
            
            if success {
                self.decoder = decoder
                self.duration = decoder.duration
                self.currentTime = 0
                
                print("📹 Video opened: duration = \(String(format: "%.2f", decoder.duration)) s, fps = \(String(format: "%.2f", decoder.fps))")
                
                // Read first frame
                if let firstFrame = await Task.detached(operation: {
                    decoder.readVideoFrame()
                }).value {
                    self.currentFrame = firstFrame.image
                    self.currentTime = firstFrame.pts
                    
                    // Calculate and get first frame load time
                    let firstFrameTime = (CFAbsoluteTimeGetCurrent() - self.loadStartTime) * 1000
                    self.firstFrameLoadTime = firstFrameTime
                    print("📊 First frame load time: \(String(format: "%.2f", firstFrameTime)) ms")
                }
                
                self.isLoading = false
                self.play()
            } else {
                self.errorMessage = "Failed to open video"
                self.isLoading = false
            }
        }
    }
    
    func play() {
        guard !isPlaying, decoder != nil else { return }
        
        isPlaying = true
        playbackStartTime = CFAbsoluteTimeGetCurrent()
        playbackStartPts = currentTime
        
        startPlayback()
    }
    
    func pause() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
    }
    
    func seek(to time: Double) {
        pause()
        
        guard let decoder = decoder else { return }
        
        Task {
            let success = await Task.detached {
                decoder.seekToTime(time)
            }.value
            
            if success {
                // Read frame at new position
                if let videoFrame = await Task.detached(operation: {
                    decoder.readVideoFrame()
                }).value {
                    self.currentFrame = videoFrame.image
                    self.currentTime = videoFrame.pts
                } else {
                    self.currentTime = time
                }
            }
        }
    }
    
    private func startPlayback() {
        playbackTask = Task {
            guard let decoder = decoder else { return }
            
            while !Task.isCancelled && isPlaying {
                
                // 先尝试非阻塞获取
                var videoFrame = await Task.detached(operation: {
                    decoder.readVideoFrame(blocking: false)
                }).value
                
                // 如果没有获取到帧，开始记录卡顿
                if videoFrame == nil {
                    let stutterStartTime = CFAbsoluteTimeGetCurrent()
                    let videoTimeAtStutter = currentTime
                    
                    // 阻塞等待帧
                    videoFrame = await Task.detached(operation: {
                        decoder.readVideoFrame(blocking: true)
                    }).value
                    
                    // 计算卡顿时长
                    if videoFrame != nil {
                        let stutterDuration = (CFAbsoluteTimeGetCurrent() - stutterStartTime) * 1000
                        
                        // 只有卡顿超过一定阈值才记录（避免记录正常的帧间隔）
                        if stutterDuration > 16.7 {
                            let event = StutterEvent(startTime: videoTimeAtStutter, duration: stutterDuration)
                            stutterEvents.append(event)
                            stutterCount += 1
                            totalStutterTime += stutterDuration
                            
                            print("🔴 Stutter #\(stutterCount): duration = \(String(format: "%.2f", stutterDuration)) ms, at video time = \(String(format: "%.2f", videoTimeAtStutter)) s")
                        }
                    }
                }
                
                // 如果还是没有帧，说明视频结束
                guard let frame = videoFrame else {
                    print("📍 End of video: no more frames available")
                    onPlaybackFinished()
                    break
                }
                
                // 计算当前应该显示的时间点
                let elapsedTime = CFAbsoluteTimeGetCurrent() - playbackStartTime
                let targetTime = playbackStartPts + elapsedTime
                
                // If pts is greater than target time, wait
                let framePts = frame.pts
                if framePts > targetTime {
                    let waitTime = framePts - targetTime
                    if waitTime > 0 && waitTime < 1.0 {
                        try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
                    }
                }
                // If pts is less than target time too much(100ms), skip the frame
                else if targetTime - framePts > 0.1 {
                    continue
                }
                
                if Task.isCancelled || !isPlaying {
                    break
                }
                
                currentFrame = frame.image
                currentTime = framePts
                
                let isNearEnd = duration > 0 && currentTime >= duration - 0.5
                let hasReachedEnd = decoder.hasReachedEnd
                
                if isNearEnd || hasReachedEnd {
                    print("📍 End of video: currentTime = \(String(format: "%.2f", currentTime)) s, duration = \(String(format: "%.2f", duration)) s, hasReachedEnd = \(hasReachedEnd)")
                    onPlaybackFinished()
                    break
                }
            }
        }
    }
    
    /// 播放结束时的处理
    private func onPlaybackFinished() {
        if !hasPrintedSummary {
            hasPrintedSummary = true
            printPlaybackSummary()
        }
        isPlaying = false
        currentTime = 0
        seek(to: 0)
    }
    
    /// 打印播放统计摘要
    private func printPlaybackSummary() {
        print("═══════════════════════════════════════════")
        print("📊 Playback Summary")
        print("───────────────────────────────────────────")
        if let firstFrameTime = firstFrameLoadTime {
            print("   First frame load time: \(String(format: "%.2f", firstFrameTime)) ms")
        }
        print("   Video duration: \(String(format: "%.2f", duration)) s")
        print("   Total stutter count: \(stutterCount)")
        print("   Total stutter time: \(String(format: "%.2f", totalStutterTime)) ms")
        if stutterCount > 0 {
            let avgStutter = totalStutterTime / Double(stutterCount)
            print("   Average stutter duration: \(String(format: "%.2f", avgStutter)) ms")
            let stutterRatio = totalStutterTime / (duration * 1000) * 100
            print("   Stutter ratio: \(String(format: "%.2f", stutterRatio))%")
        }
        print("═══════════════════════════════════════════")
    }
    
    deinit {
        playbackTask?.cancel()
    }
}

