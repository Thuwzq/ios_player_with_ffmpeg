//
//  VideoPlayerViewModel.swift
//  ios_player_with_ffmpeg
//
//  Created by liebentwei on 2026/1/20.
//

import Foundation
import SwiftUI
import Combine

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
    
    private var decoder: FFmpegDecoder?
    private var playbackTask: Task<Void, Never>?
    private var playbackStartTime: CFAbsoluteTime = 0
    private var playbackStartPts: Double = 0
    
    // Record loading start time
    private var loadStartTime: CFAbsoluteTime = 0
    
    func openVideo(url: String) {
        isLoading = true
        errorMessage = nil
        firstFrameLoadTime = nil
        
        pause()

        loadStartTime = CFAbsoluteTimeGetCurrent()
        
        let decoder = FFmpegDecoder()
        
        Task {
            let success = await Task.detached {
                decoder.openVideo(url: url)
            }.value
            
            if success {
                self.decoder = decoder
                self.duration = decoder.duration
                self.currentTime = 0
                
                // Read first frame
                if let firstFrame = await Task.detached(operation: {
                    decoder.readVideoFrame()
                }).value {
                    self.currentFrame = firstFrame.image
                    self.currentTime = firstFrame.pts
                    
                    // Calculate and get first frame load time
                    let firstFrameTime = (CFAbsoluteTimeGetCurrent() - self.loadStartTime) * 1000
                    self.firstFrameLoadTime = firstFrameTime
                    print("First frame load time: \(String(format: "%.2f", firstFrameTime)) ms")
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

                guard let videoFrame = await Task.detached(operation: {
                    decoder.readVideoFrame(blocking: true)
                }).value else {
                    // End of video
                    await MainActor.run {
                        self.isPlaying = false
                        self.currentTime = 0
                    }
                    self.seek(to: 0)
                    break
                }
                
                // 计算当前应该显示的时间点
                let elapsedTime = CFAbsoluteTimeGetCurrent() - playbackStartTime
                let targetTime = playbackStartPts + elapsedTime
                
                // If pts is greater than target time, wait
                let framePts = videoFrame.pts
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
                
                currentFrame = videoFrame.image
                currentTime = framePts
                
                if currentTime >= duration - 0.1 {
                    isPlaying = false
                    currentTime = 0
                    seek(to: 0)
                    break
                }
            }
        }
    }
    
    deinit {
        playbackTask?.cancel()
    }
}
