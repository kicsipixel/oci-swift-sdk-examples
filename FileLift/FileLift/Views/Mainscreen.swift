//
//  Mainscreen.swift
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

struct Mainscreen: View {
  // MARK: - Private Properties
  @Environment(\.dataViewModel) private var vm: DataViewModelProtocol
  @State private var showingAlert: Bool = false
  @AppStorage("compartmentId") private var compartmentId: String = ""
  @State private var errorMessage: String = ""

  var body: some View {
    content
      .task {
        do {
          try await vm.getNamespace()
        }
        catch {
          errorMessage = error.localizedDescription
          showingAlert = true
        }
      }
      // Error
      .alert("Error happened", isPresented: $showingAlert) {
        Button("Got it!", role: .cancel) {}
      } message: {
        Text(errorMessage)
      }
  }

  @ViewBuilder
  var content: some View {
    ZStack {
      Color.white
        .ignoresSafeArea()

      DropzoneView()
        .padding()

      VStack(alignment: .center) {
        Image("folder")
          .resizable()
          .frame(width: 60, height: 60)
          .padding(.bottom, 2)

        Text(
          compartmentId.isEmpty
            ? "You need to set your compartmentId first."
            : "Drop your file here to upload."
        )
        .bold()
        .foregroundStyle(.accent)

        Text("DEMO MODE - config file is missing...")
          .opacity(vm.namespace == "DEMONAMESPACE" ? 1 : 0)
          .foregroundStyle(.accent)
          .font(.caption.bold())
          .padding(.top, 10)
      }

      ProgressView(label: {
        Text("Uploading file...")
      })
      .padding(20)
      .background(.white.opacity(0.93))
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .opacity(vm.isUploading ? 1 : 0)

      if let message = vm.uploadSuccessMessage {
        VStack {
          Image(systemName: "square.and.arrow.up.badge.checkmark")
            .font(.system(size: 32))
            .padding(.bottom, 10)
          Text("\(message)")
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 280)
            .multilineTextAlignment(.center)
        }
        .padding(10)
        .background(.white.opacity(0.93))
        .clipShape(RoundedRectangle(cornerRadius: 10))
      }
    }
  }
}

// MARK: - Preview
#Preview {
  Mainscreen()
    .environment(DataViewModel())
}
