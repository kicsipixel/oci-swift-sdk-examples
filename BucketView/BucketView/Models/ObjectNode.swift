//
//  ObjectNode.swift
//  BucketView
//
//  Created by Szabolcs Tóth on 30.11.2025.
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

import Foundation
import OCIKit

struct ObjectNode: Identifiable, Hashable {
  let id: ObjectSummary.ID
  let name: String
  let size: String?
  let createdAt: String?
  let etag: String?
  let md5: String?
  let storagetier: StorageTier?
  let archivalstate: ArchivalState?
  var children: [ObjectNode]?

  init(
    id: ObjectSummary.ID,
    name: String,
    size: String? = nil,
    createdAt: String? = nil,
    etag: String? = nil,
    md5: String? = nil,
    storagetier: StorageTier? = nil,
    archivalstate: ArchivalState? = nil,
    children: [ObjectNode]? = nil
  ) {
    self.id = id
    self.name = name
    self.size = size
    self.createdAt = createdAt
    self.etag = etag
    self.md5 = md5
    self.storagetier = storagetier
    self.archivalstate = archivalstate
    self.children = children
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  static func == (lhs: ObjectNode, rhs: ObjectNode) -> Bool {
    lhs.id == rhs.id
  }
}
