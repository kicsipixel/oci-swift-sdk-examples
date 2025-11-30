//
//  ListView.swift
//  BucketView
//
//  Created by Szabolcs Tóth on 30.11.2025.
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

struct ListView: View {
  @Environment(\.dataViewModel) private var vm: DataViewModelProtocol
  @Binding var selectedID: ObjectNode.ID?
  @Binding var treeObjects: [ObjectNode]

  var body: some View {
    GroupBox(label: Label("Objects", image: ("ObjectIcon")).bold()) {
      List(selection: $selectedID) {
        OutlineGroup(treeObjects, children: \.children) { node in
          HStack {
            Image(node.size == nil ? "FolderIcon" : "FileIcon")
              .resizable()
              .frame(width: 23, height: 23)
            Text(node.name)
          }
          .tag(node.id)
        }
        .padding(6)
      }
      .listStyle(.inset)
    }
  }
}

// MARK: - Preview
#Preview {
  ListView(selectedID: .constant(nil), treeObjects: .constant([]))
}
