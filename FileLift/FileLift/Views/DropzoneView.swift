//
//  DropzoneView.swift
//  FileLift
//
//  Created by Szabolcs Tóth on 03.10.2025.
//
//  This file is part of FileLift and is licensed under the MIT License.
//  Copyright © 2025 Szabolcs Tóth.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

import SwiftUI
import UniformTypeIdentifiers

struct DropzoneView: View {
  // Private properties
  @Environment(DataViewModel.self) private var vm
  @State private var isDropActive = false
  @State private var dropzoneWidth: CGFloat = 340
  @State private var dropzoneHeight: CGFloat = 200

  // Properties
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
