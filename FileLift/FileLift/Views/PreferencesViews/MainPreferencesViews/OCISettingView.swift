//
//  OCISettingView.swift
//  FileLift
//
//  Created by Szabolcs Tóth on 28.11.2025.
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
    

import OCIKit
import SwiftUI

struct OCISettingView: View {
    // Private Properties
    // Properties
    @Binding var compartmentId: String
    @Binding var selection: String
    let nameSpace: String
    let buckets: [BucketSummary]
    
    var body: some View {
        content
    }
    
    @ViewBuilder
    var content: some View {
        VStack(alignment: .leading) {
            Text("Namespace: \(nameSpace)")
            
            TextField("CompartmentId:", text: $compartmentId)
            
            Picker("Select a bucket:", selection: $selection) {
                ForEach(buckets, id: \.name) { bucket in
                    Text(bucket.name)
                }
            }
        }
    }
}

// MARK: - protocol
#Preview {
    OCISettingView(compartmentId: .constant("oci.aapppall"), selection: .constant(""), nameSpace: "jdgfyyrhhrr", buckets: [])
}
