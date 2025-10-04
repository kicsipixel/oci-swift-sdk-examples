//
//  DropzoneView.swift
//  FileLift
//
//  Created by Szabolcs Tóth on 04.10.2025.
//  Copyright © 2025 Szabolcs Tóth. All rights reserved.
//

import SwiftUI
import UniformTypeIdentifiers

struct DropzoneView: View {
    @Environment(DataViewModel.self) private var vm
  @State private var isDropActive = false
  @State private var dropzoneWidth: CGFloat = 340
  @State private var dropzoneHeight: CGFloat = 200

  var body: some View {
    content
  }

  @ViewBuilder
  var content: some View {
    BackgroundView(width: dropzoneWidth, height: dropzoneHeight)
      .animation(.easeInOut(duration: 0.2), value: dropzoneHeight)
      .onDrop(of: [.fileURL], isTargeted: $isDropActive) { providers, _ in
        for provider in providers {
          _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL
            else { return }

            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            // Handle error message if folder is dropped
            guard !isDirectory.boolValue else {
              print("Folders are not allowed: \(url.lastPathComponent)")
              return
            }
              Task {
                  try await vm.putObject(filePath: url.path)
              }
            print("Dropped file name: \(url.lastPathComponent)")
          }
        }
        return true
      }
      .onChange(of: isDropActive) { _, newValue in
        let scale: CGFloat = 1.1
        dropzoneHeight = newValue ? 200 * scale : 200
        dropzoneWidth = newValue ? 340 * scale : 340
      }
  }
}

// MARK: - Preview
#Preview {
  DropzoneView()
        .environment(DataViewModel.preview)
}
