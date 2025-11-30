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

struct Mainscreen: View {
  @AppStorage("compartmentId") private var compartmentId: String = ""
  @Environment(\.dataViewModel) private var vm: DataViewModelProtocol
  @State private var isInspectorShown: Bool = false
  @State private var selectedBucket: String = ""
  @State private var treeObjects: [ObjectNode] = []
  @State private var selectedID: ObjectSummary.ID?
  @State private var isWizardViewShown = false
  @State private var showingAlert: Bool = false
  @State private var errorMessage: String = ""
  @State private var isParLinkWanted = false
  @State private var parLink = ""

  private var selectedNode: ObjectNode? {
    findNode(in: treeObjects, matching: selectedID)
  }

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "dd MMM yyyy, HH:mm"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()

  var body: some View {
    VStack {
      VStack(alignment: .leading) {
        // OCI Basic Settings
        OCSettingsView(isParLinkWanted: $isParLinkWanted, compartmentId: $compartmentId, parLink: $parLink, selectedBucket: $selectedBucket)

        // Bucket Picker
        BucketPicker(isParLinkWanted: $isParLinkWanted, selectedBucket: $selectedBucket)
      }
      .padding(.bottom, 3)

      // List view
      ListView(selectedID: $selectedID, treeObjects: $treeObjects)
    }
    .padding(.vertical, 15)
    .padding(.horizontal, 10)
    .onChange(of: selectedBucket) { _, newValue in
      Task {
        try await vm.listObjects(bucketName: newValue)
        treeObjects = buildTree(from: vm.objects)
      }
    }
    // Error
    .alert("Error happened", isPresented: $showingAlert) {
      Button("Got it!", role: .cancel) {}
    } message: {
      Text(errorMessage)
    }
    .inspector(isPresented: $isInspectorShown) {
      InspectorView(node: selectedNode)
    }
    .toolbar {
      ToolbarItemGroup(placement: .automatic) {
          
        Button {
          Task {
            if selectedBucket.count > 0 {
              try await vm.listObjects(bucketName: selectedBucket)
              treeObjects = buildTree(from: vm.objects)
            }
          }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }

        Button {
          isInspectorShown.toggle()
        } label: {
          Label("Toggle Inspector", systemImage: "sidebar.right")
        }
      }
    }
  }

  private func prepareView() async throws {
    // Check compartment Id
    vm.checkCompartmentId()

    // Get Namespace
    do {
      try await vm.getNamespace()
    }
    catch {
      errorMessage = error.localizedDescription
      showingAlert = true
    }

    // List buckets in the given Namespace
    do {
      try await vm.listBuckets()
    }
    catch {
      errorMessage = error.localizedDescription
      showingAlert = true
    }

    // Populating objects
    treeObjects = buildTree(from: vm.objects)
  }

  private func buildTree(from rawObjects: [ObjectSummary]) -> [ObjectNode] {
    var root: [String: ObjectNode] = [:]

    for obj in rawObjects {
      let components = obj.name.split(separator: "/").map(String.init)
      let sizeString = obj.size.map { "\($0) bytes" }
      let createdString = obj.timeCreated.map { Self.dateFormatter.string(from: $0) }
      insertNode(
        into: &root,
        components: components,
        id: obj.id,
        size: sizeString,
        createdAt: createdString,
        etag: obj.etag,
        md5: obj.md5,
        storagetier: obj.storageTier,
        archivalstate: obj.archivalState
      )
    }

    return Array(root.values).sorted(by: { $0.name < $1.name })
  }

  private func insertNode(
    into dict: inout [String: ObjectNode],
    components: [String],
    id: ObjectSummary.ID,
    size: String?,
    createdAt: String?,
    etag: String?,
    md5: String?,
    storagetier: StorageTier?,
    archivalstate: ArchivalState?
  ) {
    guard let first = components.first else { return }

    if components.count == 1 {
      dict[first] = ObjectNode(id: id, name: first, size: size, createdAt: createdAt, etag: etag, md5: md5, storagetier: storagetier, archivalstate: archivalstate, children: nil)
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

      insertNode(into: &childDict, components: Array(components.dropFirst()), id: id, size: size, createdAt: createdAt, etag: etag, md5: md5, storagetier: storagetier, archivalstate: archivalstate)
      dict[first]?.children = Array(childDict.values).sorted(by: { $0.name < $1.name })
    }
  }

  private func findNode(in nodes: [ObjectNode], matching id: ObjectSummary.ID?) -> ObjectNode? {
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
