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
        loadSkins()
        loadRealPrices() // 🔴 切换为加载真实数据
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
    
    // MARK: - 皮肤加载 (保持不变)
    func loadSkins() {
        isLoading = true
        Task {
            do {
                let skins = try await fetchSkinsFromNetwork()
                await MainActor.run {
                    self.allSkins = skins
                    self.isLoading = false
                    print("🎉 皮肤元数据加载成功")
                }
            } catch {
                let localSkins = loadSkinsFromBundle()
                await MainActor.run {
                    self.allSkins = localSkins
                    self.isLoading = false
                }
            }
        }
    }
    
    private func fetchSkinsFromNetwork() async throws -> [Skin] {
        let urlString = "https://mirror.ghproxy.com/https://raw.githubusercontent.com/ByMykel/CSGO-API/main/public/data/zh-CN/skins.json"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([Skin].self, from: data).filter { $0.image != nil }
    }
    
    private func loadSkinsFromBundle() -> [Skin] {
        guard let url = Bundle.main.url(forResource: "skins", withExtension: "json") else { return [] }
        if let data = try? Data(contentsOf: url) {
            return (try? JSONDecoder().decode([Skin].self, from: data)) ?? []
        }
        return []
    }
}
