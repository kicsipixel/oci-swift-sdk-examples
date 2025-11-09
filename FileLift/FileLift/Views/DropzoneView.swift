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
  @Environment(DataViewModel.self) private var vm
  @State private var isDropActive = false
  @State private var dropzoneWidth: CGFloat = 340
  @State private var dropzoneHeight: CGFloat = 200
  @State private var pendingUploadPaths: [String] = []
  @State private var showingConfirmation = false

  var body: some View {
    content
      .alert("Confirmation", isPresented: $showingConfirmation) {
        Button("OK", role: .destructive) {
          Task {
            for path in pendingUploadPaths {
              try? await vm.putObject(filePath: path)
            }
            pendingUploadPaths.removeAll()
          }
        }
        Button("Cancel", role: .cancel) {
          pendingUploadPaths.removeAll()
        }
      } message: {
        Text(
          pendingUploadPaths.count == 1
            ? "Do you want to upload\n \(pendingUploadPaths.first ?? "")?"
            : """
            Do you want to upload these \(pendingUploadPaths.count) files:
            \(pendingUploadPaths.map { $0.split(separator: "/").last ?? "" }.joined(separator: "\n"))
            """
        )
      }
  }

  @ViewBuilder
  var content: some View {
    BackgroundView(width: dropzoneWidth, height: dropzoneHeight)
      .animation(.easeInOut(duration: 0.2), value: dropzoneHeight)
      .onDrop(of: [.fileURL], isTargeted: $isDropActive) { providers, _ in
        var collectedPaths: [String] = []
        let group = DispatchGroup()

        for provider in providers {
          group.enter()
          _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            defer { group.leave() }

            guard let data,
              let url = URL(dataRepresentation: data, relativeTo: nil),
              url.isFileURL
            else { return }

            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            guard !isDirectory.boolValue else {
              print("Folders are not allowed: \(url.lastPathComponent)")
              return
            }

            collectedPaths.append(url.path)
          }
        }

        group.notify(queue: .main) {
          let confirmationIsNeeded = !UserDefaults.standard.bool(forKey: "autoUpload")

          if confirmationIsNeeded {
            pendingUploadPaths = collectedPaths
            showingConfirmation = true
          }
          else {
            Task {
              for path in collectedPaths {
                try? await vm.putObject(filePath: path)
              }
            }
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
