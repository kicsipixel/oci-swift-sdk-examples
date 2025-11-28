//
//  PreferencesView.swift
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

import OCIKit
import SwiftUI

struct PreferencesView: View {
  @Environment(\.dataViewModel) private var vm: DataViewModelProtocol
  @AppStorage("autoUpload") private var autoUpload = true
  @AppStorage("compartmentId") private var compartmentId: String = ""
  @AppStorage("parBucketLink") private var parBucketLink: String = ""
  @AppStorage("selection") private var selection = ""
  @State private var showingAlert: Bool = false
  @State private var errorMessage: String = ""

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
        Section {
          Toggle("Enable Auto Upload", isOn: $autoUpload)
        } header: {
          Text("Upload")
        }

        // OCI Setttings for `namespace`, `compartmentId` and `bucket`
        Section {
          Text("Namespace: \(vm.namespace.replacingOccurrences(of: "\"", with: ""))")

          TextField("CompartmentId:", text: $compartmentId)

          Picker("Select a bucket:", selection: $selection) {
            ForEach(vm.buckets, id: \.name) { bucket in
              Text(bucket.name)
            }
          }

          HStack {
            Rectangle()
              .fill(Color.accent)
              .frame(width: 140, height: 1)

            Text("OR")
              .foregroundStyle(.accent)

            Rectangle()
              .fill(Color.accent)
              .frame(width: 140, height: 1)
          }

          // This function hasn't been implemented yet in `PutObject`.
          TextField("PAR bucket (Disabled):", text: $parBucketLink)

          Button {
            Task {
              try await self.getNamespace()
              try await self.listBuckets()
            }
          } label: {
            Text("Save settings")
          }
          .frame(maxWidth: .infinity)

        } header: {
          Text("OCI Settings")
        }

        // Application version and build for easier bug tracking
        Section {
          Text("\(Bundle.main.formattedVersion)")
        } header: {
          Text("Application")
        }
      }.formStyle(.grouped)
        .task {
          Task { try await self.listBuckets() }
        }
    }
    .padding(.horizontal, 10)
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
}

// MARK: - Preview
#Preview {
  PreferencesView()
    .environment(DataViewModel())
}
