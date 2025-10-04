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
  
    @AppStorage("compartmentId") private var compartmentId: String = ""

    var body: some View {
        ZStack {
            Color.white
                .ignoresSafeArea()
            DropzoneView()
               
            VStack(alignment: .center) {
                Text(compartmentId.isEmpty ? "You need to set your compartmentId first." : "Drop your file here to upload.")
                    .bold()
                    .foregroundStyle(.accent)
            }
        }
    }
}

#Preview {
    Mainscreen()
        .environment(DataViewModel.preview)
}
