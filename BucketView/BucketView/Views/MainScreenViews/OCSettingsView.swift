//
//  OCSettingsView.swift
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

struct OCSettingsView: View {
  // Private Properties
  @Environment(\.dataViewModel) private var vm: DataViewModelProtocol
  @State private var showAlert = false
  @State private var errorMessage: String = ""
  @State private var isSaveButtonEnabled: Bool = true

  // Properties
  @Binding var isParLinkWanted: Bool
  @Binding var compartmentId: String
  @Binding var parLink: String
  @Binding var selectedBucket: String

  var body: some View {
    content
      // Error
      .alert("Error happened", isPresented: $showAlert) {
        Button("Got it!", role: .cancel) {}
      } message: {
        Text(errorMessage)
      }
      .onChange(of: compartmentId) { _, _ in
        isSaveButtonEnabled = true
      }
      .onChange(of: parLink) { _, _ in
        isSaveButtonEnabled = true
      }
  }

  @ViewBuilder
  var content: some View {
    GroupBox(label: Label("OCI", image: "CloudIcon").bold()) {
      VStack(alignment: .leading) {
        Toggle("PAR link", isOn: $isParLinkWanted)
          .toggleStyle(.switch)
        HStack {
          ZStack {
            TextField("compartmentId: ", text: $compartmentId)
              .opacity(isParLinkWanted ? 0 : 1)
            TextField("PAR link:", text: $parLink)
              .opacity(isParLinkWanted ? 1 : 0)
          }
          Button {
            if !(isParLinkWanted) {
              // get name space and list buckets
              Task {
                if compartmentId.count > 0 {
                  do {
                    isSaveButtonEnabled = false
                    try await vm.getNamespace()
                    try await vm.listBuckets()
                    if vm.buckets.count > 0 {
                      if let name = vm.buckets.first?.name {
                        selectedBucket = name
                      }
                    }
                  }
                  catch {
                    errorMessage = error.localizedDescription
                    showAlert = true
                  }
                }
                else {
                  errorMessage = "comaprtmentId is empty. Please add a relevant value."
                  showAlert = true
                }
              }
            } else {
                isSaveButtonEnabled = false
            }
          } label: {
            Text("Save")
          }
          .disabled(isSaveButtonEnabled ? false :  true)
        }
      }
      .padding(.vertical, 3)
      .padding(.horizontal, 6)
    }
  }
}

// MARK: - Preview
#Preview {
  OCSettingsView(isParLinkWanted: .constant(true), compartmentId: .constant(""), parLink: .constant(""), selectedBucket: .constant("par"))
}
