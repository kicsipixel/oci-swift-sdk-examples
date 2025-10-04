//
//  PreferencesView.swift
//  FileLift
//
//  Created by Szabolcs Tóth on 04.10.2025.
//  Copyright © 2025 Szabolcs Tóth. All rights reserved.
//

import OCIKit
import SwiftUI

struct PreferencesView: View {
  @AppStorage("autoUpload") private var autoUpload = false
  @AppStorage("compartmentId") private var compartmentId: String = ""
  @AppStorage("parBucketLink") private var parBucketLink: String = ""
  @Environment(DataViewModel.self) private var vm
  @AppStorage("selection") private var selection = ""

  var body: some View {
    content
  }

  @ViewBuilder
  var content: some View {
    VStack {
      Form {
        Section {
          Toggle("Enable Auto Upload", isOn: $autoUpload)
            .disabled(true)
        } header: {
          Text("Upload (Disabled)")
        }

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

          TextField("PAR bucket (Disabled):", text: $parBucketLink)
        } header: {
          Text("OCI Settings")
        }

        Section {
          Text("\(Bundle.main.formattedVersion)")
        } header: {
          Text("Application")
        }
      }.formStyle(.grouped)
        .task {
          do {
            try await vm.listBuckets()
          }
          catch {}
        }
    }
    .padding(.horizontal, 10)
  }
}

// MARK: - Preview
#Preview {
  PreferencesView()
    .environment(DataViewModel.preview)
}
