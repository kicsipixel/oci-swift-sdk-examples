//
//  WizardView.swift
//  BucketView
//
//  Created by Szabolcs Tóth on 23.10.2025.
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

struct WizardView: View {
  // Private Properties
  @AppStorage("compartmentId") private var compartmentId: String = ""
  @AppStorage("etag") private var etag: Bool = false
  @AppStorage("md5") private var md5: Bool = false
  @AppStorage("storagetier") private var storageTier: Bool = false
  @AppStorage("archivalstate") private var archivalState: Bool = false
  @Environment(DataViewModel.self) private var vm

  // Properties
  @Binding var show: Bool

  var body: some View {
    GeometryReader { geometry in
      VStack {
        Form {
          Section {
            TextField("CompartmentId:", text: $compartmentId)
          } header: {
            Text("Compartment")
          }

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
            Text("Files")
          }

          Button("Set") {
            withAnimation(.easeInOut(duration: 0.6)) {
              //     show = false
              vm.checkCompartmentId()
              Task {
                try await vm.listBuckets()
              }
            }
          }.frame(maxWidth: .infinity)
        }
        .formStyle(.grouped)
      }
      .padding(30)
      .frame(width: geometry.size.width, height: geometry.size.height)
      .background(Color.wizard)
      .offset(x: show ? 0 : geometry.size.width)
      .animation(.easeInOut(duration: 0.9), value: show)
    }
  }
}

#Preview {
  WizardView(show: .constant(true))
    .environment(DataViewModel.preview)
}
