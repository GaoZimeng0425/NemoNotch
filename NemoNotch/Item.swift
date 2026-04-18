//
//  Item.swift
//  NemoNotch
//
//  Created by GaoZimeng on 2026/4/18.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
