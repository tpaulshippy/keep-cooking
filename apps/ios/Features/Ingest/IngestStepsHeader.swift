// Smidgen — Lane 3 Capture
// apps/ios/Features/Ingest/IngestStepsHeader.swift
//
// Shared Add → Review → Save progress header for the Clip, Captions, and
// OCR ingest views. One definition keeps layout, styling, and VoiceOver
// behavior consistent across all three flows.

import SwiftUI

public struct IngestStepsHeader: View {
    /// Bounded to `steps.indices`; out-of-range values clamp so the
    /// subscripted visuals and accessibility label can never trap.
    public private(set) var current: Int
    private let steps = ["Add", "Review", "Save"]
    /// Circle diameter; the step connector matches this height so it stays
    /// centered on the circles at any Dynamic Type size.
    private let circleSize: CGFloat = 22

    public init(current: Int) {
        self.current = max(0, min(current, steps.count - 1))
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(steps.indices, id: \.self) { i in
                VStack(spacing: 4) {
                    Circle()
                        .fill(i <= current ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: circleSize, height: circleSize)
                        .overlay(
                            Text("\(i + 1)")
                                .font(.caption2.bold())
                                .foregroundStyle(i <= current ? .white : .secondary)
                        )
                    Text(steps[i])
                        .font(.caption2)
                        .foregroundStyle(i == current ? .primary : .secondary)
                }
                if i < steps.count - 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: 1)
                        .frame(height: circleSize)
                        .padding(.horizontal, 6)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(current + 1) of 3: \(steps[current])")
    }
}
