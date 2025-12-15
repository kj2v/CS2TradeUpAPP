//
//  PriceModel.swift
//  CS2TradeUp
//
//  Created by 胡一潘 on 2025/12/12.
//

import Foundation

// 对应你最新提供的 JSON 结构
struct MarketItem: Codable {
    let id: Int?
    let name: String
    let exterior_localized_name: String?
    let rarity_localized_name: String?
    let img: String?
    let yyyp_sell_price: Double? // 注意：现在是 Double 类型
    let yyyp_sell_num: Int?
    
    // 辅助方法：格式化显示价格
    var displayPrice: String {
        if let price = yyyp_sell_price {
            return String(format: "¥%.2f", price)
        }
        return "暂无报价"
    }
    
    // 辅助方法：获取原始价格用于计算总成本
    var rawPrice: Double {
        return yyyp_sell_price ?? 0.0
    }
}
