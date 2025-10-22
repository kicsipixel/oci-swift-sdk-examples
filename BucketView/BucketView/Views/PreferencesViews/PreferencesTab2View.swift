//
//  PreferencesTab2View.swift
//  BucketView
//
//  Created by Szabolcs Tóth on 22.10.2025.
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

import SwiftUI

struct PreferencesTab2View: View {
  // Private Properties
  @AppStorage("etag") private var etag: Bool = false
  @AppStorage("md5") private var md5: Bool = false
  @AppStorage("storagetier") private var storageTier: Bool = false
  @AppStorage("archivalstate") private var archivalState: Bool = false
  @Environment(DataViewModel.self) private var vm

  // Properties
  var body: some View {
    content
  }

  @ViewBuilder
  var content: some View {
    Form {
      // OCI Setttings for `namespace`, `compartmentId` and `bucket`
      // Valid values: `name`, `size`, `etag`, `md5`, `timeCreated`, `timeModified`, `storageTier`, `archivalState`.
      Section {
        Toggle(isOn: $etag) {
          Text("ETag:")
        }
        Toggle(isOn: $md5) {
          Text("MD5:")
        }
        Toggle(isOn: $storageTier) {
          Text("Storage Tier:")
        }
        Toggle(isOn: $archivalState) {
          Text("Archival State:")
        }
      } header: {
        Text("Fields of File to be shown")
      }.disabled(true)
    }.formStyle(.grouped)
  }
}

// MARK: - Preview
#Preview {
  PreferencesTab1View()
    .environment(DataViewModel.preview)
}
