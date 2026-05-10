//
//  Item.swift
//  AoiStitcher
//
//  Created by 阿多 on 2026/4/1.
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
