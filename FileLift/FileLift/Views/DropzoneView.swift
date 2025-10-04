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
  var body: some View {
    content
  }

  @ViewBuilder
  var content: some View {
    BackgroundView()
      .onDrop(of: [.fileURL], isTargeted: nil) { providers, _ in
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

            print("Dropped file name: \(url.lastPathComponent)")
          }
        }
        return true
      }
  }
}

// MARK: - Preview
#Preview {
  DropzoneView()
}
