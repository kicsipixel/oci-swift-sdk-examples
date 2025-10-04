//
//  PreferencesView.swift
//  FileLift
//
//  Created by Szabolcs Tóth on 04.10.2025.
//  Copyright © 2025 Szabolcs Tóth. All rights reserved.
//

import SwiftUI

struct PreferencesView: View {
    @AppStorage("autoUpload") private var autoUpload = false
    @AppStorage("compartmentId") private var compartmentId: String = ""
    
    var body: some View {
        VStack {
            Form {
                Section {
                    Toggle("Enable Auto Upload", isOn: $autoUpload)
                        .disabled(true)
                } header: {
                    Text("Upload")
                }
                
                Section {
                    TextField("CompartmentId:", text: $compartmentId)
                } header: {
                    Text("OCI Settings")
                }
                
                Section {
                    Text("\(Bundle.main.formattedVersion)")
                } header: {
                    Text("Application")
                }
            }.formStyle(.grouped)
        }
        .padding(.horizontal, 10)
    }
}
 
// MARK: - Preview
#Preview {
    PreferencesView()
}
