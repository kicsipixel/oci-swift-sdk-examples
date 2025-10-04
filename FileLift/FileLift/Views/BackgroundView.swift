//
//  Background.swift
//  FileLift
//
//  Created by Szabolcs Tóth on 04.10.2025.
//  Copyright © 2025 Szabolcs Tóth. All rights reserved.
//

import SwiftUI

struct BackgroundView: View {
  var body: some View {
    content
  }

  @ViewBuilder
  var content: some View {
    RoundedRectangle(cornerRadius: 16)
      .fill(Color.accent.opacity(0.1))
      .frame(width: 340, height: 200)
      .overlay(
        RoundedRectangle(cornerRadius: 16)
          .stroke(style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
          .foregroundColor(.accent)
      )
  }
}

// MARK: - Preview
#Preview {
    BackgroundView()
}
