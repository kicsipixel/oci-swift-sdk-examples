//
//  InspectorView.swift
//  BucketView
//
//  Created by Szabolcs Tóth on 05.10.2025.
//  Copyright © 2025 Szabolcs Tóth
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

import OCIKit
import SwiftUI

struct InspectorView: View {
  let node: ObjectNode?

  var body: some View {
    VStack(spacing: 20) {
      Spacer()
      if let node {
        Image(node.size != nil ? "FileIcon" : "FolderIcon")
          .resizable()
          .frame(width: 60, height: 60)

        Text("\(node.name)")
          .bold()
          .font(.title2)

          List {
            Text("Name: ").bold() + Text(node.name)
            Text("Size: ").bold() + Text(node.size ?? "")
            Text("Created: ").bold() + Text(node.createdAt ?? "")

            if UserDefaults.standard.bool(forKey: "etag") {
              Text("ETag: ").bold() + Text(node.etag ?? "")
            }

            if UserDefaults.standard.bool(forKey: "md5") {
              Text("MD5: ").bold() + Text(node.md5 ?? "")
            }

            if UserDefaults.standard.bool(forKey: "storagetier") {
              Text("Storage Tier: ").bold() + Text(node.storagetier?.rawValue ?? "")
            }

            if UserDefaults.standard.bool(forKey: "archivalstate") {
              Text("Archival State: ").bold() + Text(node.archivalstate?.rawValue ?? "")
            }
          }
          .listStyle(.bordered)

        .padding(.top, 4)
      }
      else {
        Text("No selection")
          .foregroundColor(.secondary)
      }

      Spacer()
    }
    .padding(.horizontal, 20)
  }
}

// MARK: - Preview
#Preview {
  InspectorView(node: ObjectNode(id: UUID(), name: "TestFile.md", size: "1999", createdAt: "\(Date.now)"))
}
