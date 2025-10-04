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
    // Private properties
    @Environment(DataViewModel.self) private var vm
    @State private var selection: String? = nil
    @State var isOn = false

    var body: some View {
        ZStack {
            Color.white
                .ignoresSafeArea()
            DropzoneView()
               
            VStack {
                Text("Drop your file to start uploading.")
            }
        }
    }
}

#Preview {
    Mainscreen()
        .environment(DataViewModel.preview)
}
