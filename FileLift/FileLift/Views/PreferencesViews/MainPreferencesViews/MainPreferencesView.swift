//
//  MainPreferencesView.swift
//  FileLift
//
//  Created by Szabolcs Tóth on 28.11.2025.
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

struct MainPreferencesView: View {
  // Private Properties
  @Environment(\.dataViewModel) private var vm: DataViewModelProtocol
  @AppStorage("autoUpload") private var autoUpload = true
  @AppStorage("compartmentId") private var compartmentId: String = ""
  @AppStorage("parBucketLink") private var parBucketLink: String = ""
  @AppStorage("parBucketLinkAvailable") private var parBucket = false
  @AppStorage("selection") private var selection = ""
  @State private var showingAlert = false
  @State private var errorMessage = ""

  // Properties
  var body: some View {
    content
      // Error
      .alert("Error happened", isPresented: $showingAlert) {
        Button("Got it!", role: .cancel) {}
      } message: {
        Text(errorMessage)
      }
  }

  @ViewBuilder
  var content: some View {
    VStack {
      Form {
        // Autoupload - no need confirmation for uploading
        AutouploadView(autoUpload: $autoUpload)

        Section {
          Toggle("PAR Link", isOn: $parBucket)
          ZStack {
            // OCI Setttings for `namespace`, `compartmentId` and `bucket`
            OCISettingView(compartmentId: $compartmentId, selection: $selection, nameSpace: vm.namespace, buckets: vm.buckets)
              .tabItem {
                Text("Namespace")
              }
              .opacity(parBucket ? 0 : 1)
              .animation(.easeInOut(duration: 0.9), value: parBucket)

            // This function hasn't been implemented yet in `PutObject`.
            PARBucketSettings(parBucketLink: $parBucketLink)
              .tabItem {
                Text("PAR bucket")
              }
              .opacity(parBucket ? 1 : 0)
              .animation(.easeInOut(duration: 0.9), value: parBucket)
          }

          Button {
            Task {
              if !(parBucket) {
                  try await prepareSettings()
              }
            }
          } label: {
            Text("Save settings")
          }
          .frame(maxWidth: .infinity)

        } header: {
          Text("OCI Settings")
        }

      }.formStyle(.grouped)
        .task {
          Task { try await self.listBuckets() }
        }
        .padding(.horizontal, 10)

    }
  }

  // MARK: - Functions
  private func listBuckets() async throws {
    do {
      try await vm.getNamespace()
    }
    catch {
      errorMessage = error.localizedDescription
      showingAlert = true
    }
  }

  private func getNamespace() async throws {
    do {
      try await vm.listBuckets()
    }
    catch {
      errorMessage = error.localizedDescription
      showingAlert = true
    }
  }

  private func prepareSettings() async throws {
    try await self.getNamespace()
    try await self.listBuckets()
  }
}

// MARK: - Preview
#Preview {
  MainPreferencesView()
}
