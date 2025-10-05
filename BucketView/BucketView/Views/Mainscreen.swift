//
//  Mainscreen.swift
//  BucketView
//
//  Created by Szabolcs Tóth on 05.10.2025.
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

struct Mainscreen: View {
  // Private properties
  @State private var showInspector: Bool = false
    @State private var selection: String = ""

  var body: some View {
    content
      .frame(width: 440, height: 480)
      .inspector(isPresented: $showInspector) {
        InspectorView()
      }
      .toolbar {
        Text("BucketView")
          .bold()
          .font(.title3)

        Button(action: { showInspector.toggle() }) {
          Label("Toggle Inspector", systemImage: "sidebar.right")
        }
      }
  }

  @ViewBuilder
  var content: some View {
      VStack {
          Picker("Select bucket", selection: $selection) {
              Text("1")
              Text("2")
          }
          Text("Hello, World!")
          
          Spacer()
      }
      .padding(.horizontal, 30)
  }
}

#Preview {
  Mainscreen()
}
