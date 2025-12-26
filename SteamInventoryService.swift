import Foundation

// MARK: - Steam 资产模型
public struct SteamAsset: Identifiable, Codable {
    public let id: String
    public let name: String
    public let iconUrl: String
    public let isStatTrak: Bool
    public var wear: Double? // 真实磨损
    public let inspectLink: String? // 新增：检视链接
}

// MARK: - Steam 服务
public class SteamInventoryService {
    public static let shared = SteamInventoryService()
    
    // 您的 API Key (备用，主要用于 official API，这里暂不使用)
    private let apiKey = "AB177A71FD700098EBDB08FB9C6B156A"
    
    // 公开方法：获取完整库存（自动处理分页）
    public func fetchInventory(steamId: String, completion: @escaping (Result<[SteamAsset], Error>) -> Void) {
        // 开始递归拉取，初始 startAssetId 为 nil
        fetchPage(steamId: steamId, startAssetId: nil) { result in
            completion(result)
        }
    }
    
    // 私有方法：递归拉取单页 (修复 Escaping Closure 捕获 inout 问题)
    // 逻辑变更：不再使用 inout 参数，而是让回调返回“剩余的所有资产”，然后当前层负责拼接
    private func fetchPage(steamId: String, startAssetId: String?, completion: @escaping (Result<[SteamAsset], Error>) -> Void) {
        
        // 构建 URL：注意改为 schinese (简体中文)
        var urlString = "https://steamcommunity.com/inventory/\(steamId)/730/2?l=schinese&count=2000"
        if let startId = startAssetId {
            urlString += "&start_assetid=\(startId)"
        }
        
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "URL 构建失败", code: -1)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        
        // 伪装 Headers
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        
        print("🚀 [SteamService] 请求分页 (start: \(startAssetId ?? "0")): \(urlString)")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ 网络错误: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                print("⚠️ HTTP 状态码: \(httpResponse.statusCode)")
                completion(.failure(NSError(domain: "Steam 返回错误码: \(httpResponse.statusCode)", code: httpResponse.statusCode)))
                return
            }
            
            guard let data = data else {
                completion(.failure(NSError(domain: "无数据", code: -1)))
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // 1. 检查业务成功标志
                    if let success = json["success"] as? Int, success != 1 {
                        completion(.failure(NSError(domain: "Steam API success != 1", code: -1)))
                        return
                    }
                    
                    var currentPageAssets: [SteamAsset] = []
                    
                    // 2. 解析当前页数据
                    if let assets = json["assets"] as? [[String: Any]],
                       let descriptions = json["descriptions"] as? [[String: Any]] {
                        
                        // 建立描述索引
                        var descMap: [String: [String: Any]] = [:]
                        for desc in descriptions {
                            let classId = desc["classid"] as? String ?? ""
                            let instanceId = desc["instanceid"] as? String ?? "0"
                            descMap["\(classId)_\(instanceId)"] = desc
                        }
                        
                        // 匹配并转换
                        for asset in assets {
                            guard let assetId = asset["assetid"] as? String,
                                  let classId = asset["classid"] as? String,
                                  let instanceId = asset["instanceid"] as? String else { continue }
                            
                            if let desc = descMap["\(classId)_\(instanceId)"] {
                                let name = desc["market_hash_name"] as? String ?? "未知物品"
                                let icon = desc["icon_url"] as? String ?? ""
                                // 中文名下 StatTrak 可能是 "StatTrak™" 或 "StatTrak"
                                let isStatTrak = name.contains("StatTrak")
                                let type = desc["type"] as? String ?? ""
                                
                                // 过滤 (中文环境下的类型过滤)
                                let lowerType = type.lowercased()
                                
                                // 过滤逻辑增强
                                let isContainer = lowerType.contains("container") || lowerType.contains("容器") || lowerType.contains("箱")
                                let isGraffiti = lowerType.contains("graffiti") || lowerType.contains("涂鸦")
                                let isSticker = lowerType.contains("sticker") || lowerType.contains("印花")
                                let isKey = lowerType.contains("key") || lowerType.contains("钥匙")
                                let isMusic = lowerType.contains("music") || lowerType.contains("音乐")
                                let isMedal = lowerType.contains("medal") || lowerType.contains("徽章")
                                
                                if isContainer || isGraffiti || isSticker || isKey || isMusic || isMedal {
                                    continue
                                }
                                
                                let fullIconUrl = "https://community.cloudflare.steamstatic.com/economy/image/\(icon)"
                                
                                // 获取中文显示名
                                let displayName = desc["market_name"] as? String ?? name
                                
                                // 解析检视链接 (Inspect Link)
                                // Steam API 返回的 descriptions -> actions 数组里包含了检视链接模板
                                var inspectLink: String? = nil
                                if let actions = desc["actions"] as? [[String: Any]] {
                                    // 通常第一个 action 就是 "在游戏中检视..."
                                    // 格式通常为: "steam://rungame/730/76561202255233023/+csgo_econ_action_preview S%owner_steamid%A%assetid%D..."
                                    if let linkTemplate = actions.first?["link"] as? String {
                                        // 替换占位符
                                        inspectLink = linkTemplate
                                            .replacingOccurrences(of: "%owner_steamid%", with: steamId)
                                            .replacingOccurrences(of: "%assetid%", with: assetId)
                                        print(inspectLink)
                                    }
                                }
                                
                                currentPageAssets.append(SteamAsset(
                                    id: assetId,
                                    name: displayName, // 使用中文显示名
                                    iconUrl: fullIconUrl,
                                    isStatTrak: isStatTrak,
                                    wear: nil,
                                    inspectLink: inspectLink // 赋值
                                ))
                            }
                        }
                    }
                    
                    print("✅ 本页获取 \(currentPageAssets.count) 个物品")
                    
                    // 3. 检查是否还有更多 (Pagination)
                    let moreItems = json["more_items"] as? Int ?? 0
                    let lastAssetId = json["last_assetid"] as? String
                    
                    if moreItems == 1, let nextStart = lastAssetId {
                        // 递归拉取下一页
                        // 延迟一点点，避免 429
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                            // 递归调用：获取“剩余所有页”的数据
                            self.fetchPage(steamId: steamId, startAssetId: nextStart) { nextResult in
                                switch nextResult {
                                case .success(let nextAssets):
                                    // 成功：将当前页 + 剩余页合并
                                    let combinedAssets = currentPageAssets + nextAssets
                                    completion(.success(combinedAssets))
                                case .failure(let error):
                                    // 如果下一页失败，也可以选择返回当前已获取的，或者报错
                                    // 这里选择报错，或者你可以 print error 然后 completion(.success(currentPageAssets))
                                    print("⚠️ 后续页拉取失败: \(error.localizedDescription)，仅返回已获取数据")
                                    completion(.success(currentPageAssets))
                                }
                            }
                        }
                    } else {
                        // 全部拉取完毕
                        print("🎉 全部加载完成")
                        completion(.success(currentPageAssets))
                    }
                    
                } else {
                    completion(.failure(NSError(domain: "JSON 解析失败", code: -1)))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}
