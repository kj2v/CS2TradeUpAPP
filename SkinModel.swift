import Foundation
import SwiftUI

// 1. 定义 5 种磨损外观 (CS2 标准)
enum Wear: String, CaseIterable, Identifiable {
    case factoryNew = "崭新出厂"
    case minimalWear = "略有磨损"
    case fieldTested = "久经沙场"
    case wellWorn = "破损不堪"
    case battleScarred = "战痕累累"
    
    var id: String { self.rawValue }
    
    // 对应的磨损度范围
    var range: ClosedRange<Double> {
        switch self {
        case .factoryNew: return 0.00...0.07
        case .minimalWear: return 0.07...0.15
        case .fieldTested: return 0.15...0.38
        case .wellWorn: return 0.38...0.45
        case .battleScarred: return 0.45...1.00
        }
    }
}

// 2. 核心皮肤模型
struct Skin: Codable, Identifiable, Hashable {
    let id: String
    var name: String        // 改为 var，允许修改名字
    let description: String?
    let weapon: Weapon?
    let category: Category?
    let rarity: Rarity?
    let min_float: Double?
    let max_float: Double?
    let image: String?
    
    static func == (lhs: Skin, rhs: Skin) -> Bool {
        return lhs.id == rhs.id && lhs.name == rhs.name // 名字变了也被视为不同的变体
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
    }
    
    var imageURL: URL? {
        if let imageString = image {
            return URL(string: imageString)
        }
        return nil
    }
    
    // 🔴 核心方法：检查该皮肤是否支持某种外观
    // 并不是所有皮肤都有 0.0-1.0 的全磨损范围，有的锁磨损（比如二西莫夫最低 0.18）
    func supports(wear: Wear) -> Bool {
        guard let min = min_float, let max = max_float else { return true }
        
        // 检查两个区间是否有交集
        return wear.range.overlaps(min...max)
    }
    
    // 🔴 核心方法：生成带后缀的变体
    func withWear(_ wear: Wear) -> Skin {
        var newSkin = self
        // 拼接后缀，注意加空格，例如 " (崭新出厂)"
        // 这样就能匹配上你爬虫爬下来的 name 字段了
        newSkin.name = "\(self.name) (\(wear.rawValue))"
        return newSkin
    }
}

struct Weapon: Codable, Hashable {
    let id: String
    let name: String
}

struct Category: Codable, Hashable {
    let id: String
    let name: String
}

struct Rarity: Codable, Hashable {
    let id: String
    let name: String
    let color: String
    
    var swiftColor: Color {
        return Color(hex: color) ?? .gray
    }
}

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        var length = hexSanitized.count
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        let r, g, b: CGFloat
        if length == 6 {
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0
        } else { return nil }
        self.init(red: r, green: g, blue: b)
    }
}
