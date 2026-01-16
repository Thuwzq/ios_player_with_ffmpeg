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
    
    private var decoder: FFmpegDecoder?
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    private var frameInterval: CFTimeInterval = 0
    
    private var playbackTask: Task<Void, Never>?
    
    func openVideo(url: String) {
        isLoading = true
        errorMessage = nil
        
        let decoder = FFmpegDecoder()
        
        Task {
            let success = await Task.detached {
                decoder.openVideo(url: url)
            }.value
            
            if success {
                self.decoder = decoder
                self.duration = decoder.duration
                self.frameInterval = decoder.fps > 0 ? 1.0 / decoder.fps : 1.0 / 30.0
                
                // Read first frame
                let firstFrame: UIImage? = await Task.detached {
                    return decoder.readFrame()
                }.value
                
                if let firstFrame = firstFrame {
                    self.currentFrame = firstFrame
                }
                
                self.isLoading = false
            } else {
                self.errorMessage = "Failed to open video"
                self.isLoading = false
            }
        }
    }
    
    func play() {
        guard !isPlaying, decoder != nil else { return }
        
        isPlaying = true
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
                self.currentTime = time
                
                // Read frame at new position
                let frame: UIImage? = await Task.detached {
                    return decoder.readFrame()
                }.value
                
                if let frame = frame {
                    self.currentFrame = frame
                }
            }
        }
    }
    
    private func startPlayback() {
        playbackTask = Task {
            while !Task.isCancelled && isPlaying {
                if let frame = await readNextFrame() {
                    currentFrame = frame
                    currentTime += frameInterval
                    
                    if currentTime >= duration {
                        isPlaying = false
                        currentTime = 0
                        seek(to: 0)
                        break
                    }
                } else {
                    // End of video
                    isPlaying = false
                    currentTime = 0
                    seek(to: 0)
                    break
                }
                
                // Sleep for frame interval
                try? await Task.sleep(nanoseconds: UInt64(frameInterval * 1_000_000_000))
            }
        }
    }
    
    private func readNextFrame() async -> UIImage? {
        guard let decoder = decoder else { return nil }
        
        return await Task.detached {
            return decoder.readFrame()
        }.value
    }
    
    deinit {
        playbackTask?.cancel()
    }
}
