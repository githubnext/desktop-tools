//
//  WatchCaptureHUDView.swift
//  Peekaboo
//

import SwiftUI

struct WatchCaptureHUDView: View {
    enum Constants {
        static let timelineSegments = 5
    }

    let sequence: Int
    @State private var pulse = false

    private var activeSegment: Int {
        self.sequence % Constants.timelineSegments
    }

    var body: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(VisualizerTheme.accent)
                .frame(width: 14, height: 14)
                .shadow(color: VisualizerTheme.accent.opacity(0.8), radius: 6)
                .scaleEffect(self.pulse ? 1.25 : 0.85)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: self.pulse)

            VStack(alignment: .leading, spacing: 6) {
                Text("Change-aware capture running")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(VisualizerTheme.hudText)
                Text("Timeline lights up whenever frames are kept")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(VisualizerTheme.hudTextSecondary)

                WatchTimelineView(activeIndex: self.activeSegment, totalSegments: Constants.timelineSegments)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("watch")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VisualizerTheme.hudTextSecondary)
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(.white)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(width: 340, height: 70)
        .hudChip(cornerRadius: 16)
        .onAppear {
            self.pulse = true
        }
    }
}

private struct WatchTimelineView: View {
    let activeIndex: Int
    let totalSegments: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<self.totalSegments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(self.segmentColor(for: index))
                    .frame(width: 36, height: 5)
                    .animation(.easeInOut(duration: 0.3), value: self.activeIndex)
            }
        }
    }

    private func segmentColor(for index: Int) -> Color {
        if index == self.activeIndex {
            return VisualizerTheme.accent
        }
        if index == (self.activeIndex - 1 + self.totalSegments) % self.totalSegments {
            return VisualizerTheme.accent.opacity(0.4)
        }
        return Color.white.opacity(0.22)
    }
}

#if DEBUG && !SWIFT_PACKAGE
#Preview("Watch HUD") {
    WatchCaptureHUDView(sequence: 0)
        .padding()
        .background(Color.gray.opacity(0.4))
}
#endif
