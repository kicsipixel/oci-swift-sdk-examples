//
//  Extensions.swift
//  FileLift
//
//  Created by Szabolcs Tóth on 04.10.2025.
//  Copyright © 2025 Szabolcs Tóth. All rights reserved.
//

import Foundation

extension Bundle {
    /// The app’s version number (CFBundleShortVersionString).
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    /// The app’s build number (CFBundleVersion).
    var buildNumber: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    /// Combined version string, e.g. "1.2.3 (45)"
    var formattedVersion: String {
        "v\(appVersion) \(buildNumber)"
    }
}
