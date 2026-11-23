// Smidgen — Lane 3 Capture
// apps/ios/Features/Ingest/IngestStepsHeader.swift
//
// Shared Add → Review → Save progress header for the Clip, Captions, and
// OCR ingest views. One definition keeps layout, styling, and VoiceOver
// behavior consistent across all three flows.

import SwiftUI

public struct IngestStepsHeader: View {
    public var current: Int
    private let steps = ["Add", "Review", "Save"]

    public init(current: Int) {
        self.current = current
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(steps.indices, id: \.self) { i in
                VStack(spacing: 4) {
                    Circle()
                        .fill(i <= current ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 22, height: 22)
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
                        .padding(.horizontal, 6)
                        .padding(.bottom, 16)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(current + 1) of 3: \(steps[current])")
    }
}
