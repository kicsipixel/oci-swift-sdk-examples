//
//  Mainscreen.swift
//  BucketView
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

// MARK: - Main Screen
struct Mainscreen2: View {
  @State private var showInspector: Bool = true
  @Environment(DataViewModel.self) private var vm
  @State private var showingAlert: Bool = false
  @AppStorage("compartmentId") private var compartmentId: String = ""
  @State private var errorMessage: String = ""
  @State private var treeObjects: [ObjectNode] = []
  @State private var selectedID: ObjectSummary.ID?
    @State private var selection: String? = nil

  var selectedNode: ObjectNode? {
    findNode(in: treeObjects, matching: selectedID)
  }

  // MARK: - Date Formatter
  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "dd MMM yyyy, HH:mm"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()

  var body: some View {
    VStack {
      Picker("Select a bucket:", selection: $selection) {
        ForEach(vm.buckets, id: \.name) { bucket in
          Text(bucket.name).tag(Optional(bucket.name))
        }
      }
      .padding()
      .onChange(of: selection) { _, newValue in
        // Handle optional selection
        guard let bucketName = newValue else { return }

        Task {
          do {
            try await vm.listObjects(bucketName: bucketName)
            treeObjects = buildTree(from: vm.objects)
          }
          catch {
            errorMessage = error.localizedDescription
            showingAlert = true
          }
        }
      }

        ZStack {
            Text(vm.buckets.isEmpty ? "No buckets were found." :"The bucket is empty.")
            
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
            .frame(minHeight: 300)
            .opacity(vm.objects.isEmpty ? 0 : 1)
        }
    }
    .padding()
    .inspector(isPresented: $showInspector) {
      InspectorView(node: selectedNode)
    }
    .task {
      do {
        try await vm.getNamespace()
        try await vm.listBuckets()
          if let first = vm.buckets.first {
              selection = first.name
          }
        treeObjects = buildTree(from: vm.objects)
      }
      catch {
        errorMessage = error.localizedDescription
        showingAlert = true
      }
    }
    .alert("Error happened", isPresented: $showingAlert) {
      Button("Got it!", role: .cancel) {}
    } message: {
      Text(errorMessage)
    }
    .toolbar {
      ToolbarItemGroup {
        Text("BucketView")
          .bold()
          .font(.title3)

        Button(action: { showInspector.toggle() }) {
          Label("Toggle Inspector", systemImage: "sidebar.right")
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
#Preview {
  Mainscreen2()
    .environment(DataViewModel.preview)
}
