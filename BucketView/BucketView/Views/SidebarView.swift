//
//  SidebarView.swift
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

struct SidebarView: View {
  // Private properties
  @Environment(DataViewModel.self) private var vm
  @Binding var selectedBucket: String?

  // Properties
  var body: some View {
    ZStack {
      // Background
     // Color.sidebar.ignoresSafeArea()

      // List
      List(selection: $selectedBucket) {
        Section("BUCKETS") {
          ForEach(vm.buckets, id: \.name) { bucket in
            Label("\(bucket.name)", systemImage: "balloon.2.fill")
              .foregroundStyle(Color.text)
              .bold()
              .shadow(color: .white.opacity(0.35), radius: 0, x: 1, y: 1)
          }
        }
      }
      .listStyle(SidebarListStyle())
      .frame(minWidth: 300)
    }
  }
}

// MARK: - Preview
#Preview {
    SidebarView(selectedBucket: .constant(nil))
    .environment(DataViewModel.preview)
}
