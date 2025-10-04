//
//  ContentView.swift
//  FileLift
//
//  Created by Szabolcs Tóth on 03.10.2025.
//  Copyright © 2025 Szabolcs Tóth. All rights reserved.
//

import OCIKit
import SwiftUI

struct Mainscreen: View {
  // MARK: - Private Properties
  @Environment(DataViewModel.self) private var vm
  @State private var showingAlert: Bool = false
  @AppStorage("compartmentId") private var compartmentId: String = ""
  @State private var errorMessage: String = ""

  var body: some View {
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
      }
    }
    .task {
      do {
        try await vm.getNamespace()
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
  }
}

// MARK: - Preview
#Preview {
  Mainscreen()
    .environment(DataViewModel.preview)
}
