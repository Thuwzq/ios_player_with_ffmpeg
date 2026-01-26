//
//  ContentView.swift
//  ios_player_with_ffmpeg
//
//  Created by liebentwei on 2026/1/16.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = VideoPlayerViewModel()
    @State private var videoURL = ""
    @State private var showControls = true
    
    // Some example video URLs for testing
    private let exampleURLs = [
        "killer.mp4",
        "pilot.flv",
        "tquic://106.52.100.46:8443/pilot.flv?use_wifi=1",
        "tquic://106.52.100.46:8443/pilot.flv?use_wifi=0",
    ]
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Video display area
                ZStack {
                    Color.black
                    
                    if viewModel.isLoading {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                    } else if let errorMessage = viewModel.errorMessage {
                        VStack(spacing: 16) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 50))
                                .foregroundColor(.red)
                            
                            Text(errorMessage)
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                    } else if let frame = viewModel.currentFrame {
                        Image(uiImage: frame)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .onTapGesture {
                                withAnimation {
                                    showControls.toggle()
                                }
                            }
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "play.rectangle")
                                .font(.system(size: 50))
                                .foregroundColor(.gray)
                            
                            Text("Enter a video URL to start playing")
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                    }
                    
                    // Controls overlay
                    if showControls && viewModel.currentFrame != nil {
                        VStack {
                            Spacer()
                            VideoPlayerControlsView(viewModel: viewModel)
                        }
                        .transition(.move(edge: .bottom))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: geometry.size.height * 0.5)
                
                // URL input area
                VStack(spacing: 16) {
                    Text("FFmpeg Video Player")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    // URL input
                    HStack {
                        TextField("Enter video URL", text: $videoURL)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        
                        Button("Load") {
                            if !videoURL.isEmpty {
                                loadVideo(filename: videoURL)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(videoURL.isEmpty || viewModel.isLoading)
                    }
                    
                    // Example URLs
                    Text("Example videos:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(exampleURLs, id: \.self) { filename in
                                Button(action: {
                                    videoURL = filename
                                    loadVideo(filename: filename)
                                }) {
                                    Text(filename)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color.blue.opacity(0.1))
                                        .cornerRadius(8)
                                }
                                .disabled(viewModel.isLoading)
                            }
                        }
                    }
                    
                    Spacer()
                }
                .padding()
            }
        }
        .edgesIgnoringSafeArea(.top)
    }
    
    /// 加载本地或网络视频
    private func loadVideo(filename: String) {
        // 如果是网络 URL，直接使用
        if filename.hasPrefix("http://") || filename.hasPrefix("https://") || filename.hasPrefix("tquic://") {
            viewModel.openVideo(url: filename)
            return
        }
        
        // 本地文件：从 Bundle 获取路径
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        
        // 如果使用 "Create folder references" 添加了 videos 文件夹
        if let path = Bundle.main.path(forResource: "videos/\(name)", ofType: ext) {
            viewModel.openVideo(url: path)
        }
        // 如果视频文件直接在 Bundle 根目录
        else if let path = Bundle.main.path(forResource: name, ofType: ext) {
            viewModel.openVideo(url: path)
        }
        else {
            viewModel.errorMessage = "File not found: \(filename)"
        }
    }
}

#Preview {
    ContentView()
}
