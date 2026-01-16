//
//  VideoPlayerControlsView.swift
//  ios_player_with_ffmpeg
//
//  Created by liebentwei on 2026/1/20.
//

import SwiftUI

struct VideoPlayerControlsView: View {
    @ObservedObject var viewModel: VideoPlayerViewModel
    
    var body: some View {
        VStack(spacing: 20) {
            // Progress slider
            VStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { viewModel.currentTime },
                        set: { viewModel.seek(to: $0) }
                    ),
                    in: 0...max(viewModel.duration, 1)
                )
                
                HStack {
                    Text(formatTime(viewModel.currentTime))
                        .font(.caption)
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Text(formatTime(viewModel.duration))
                        .font(.caption)
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal)
            
            // Play/Pause button
            HStack(spacing: 40) {
                Button(action: {
                    viewModel.seek(to: max(0, viewModel.currentTime - 10))
                }) {
                    Image(systemName: "gobackward.10")
                        .font(.title)
                        .foregroundColor(.white)
                }
                
                Button(action: {
                    if viewModel.isPlaying {
                        viewModel.pause()
                    } else {
                        viewModel.play()
                    }
                }) {
                    Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.white)
                }
                
                Button(action: {
                    viewModel.seek(to: min(viewModel.duration, viewModel.currentTime + 10))
                }) {
                    Image(systemName: "goforward.10")
                        .font(.title)
                        .foregroundColor(.white)
                }
            }
        }
        .padding()
        .background(
            LinearGradient(
                gradient: Gradient(colors: [.clear, .black.opacity(0.7)]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
