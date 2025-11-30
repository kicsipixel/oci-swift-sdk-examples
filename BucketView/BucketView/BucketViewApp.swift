//
//  BucketViewApp.swift
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

import Sparkle
import SwiftUI

struct InitError: Identifiable {
  let id = UUID()
  let error: Error
}

@main
struct BucketViewApp: App {
  // Private Properties
  private let updaterController: SPUStandardUpdaterController
  @State private var initError: InitError?

  // Properties
  let dataViewModel: DataViewModelProtocol

  init() {
    // Sparkle init
    updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    do {
      // DataViewModel init
      dataViewModel = try DataViewModel()
    }
    catch {
      // Wrap the error so SwiftUI can track it
      _initError = State(initialValue: InitError(error: error))
      print("⚠️ Failed to initialize DataViewModel: \(error)")
      dataViewModel = MockDataViewModel()
    }
  }

  var body: some Scene {
    WindowGroup {
      Mainscreen()
            .frame(minWidth: 600, minHeight: 480)
        .environment(\.dataViewModel, dataViewModel)
        .alert(item: $initError) { initError in
          Alert(
            title: Text("Initialization Error"),
            message: Text(initError.error.localizedDescription),
            dismissButton: .default(Text("OK"))
          )
        }
    }
    .commands {
      CommandGroup(after: .appInfo) {
        CheckForUpdatesView(updater: updaterController.updater)
      }
    }
    .windowResizability(.contentSize)
    .defaultPosition(.center)

    // Preferences
    Settings {
      PreferencesView()
        .environment(\.dataViewModel, dataViewModel)
        .frame(width: 400, height: 400)
    }
  }
}
