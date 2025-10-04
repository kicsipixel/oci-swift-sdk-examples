//
//  FileLiftApp.swift
//  FileLift
//
//  Created by Szabolcs Tóth on 03.10.2025.
//  Copyright © 2025 Szabolcs Tóth. All rights reserved.
//

import SwiftUI

@main
struct FileLiftApp: App {
  let dataViewModel: DataViewModel

  init() {
    do {
      dataViewModel = try DataViewModel()
    }
    catch {
      fatalError("Failed to initialize DataViewModel: \(error)")
    }
  }

  var body: some Scene {
    // Mainscreen
    WindowGroup {
      Mainscreen()
        .environment(dataViewModel)
    }
    .defaultPosition(.center)
    .windowResizability(.contentSize)

    // Preferences
    Settings {
      PreferencesView()
        .environment(dataViewModel)
        .frame(width: 400, height: 460)
    }
  }
}
