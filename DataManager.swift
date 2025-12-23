import Foundation

@Observable
class DataManager {
    static let shared = DataManager()
    
    // 皮肤元数据
    var allSkins: [Skin] = []
    
    // 价格字典
    var priceMap: [String: MarketItem] = [:]
    
    var isLoading = false
    var errorMessage: String?
    
    init() {
        loadSkins() // ✅ 直接加载本地
        loadRealPrices()
    }
    
    // MARK: - 加载真实爬取的价格数据
    func loadRealPrices() {
        print("📂 正在加载本地 cs2_skins_db.json ...")
        
        guard let url = Bundle.main.url(forResource: "cs2_skins_db", withExtension: "json") else {
            print("❌ 错误：找不到 cs2_skins_db.json，请确保已创建文件并勾选 Target Membership")
            return
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            // 尝试解析
            let items = try decoder.decode([MarketItem].self, from: data)
            
            // 转字典 (name -> Item)
            var newMap: [String: MarketItem] = [:]
            for item in items {
                // 如果爬虫数据里有 name 字段，直接用
                newMap[item.name] = item
            }
            
            // 在主线程更新 UI 相关数据
            DispatchQueue.main.async {
                self.priceMap = newMap
                print("💰 真实价格库加载完成: \(newMap.count) 条报价")
            }
        } catch {
            print("❌ 价格数据解析失败: \(error)")
            // 打印详细解析错误，方便你看是不是字段名对不上
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .keyNotFound(let key, _):
                    print("   -> 缺少字段: \(key.stringValue)")
                case .typeMismatch(_, let context):
                    print("   -> 类型不匹配: \(context.debugDescription)")
                default: break
                }
            }
        }
    }
    
    // 查价格
    func getPrice(for skinName: String) -> String {
        return priceMap[skinName]?.displayPrice ?? "---"
    }
    
    func getRawPrice(for skinName: String) -> Double {
        return priceMap[skinName]?.rawPrice ?? 0.0
    }
    
    // MARK: - 皮肤加载 (仅本地)
    func loadSkins() {
        isLoading = true
        print("📂 正在加载本地 skins.json ...")
        
        // 直接同步加载，不再使用 Task 和网络请求
        let localSkins = loadSkinsFromBundle()
        self.allSkins = localSkins
        self.isLoading = false
        
        if localSkins.isEmpty {
            print("⚠️ 警告：本地 skins.json 未找到或解析为空")
        } else {
            print("🎉 皮肤元数据加载成功: \(localSkins.count) 个条目")
        }
    }
    
    private func loadSkinsFromBundle() -> [Skin] {
        guard let url = Bundle.main.url(forResource: "skins", withExtension: "json") else {
            print("❌ 错误：Bundle 中找不到 skins.json")
            return []
        }
        
        do {
            let data = try Data(contentsOf: url)
            // 过滤掉没有图片的皮肤，保持数据整洁
            let decodedSkins = try JSONDecoder().decode([Skin].self, from: data)
            return decodedSkins.filter { $0.image != nil }
        } catch {
            print("❌ 本地 skins.json 解析失败: \(error)")
            return []
        }
    }
}
