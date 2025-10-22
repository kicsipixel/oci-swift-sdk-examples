//
//  Mainscreen.swift
//  BucketView
//
//  Created by Szabolcs Tóth on 17.10.2025.
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

// MARK: - Object Model for Tree
struct ObjectNode: Identifiable, Hashable {
  let id: ObjectSummary.ID
  let name: String
  let size: String?
  let createdAt: String?
  var children: [ObjectNode]?

  init(id: ObjectSummary.ID, name: String, size: String? = nil, createdAt: String? = nil, children: [ObjectNode]? = nil) {
    self.id = id
    self.name = name
    self.size = size
    self.createdAt = createdAt
    self.children = children
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  static func == (lhs: ObjectNode, rhs: ObjectNode) -> Bool {
    lhs.id == rhs.id
  }
}

struct Mainscreen: View {
  // Private Properties
  @Environment(DataViewModel.self) private var vm
  @State private var isInspectorShown: Bool = false
  @State private var selectedBucket: String? = nil
  @State private var treeObjects: [ObjectNode] = []
  @State private var selectedID: ObjectSummary.ID?

  private var selectedNode: ObjectNode? {
    findNode(in: treeObjects, matching: selectedID)
  }

  // MARK: - Date Formatter
  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "dd MMM yyyy, HH:mm"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()

  // Properties
  var body: some View {
    NavigationSplitView {
      SidebarView(selectedBucket: $selectedBucket)
    } detail: {
      ZStack {
        VStack {
            List(selection: $selectedID) {
                OutlineGroup(treeObjects, children: \.children) { node in
                    HStack {
                        Image(node.size?.isEmpty == nil ? "FolderIcon" : "FileIcon")
                            .resizable()
                            .frame(width: 30, height: 30)
                        
                        Text(node.name)
                    }
                    .tag(node.id)
                }
            }
            .listStyle(.inset)
          .inspector(isPresented: $isInspectorShown) {
            InspectorView(node: selectedNode)
          }
        }
        .frame(minWidth: 500)
      }
      .task {
        try? await vm.getNamespace()
        try? await vm.listBuckets()
          treeObjects = buildTree(from: vm.objects)
      }
      .onChange(of: selectedBucket) { _, newValue in
        guard let bucketName = newValue else { return }
        Task {
          try await vm.listObjects(bucketName: bucketName)
            treeObjects = buildTree(from: vm.objects)
        }
      }
      .toolbar {
        ToolbarItemGroup(placement: .automatic) {
          Button(action: { isInspectorShown.toggle() }) {
            Label("Toggle Inspector", systemImage: "sidebar.right")
          }
        }
      }
    }
  }

  // MARK: - Build hierarchical tree from flat paths
  func buildTree(from rawObjects: [ObjectSummary]) -> [ObjectNode] {
    var root: [String: ObjectNode] = [:]

    for obj in rawObjects {
      let components = obj.name.split(separator: "/").map(String.init)
      let sizeString = obj.size.map { "\($0) bytes" }
      let createdString = obj.timeCreated.map { Self.dateFormatter.string(from: $0) }
      insertNode(into: &root, components: components, id: obj.id, size: sizeString, createdAt: createdString)
    }

    return Array(root.values).sorted(by: { $0.name < $1.name })
  }

  // Recursive insertion
  private func insertNode(
    into dict: inout [String: ObjectNode],
    components: [String],
    id: ObjectSummary.ID,
    size: String?,
    createdAt: String?
  ) {
    guard let first = components.first else { return }

    if components.count == 1 {
      dict[first] = ObjectNode(id: id, name: first, size: size, createdAt: createdAt, children: nil)
    }
    else {
      if dict[first] == nil {
        dict[first] = ObjectNode(id: ObjectSummary.ID(), name: first, children: [])
      }

      var childDict: [String: ObjectNode] = [:]
      if let children = dict[first]?.children {
        for child in children {
          childDict[child.name] = child
        }
      }

      insertNode(into: &childDict, components: Array(components.dropFirst()), id: id, size: size, createdAt: createdAt)
      dict[first]?.children = Array(childDict.values).sorted(by: { $0.name < $1.name })
    }
  }

  func findNode(in nodes: [ObjectNode], matching id: ObjectSummary.ID?) -> ObjectNode? {
    guard let id else { return nil }
    for node in nodes {
      if node.id == id {
        return node
      }
      if let child = findNode(in: node.children ?? [], matching: id) {
        return child
      }
    }
    return nil
  }
}

// MARK: - Preview
#Preview("Light Mode") {
    Mainscreen()
        .environment(DataViewModel.preview)
}

#Preview("Dark Mode") {
    Mainscreen()
        .environment(DataViewModel.preview)
        .preferredColorScheme(.dark)
}

