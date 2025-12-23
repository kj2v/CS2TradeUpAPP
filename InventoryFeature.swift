import SwiftUI

// MARK: - 价格趋势拟合服务
class PriceCurveService {
    static let shared = PriceCurveService()
    
    func getPredictedPrice(skin: Skin, wear: Double, isStatTrak: Bool) -> Double {
        let basePrice = fetchBestMatchPrice(skin: skin, wear: wear, isStatTrak: isStatTrak)
        if basePrice <= 0 { return 0 }
        
        if let range = Wear.allCases.first(where: { $0.range.contains(wear) })?.range {
            let relativePos = (wear - range.lowerBound) / (range.upperBound - range.lowerBound)
            let premiumFactor = 1.0 + (1.0 - relativePos) * 0.05
            return basePrice * premiumFactor
        }
        return basePrice
    }
    
    private func fetchBestMatchPrice(skin: Skin, wear: Double, isStatTrak: Bool) -> Double {
        let wearName = Wear.allCases.first { $0.range.contains(wear) }?.rawValue ?? "崭新出厂"
        let prefix = isStatTrak ? "（StatTrak™）" : ""
        let base = skin.baseName // 例如 "Galil AR | Cold Fusion" 或 "Galil AR | 冰核聚变"
        
        // 1. 标准名称精确匹配
        // 尝试: "StatTrak™ Galil AR | 冰核聚变 (崭新出厂)"
        let searchName = "\(prefix)\(base) (\(wearName))"
        let p1 = DataManager.shared.getSmartPrice(for: searchName)
        if p1 > 0 { return p1 }
        
        // 2. 去空格尝试
        // 尝试: "StatTrak™GalilAR|冰核聚变 (崭新出厂)"
        let noSpaceBase = base.replacingOccurrences(of: " ", with: "")
        if noSpaceBase != base {
            let variantName = "\(prefix)\(noSpaceBase) (\(wearName))"
            let p = DataManager.shared.getSmartPrice(for: variantName)
            if p > 0 { return p }
        }
        
        // 3. 智能模糊匹配 (针对翻译混乱的枪名)
        // 策略：分割 武器 | 皮肤，保持皮肤名不变，尝试替换武器名为常见的中文翻译
        if let fuzzyPrice = fetchFuzzyPrice(base: base, wearName: wearName, prefix: prefix) {
            return fuzzyPrice
        }
        
        return 0
    }
    
    private func fetchFuzzyPrice(base: String, wearName: String, prefix: String) -> Double? {
        // 必须包含竖杠，因为策略是 "竖杠后肯定匹配"
        let parts = base.components(separatedBy: " | ")
        guard parts.count == 2 else { return nil }
        
        let weaponRaw = parts[0] // e.g. "Galil AR" 或 "加利尔 AR"
        let skinName = parts[1]  // e.g. "冰核聚变" (用户确认此部分准确)
        
        // 定义模糊匹配规则：(中文关键词, [尝试的数据库可能存在的武器名])
        // 只要 weaponRaw 包含 关键词，就尝试组合所有 替换词
        // 这里的关键词使用中文，以适应全中文的输入源
        let fuzzyRules: [(String, [String])] = [
            ("加利尔", ["加利尔 AR", "加利尔", "Galil AR"]),
            ("USP", ["USP 消音版", "USP-S", "USP"]),
            ("格洛克", ["格洛克 18 型", "格洛克 18", "格洛克", "Glock-18"]),
            ("CZ75", ["CZ75 自动手枪", "CZ75-Auto", "CZ75"]),
            ("沙漠之鹰", ["沙漠之鹰", "Desert Eagle"]),
            ("FN57", ["FN57", "Five-SeveN"]),
            ("双持贝瑞塔", ["双持贝瑞塔", "Dual Berettas"]),
            ("M4A1", ["M4A1 消音型", "M4A1-S", "M4A1"]), // 包含 M4A1 关键词
            ("MAC-10", ["MAC-10", "MAC-10 冲锋枪"]),
            ("MP9", ["MP9", "MP9 冲锋枪"]),
            ("R8", ["R8 左轮手枪", "R8 Revolver"]),
            ("SSG", ["SSG 08", "鸟狙"]), // 覆盖 SSG 08
            ("鸟狙", ["SSG 08", "鸟狙"]),
            ("SCAR", ["SCAR-20", "SCAR-20 自动狙击步枪"]),
            ("G3SG1", ["G3SG1", "G3SG1 自动狙击步枪"]),
            ("法玛斯", ["法玛斯", "FAMAS"]),
            ("野牛", ["PP-野牛", "PP-Bizon"]),
            ("MP7", ["MP7", "MP7 冲锋枪"]),
            ("P90", ["P90", "P90 冲锋枪"]),
            ("UMP-45", ["UMP-45", "UMP-45 冲锋枪"]),
            ("MAG-7", ["MAG-7", "警喷"]),
            ("XM1014", ["XM1014", "自动霰弹枪"]),
            ("新星", ["新星", "Nova"]),
            ("截短", ["截短霰弹枪", "Sawed-Off"]),
            ("M249", ["M249"])
        ]
        
        for (keyword, replacements) in fuzzyRules {
            // 如果当前的枪名包含关键词 (例如 "加利尔 AR" 包含 "加利尔")
            // 兼容输入可能是英文的情况 (keyword 用 localizedCaseInsensitiveContains 或手动添加英文 Key)
            if weaponRaw.contains(keyword) || weaponRaw.localizedCaseInsensitiveContains(keyword) {
                for rep in replacements {
                    // 构造新的尝试名称：前缀(StatTrak™) + 替换后的武器名 + | + 准确的皮肤名 + (磨损)
                    // 这样 StatTrak™ 会被正确保留在最前面，仅替换中间的枪名
                    let tryName = "\(rep)\(prefix) | \(skinName) (\(wearName))"
                    // M249（StatTrak™） | 闹市区 (略有磨损)
                    // print(tryName)
                    let p = DataManager.shared.getSmartPrice(for: tryName)
                    if p > 0 {
                        // print("✅ [Fuzzy Match Success] \(base) -> \(tryName)") // Debug
                        return p
                    }
                }
            }
        }
        
        // 如果以上规则都没命中，但包含英文，尝试最简单的中文直译推测（针对部分通用格式）
        // 比如有些数据仅仅是把 AR 去掉
        if weaponRaw.contains(" AR") {
            let simpleRep = weaponRaw.replacingOccurrences(of: " AR", with: "")
            let tryName = "\(prefix)\(simpleRep) | \(skinName) (\(wearName))"
            if let p = check(tryName) { return p }
        }
        
        return nil
    }
    
    // 辅助检查函数
    private func check(_ name: String) -> Double? {
        let p = DataManager.shared.getSmartPrice(for: name)
        return p > 0 ? p : nil
    }
}

// MARK: - 共享数据结构
struct SkinGroup: Identifiable {
    let id = UUID()
    let displayName: String
    let count: Int
    let exampleAsset: SteamAsset
    let matchedSkin: Skin?
    let avgPrice: Double
}

// MARK: - 库存配平模型
struct InventoryItem: Identifiable, Equatable, Hashable {
    let id = UUID()
    let tradeItem: TradeItem
    
    var skin: Skin { tradeItem.skin }
    var wear: Double { tradeItem.wearValue }
    
    var estimatedValue: Double {
        PriceCurveService.shared.getPredictedPrice(skin: skin, wear: wear, isStatTrak: tradeItem.isStatTrak)
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: InventoryItem, rhs: InventoryItem) -> Bool {
        return lhs.id == rhs.id
    }
}

// MARK: - 优化结果配方
struct OptimizedRecipe: Identifiable {
    let id = UUID()
    let index: Int
    let mainItems: [InventoryItem]
    let fillerItems: [InventoryItem]
    
    var allItems: [InventoryItem] { mainItems + fillerItems }
    
    var avgWear: Double {
        let total = allItems.reduce(0.0) { $0 + $1.wear }
        return allItems.isEmpty ? 0 : total / Double(allItems.count)
    }
    
    var expectedOutputValue: Double {
        guard let first = allItems.first else { return 0 }
        let inputLevel = first.skin.rarity?.level ?? 0
        let isStatTrak = first.tradeItem.isStatTrak
        
        let rawCol = DataManager.shared.getCollectionName(for: first.skin)
        let outcomes = DataManager.shared.getSkinsByLevelSmart(collectionRawName: rawCol, level: inputLevel + 1)
        
        if outcomes.isEmpty { return 0 }
        
        var totalProbVal = 0.0
        for outcome in outcomes {
            let minF = outcome.min_float ?? 0
            let maxF = outcome.max_float ?? 1
            let outputWear = avgWear * (maxF - minF) + minF
            
            let val = PriceCurveService.shared.getPredictedPrice(skin: outcome, wear: outputWear, isStatTrak: isStatTrak)
            totalProbVal += val
        }
        
        return totalProbVal / Double(outcomes.count)
    }
    
    var cost: Double {
        allItems.reduce(0.0) { $0 + $1.estimatedValue }
    }
    
    var roi: Double {
        cost > 0 ? (expectedOutputValue - cost) / cost : 0
    }
}

// MARK: - ViewModel
@Observable
class InventoryViewModel {
    var steamId: String = "76561198204777059"
    var isFetchingSteam = false
    var steamError: String? = nil
    
    var rawSteamInventory: [SteamAsset] = []
    
    var selectedMainSkin: Skin? = nil
    var selectedMainGroupName: String? = nil
    
    var selectedFillerSkin: Skin? = nil
    var selectedFillerGroupName: String? = nil
    
    var mainInventory: [InventoryItem] = []
    var fillerInventory: [InventoryItem] = []
    
    var targetRecipeCount: Int = 3
    var mainsPerRecipe: Int = 2
    
    var optimizedRecipes: [OptimizedRecipe] = []
    var isCalculating = false
    var errorMessage: String? = nil
    
    var totalInventoryValue: Double {
        (mainInventory + fillerInventory).reduce(0) { $0 + $1.estimatedValue }
    }
    var totalExpectedOutput: Double {
        optimizedRecipes.reduce(0) { $0 + $1.expectedOutputValue }
    }
    
    func fetchSteamInventory() {
        guard !steamId.isEmpty else { return }
        isFetchingSteam = true
        steamError = nil
        rawSteamInventory = []
        
        SteamInventoryService.shared.fetchInventory(steamId: steamId) { [weak self] result in
            DispatchQueue.main.async {
                self?.isFetchingSteam = false
                switch result {
                case .success(let assets):
                    if assets.isEmpty {
                        self?.steamError = "该账号库存为空或没有 CS2 可交易物品。"
                    } else {
                        self?.rawSteamInventory = self?.preFilterAssets(assets) ?? []
                    }
                case .failure(let error):
                    self?.steamError = error.localizedDescription
                }
            }
        }
    }
    
    private func preFilterAssets(_ assets: [SteamAsset]) -> [SteamAsset] {
        return assets.filter { asset in
            let name = asset.name
            if name.contains("纪念品") || name.contains("Souvenir") { return false }
            let invalidKeywords = ["匕首", "刀", "手套", "裹手", "徽章", "硬币", "音乐盒", "布章", "探员", "大师级", "非凡", "服役勋章"]
            for kw in invalidKeywords {
                if name.contains(kw) { return false }
            }
            return true
        }
    }
    
    func processInventoryForSelectedSkins() {
        mainInventory = []
        fillerInventory = []
        
        if let mainSkin = selectedMainSkin, let groupName = selectedMainGroupName {
            mainInventory = filterAndConvert(skin: mainSkin, targetGroupName: groupName, from: rawSteamInventory)
        }
        
        if let fillerSkin = selectedFillerSkin, let groupName = selectedFillerGroupName {
            fillerInventory = filterAndConvert(skin: fillerSkin, targetGroupName: groupName, from: rawSteamInventory)
        }
        
        optimizedRecipes = []
    }
    
    private func filterAndConvert(skin: Skin, targetGroupName: String, from assets: [SteamAsset]) -> [InventoryItem] {
        return assets.filter { asset in
            return asset.name == targetGroupName
        }.map { asset in
            let range = inferWearRange(from: targetGroupName)
            let minF = max(skin.min_float ?? 0.0, range.lowerBound)
            let maxF = min(skin.max_float ?? 1.0, range.upperBound)
            let simulatedWear = asset.wear ?? Double.random(in: minF...maxF)
            let item = TradeItem(skin: skin, wearValue: simulatedWear, isStatTrak: asset.isStatTrak)
            return InventoryItem(tradeItem: item)
        }
    }
    
    private func inferWearRange(from name: String) -> ClosedRange<Double> {
        if name.contains("崭新") || name.contains("Factory New") { return 0.00...0.07 }
        if name.contains("略有") || name.contains("略磨") || name.contains("Minimal Wear") { return 0.07...0.15 }
        if name.contains("久经") || name.contains("Field-Tested") { return 0.15...0.38 }
        if name.contains("破损") || name.contains("Well-Worn") { return 0.38...0.45 }
        if name.contains("战痕") || name.contains("Battle-Scarred") { return 0.45...1.00 }
        return 0.00...1.00
    }
    
    func getCompatibleInventory(for selectionType: InventorySmartView.SheetType) -> [SteamAsset] {
        guard let mainSkin = selectedMainSkin, selectionType == .fillerSelector else {
            if selectionType == .mainSelector, let filler = selectedFillerSkin {
                return filterCompatible(baseSkin: filler, from: rawSteamInventory)
            }
            return rawSteamInventory
        }
        return filterCompatible(baseSkin: mainSkin, from: rawSteamInventory)
    }
    
    private func filterCompatible(baseSkin: Skin, from assets: [SteamAsset]) -> [SteamAsset] {
        let targetLevel = baseSkin.rarity?.level
        let isMainST = selectedMainGroupName?.contains("StatTrak") ?? false
        let allSkins = DataManager.shared.getAllSkins()
        
        return assets.filter { asset in
            if asset.isStatTrak != isMainST { return false }
            let cleanName = cleanSteamName(asset.name)
            if let matched = allSkins.first(where: {
                let dbBase = cleanSteamName($0.baseName)
                return dbBase == cleanName || cleanName.contains(dbBase) || dbBase.contains(cleanName)
            }) {
                return matched.rarity?.level == targetLevel
            }
            return false
        }
    }
    
    func cleanSteamName(_ name: String) -> String {
        var cleaned = name
        let wears = [" (Factory New)", " (Minimal Wear)", " (Field-Tested)", " (Well-Worn)", " (Battle-Scarred)",
                     " (崭新出厂)", " (略有磨损)", " (久经沙场)", " (破损不堪)", " (战痕累累)"]
        for w in wears { cleaned = cleaned.replacingOccurrences(of: w, with: "") }
        
        let statTraks = ["StatTrak™ ", "StatTrak ", "（StatTrak™）", "(StatTrak™)"]
        for st in statTraks { cleaned = cleaned.replacingOccurrences(of: st, with: "") }
        
        cleaned = cleaned.replacingOccurrences(of: " ", with: "")
        
        return cleaned.trimmingCharacters(in: .whitespaces).lowercased()
    }
    
    func runOptimization() {
        isCalculating = true
        errorMessage = nil
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let neededMains = self.targetRecipeCount * self.mainsPerRecipe
            let neededFillers = self.targetRecipeCount * (10 - self.mainsPerRecipe)
            
            if self.mainInventory.count < neededMains || self.fillerInventory.count < neededFillers {
                DispatchQueue.main.async {
                    self.errorMessage = "库存不足：需要 \(neededMains)主/\(neededFillers)辅，实际 \(self.mainInventory.count)/\(self.fillerInventory.count)"
                    self.isCalculating = false
                }
                return
            }
            
            let activeMains = Array(self.mainInventory.sorted(by: { $0.wear < $1.wear }).prefix(neededMains))
            let activeFillers = Array(self.fillerInventory.sorted(by: { $0.wear < $1.wear }).prefix(neededFillers))
            
            var recipes: [OptimizedRecipe] = []
            var currentMains = activeMains
            var currentFillers = activeFillers
            
            for i in 0..<self.targetRecipeCount {
                let mSlice = currentMains.prefix(self.mainsPerRecipe)
                currentMains.removeFirst(self.mainsPerRecipe)
                let fSlice = currentFillers.prefix(10 - self.mainsPerRecipe)
                currentFillers.removeFirst(10 - self.mainsPerRecipe)
                recipes.append(OptimizedRecipe(index: i + 1, mainItems: Array(mSlice), fillerItems: Array(fSlice)))
            }
            
            var improved = true
            var iterations = 0
            while improved && iterations < 500 {
                improved = false
                iterations += 1
                let idx1 = Int.random(in: 0..<self.targetRecipeCount)
                let idx2 = Int.random(in: 0..<self.targetRecipeCount)
                if idx1 == idx2 { continue }
                var r1 = recipes[idx1]
                var r2 = recipes[idx2]
                let currentTotalEV = r1.expectedOutputValue + r2.expectedOutputValue
                
                if !r1.fillerItems.isEmpty && !r2.fillerItems.isEmpty {
                    var newR1Fillers = r1.fillerItems
                    var newR2Fillers = r2.fillerItems
                    let i = Int.random(in: 0..<newR1Fillers.count)
                    let j = Int.random(in: 0..<newR2Fillers.count)
                    let temp = newR1Fillers[i]
                    newR1Fillers[i] = newR2Fillers[j]
                    newR2Fillers[j] = temp
                    let newR1 = OptimizedRecipe(index: r1.index, mainItems: r1.mainItems, fillerItems: newR1Fillers)
                    let newR2 = OptimizedRecipe(index: r2.index, mainItems: r2.mainItems, fillerItems: newR2Fillers)
                    if newR1.expectedOutputValue + newR2.expectedOutputValue > currentTotalEV + 0.01 {
                        recipes[idx1] = newR1
                        recipes[idx2] = newR2
                        improved = true
                    }
                }
            }
            
            let finalRecipes = recipes.sorted { $0.expectedOutputValue > $1.expectedOutputValue }
            
            DispatchQueue.main.async {
                self.optimizedRecipes = finalRecipes
                self.isCalculating = false
            }
        }
    }
}

// MARK: - Steam 库存选择器 (回归 View 层计算，带 Debug)
struct SteamSkinSelectorView: View {
    let inventory: [SteamAsset] // 接收原始数据
    let onSelect: (Skin, String) -> Void
    @Environment(\.dismiss) var dismiss
    
    @State private var groups: [SkinGroup] = []
    @State private var isLoading = true
    @State private var debugInfo: String = ""
    @State private var retryAttempt = 0
    
    var body: some View {
        NavigationStack {
            VStack {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在匹配本地数据库...")
                            .foregroundColor(.secondary)
                        if retryAttempt > 0 {
                            Text("数据库正在加载，重试中 (\(retryAttempt))...")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                        Text(debugInfo)
                            .font(.caption2)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                } else {
                    List(groups) { group in
                        Button(action: {
                            if let skin = group.matchedSkin {
                                onSelect(skin, group.displayName)
                                dismiss()
                            }
                        }) {
                            HStack {
                                ZStack {
                                    CachedImage(url: URL(string: group.exampleAsset.iconUrl), transition: false)
                                        .frame(width: 60, height: 45)
                                }
                                .padding(2)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(group.matchedSkin?.rarity?.swiftColor ?? .gray, lineWidth: 2)
                                )
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.displayName)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)
                                        .lineLimit(2)
                                    
                                    HStack {
                                        Text("库存: \(group.count)")
                                            .font(.caption)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.1))
                                            .cornerRadius(4)
                                            .foregroundColor(.blue)
                                        
                                        if group.avgPrice > 0 {
                                            Text("¥\(String(format: "%.2f", group.avgPrice))")
                                                .font(.caption)
                                                .fontWeight(.bold)
                                                .foregroundColor(.green)
                                        } else {
                                            Text("暂无报价")
                                                .font(.caption)
                                                .foregroundColor(.gray)
                                        }
                                        
                                        if group.matchedSkin == nil {
                                            Text("未匹配数据库")
                                                .font(.caption)
                                                .foregroundColor(.red)
                                        }
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.gray)
                            }
                        }
                        .disabled(group.matchedSkin == nil)
                    }
                }
            }
            .navigationTitle("选择库存物品")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                processGroups()
            }
        }
    }
    
    private func processGroups() {
        print("🕒 [Debug] 界面出现，开始执行匹配逻辑... \(Date()) attempt: \(retryAttempt)")
        
        // 🚨 关键修复：加入重试逻辑
        // 因为 DataManager 可能是首次被访问，正在后台异步加载 JSON/API，
        // 导致 getAllSkins() 返回空，或者 getSmartPrice 返回 0。
        
        DispatchQueue.global(qos: .userInitiated).async {
            // 每次执行时都重新获取一次 Skin 列表，以防 DataManager 刚加载完
            let allSkins = DataManager.shared.getAllSkins()
            
            // 1. 按 Steam 原名分组
            let grouped = Dictionary(grouping: inventory) { $0.name }
            
            // 2. 匹配
            let computedGroups = grouped.map { (fullName, assets) -> SkinGroup in
                var cleanName = fullName
                let wears = [" (Factory New)", " (Minimal Wear)", " (Field-Tested)", " (Well-Worn)", " (Battle-Scarred)",
                             " (崭新出厂)", " (略有磨损)", " (久经沙场)", " (破损不堪)", " (战痕累累)"]
                for w in wears { cleanName = cleanName.replacingOccurrences(of: w, with: "") }
                let statTraks = ["StatTrak™ ", "StatTrak ", "（StatTrak™）", "(StatTrak™)"]
                for st in statTraks { cleanName = cleanName.replacingOccurrences(of: st, with: "") }
                let cleanNameNoSpace = cleanName.replacingOccurrences(of: " ", with: "").lowercased()
                
                // 匹配数据库
                let matched = allSkins.first { skin in
                    let dbBaseNoSpace = skin.baseName.replacingOccurrences(of: " ", with: "").lowercased()
                    let dbFullNoSpace = skin.name.replacingOccurrences(of: " ", with: "").lowercased()
                    return dbBaseNoSpace == cleanNameNoSpace || dbFullNoSpace.contains(cleanNameNoSpace) || cleanNameNoSpace.contains(dbBaseNoSpace)
                }
                
                let example = assets.first!
                let isST = example.isStatTrak
                
                var dummyWear = 0.1
                if fullName.contains("崭新") { dummyWear = 0.01 }
                else if fullName.contains("略有") { dummyWear = 0.10 }
                else if fullName.contains("久经") { dummyWear = 0.20 }
                else if fullName.contains("破损") { dummyWear = 0.40 }
                else if fullName.contains("战痕") { dummyWear = 0.50 }
                
                // 价格获取
                var price = 0.0
                if let skin = matched {
                    price = PriceCurveService.shared.getPredictedPrice(skin: skin, wear: dummyWear, isStatTrak: isST)
                } else {
                    price = DataManager.shared.getSmartPrice(for: fullName)
                }
                
                return SkinGroup(
                    displayName: fullName,
                    count: assets.count,
                    exampleAsset: example,
                    matchedSkin: matched,
                    avgPrice: price
                )
            }.sorted { $0.count > $1.count }
            
            // 3. 检查数据质量 (是否加载了价格或皮肤)
            // 如果库存不为空，但计算结果里 0 个匹配 或 0 个有价格，说明数据库可能还没好
            let hasMatches = computedGroups.contains { $0.matchedSkin != nil }
            let hasPrices = computedGroups.contains { $0.avgPrice > 0 }
            let isInventoryEmpty = self.inventory.isEmpty
            
            DispatchQueue.main.async {
                // 如果库存非空，但完全没有匹配到价格或皮肤，且重试次数 < 3，则认为是数据未加载
                if !isInventoryEmpty && (!hasMatches || !hasPrices) && self.retryAttempt < 3 {
                    self.retryAttempt += 1
                    let delay = 0.5 * Double(self.retryAttempt) // 递增等待：0.5s, 1.0s, 1.5s
                    
                    print("⚠️ [Debug] 数据库似乎未就绪 (匹配: \(hasMatches), 价格: \(hasPrices))，\(delay)秒后重试...")
                    self.debugInfo = "等待数据加载 (尝试 \(self.retryAttempt)/3)..."
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self.processGroups()
                    }
                } else {
                    // 成功或已达最大重试次数
                    self.groups = computedGroups
                    self.isLoading = false
                    print("✅ [Debug] 匹配完成! 结果: \(computedGroups.count) 组")
                    
                    if !isInventoryEmpty && !hasMatches {
                         self.debugInfo = "未匹配到任何饰品数据，请检查本地数据库"
                    }
                }
            }
        }
    }
}

// MARK: - UI 视图 (InventorySmartView)
struct InventorySmartView: View {
    @State private var viewModel = InventoryViewModel()
    
    enum SheetType: Identifiable {
        case mainSelector
        case fillerSelector
        var id: Int { hashValue }
    }
    
    @State private var activeSheet: SheetType?
    @State private var showSteamIdAlert = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Steam 连接卡片
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "person.icloud.fill").foregroundColor(.blue)
                            Text("Steam 库存连接").font(.headline)
                            Spacer()
                            if viewModel.isFetchingSteam {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Button(viewModel.rawSteamInventory.isEmpty ? "点击加载" : "刷新库存") {
                                    showSteamIdAlert = true
                                }
                                .font(.caption).buttonStyle(.borderedProminent)
                            }
                        }
                        
                        if !viewModel.rawSteamInventory.isEmpty {
                            Text("已加载 \(viewModel.rawSteamInventory.count) 件物品").font(.caption).foregroundColor(.green)
                        }
                        
                        if let err = viewModel.steamError {
                            Text(err).font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding().background(Color(UIColor.secondarySystemBackground)).cornerRadius(16).padding(.horizontal)
                    .onTapGesture { showSteamIdAlert = true }

                    if !viewModel.rawSteamInventory.isEmpty {
                        HStack(spacing: 16) {
                            SelectionCard(
                                title: "主料 (Main)",
                                skin: viewModel.selectedMainSkin,
                                subtitle: viewModel.selectedMainGroupName,
                                count: viewModel.mainInventory.count,
                                color: .orange,
                                action: { activeSheet = .mainSelector }
                            )
                            
                            SelectionCard(
                                title: "辅料 (Filler)",
                                skin: viewModel.selectedFillerSkin,
                                subtitle: viewModel.selectedFillerGroupName,
                                count: viewModel.fillerInventory.count,
                                color: .blue,
                                action: { activeSheet = .fillerSelector }
                            )
                        }
                        .padding(.horizontal)
                    } else {
                        Button(action: { showSteamIdAlert = true }) {
                            VStack(spacing: 12) {
                                Image(systemName: "arrow.up.circle").font(.largeTitle)
                                Text("请先点击上方“刷新库存”\n连接 Steam 并读取数据").multilineTextAlignment(.center)
                            }
                            .foregroundColor(.secondary).frame(maxWidth: .infinity).padding(.vertical, 40)
                            .background(Color(UIColor.secondarySystemBackground).opacity(0.5)).cornerRadius(16).padding(.horizontal)
                        }
                    }
                    
                    if viewModel.selectedMainSkin != nil && viewModel.selectedFillerSkin != nil {
                        VStack(spacing: 16) {
                            HStack {
                                Text("目标炉数").font(.headline)
                                Spacer()
                                Stepper("\(viewModel.targetRecipeCount) 炉", value: $viewModel.targetRecipeCount, in: 1...10).fixedSize()
                            }
                            HStack {
                                Text("主料数量/炉").font(.headline)
                                Spacer()
                                Stepper("\(viewModel.mainsPerRecipe) 个", value: $viewModel.mainsPerRecipe, in: 1...9).fixedSize()
                            }
                            
                            Button(action: { withAnimation { viewModel.runOptimization() } }) {
                                HStack {
                                    if viewModel.isCalculating { ProgressView().tint(.white) } else { Image(systemName: "wand.and.stars") }
                                    Text(viewModel.isCalculating ? "计算中..." : "开始智能分配")
                                }
                                .font(.headline).foregroundColor(.white).frame(maxWidth: .infinity).frame(height: 54)
                                .background(Color.blue).cornerRadius(16)
                            }
                            .disabled(viewModel.isCalculating)
                            
                            if let err = viewModel.errorMessage {
                                Text(err).font(.caption).foregroundColor(.red)
                            }
                        }
                        .padding(20).background(Color(UIColor.secondarySystemBackground)).cornerRadius(20).padding(.horizontal)
                        
                        if !viewModel.optimizedRecipes.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("分配方案 (模拟磨损)").font(.title2).bold().padding(.horizontal).foregroundColor(.orange)
                                ForEach(viewModel.optimizedRecipes) { recipe in RecipeResultCard(recipe: recipe) }
                            }
                            .padding(.bottom, 50).transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
            }
            .navigationTitle("库存配平")
            .sheet(item: $activeSheet) { type in
                SteamSkinSelectorView(
                    inventory: viewModel.getCompatibleInventory(for: type),
                    onSelect: { skin, groupName in
                        if type == .mainSelector {
                            viewModel.selectedMainSkin = skin
                            viewModel.selectedMainGroupName = groupName
                            if let filler = viewModel.selectedFillerSkin, filler.rarity?.level != skin.rarity?.level {
                                viewModel.selectedFillerSkin = nil
                                viewModel.selectedFillerGroupName = nil
                            }
                        } else {
                            viewModel.selectedFillerSkin = skin
                            viewModel.selectedFillerGroupName = groupName
                        }
                        viewModel.processInventoryForSelectedSkins()
                    }
                )
            }
            .alert("连接 Steam 库存", isPresented: $showSteamIdAlert) {
                TextField("Steam ID (64位)", text: $viewModel.steamId)
                Button("确定") { viewModel.fetchSteamInventory() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("输入您的 64 位 Steam ID 以读取公开库存。")
            }
        }
    }
}

// MARK: - UI 组件 (SelectionCard, RecipeResultCard 等保持不变)
// (为节省篇幅，这里复用之前生成的代码，请确保文件末尾包含 SelectionCard, RecipeResultCard, InventorySlotMini, StatValue 的定义)
struct SelectionCard: View {
    let title: String
    let skin: Skin?
    var subtitle: String? = nil
    let count: Int
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Text(title).font(.subheadline).fontWeight(.bold).foregroundColor(color).frame(maxWidth: .infinity, alignment: .leading)
                skinContent
            }
            .padding().frame(height: 160).frame(maxWidth: .infinity)
            .background(Color(UIColor.systemBackground)).cornerRadius(16)
            .shadow(color: color.opacity(0.1), radius: 5, x: 0, y: 2)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(skin != nil ? color : Color.gray.opacity(0.2), lineWidth: 2))
        }
    }
    
    @ViewBuilder var skinContent: some View {
        if let currentSkin = skin {
            CachedImage(url: currentSkin.imageURL, transition: false).frame(height: 50)
            VStack(spacing: 2) {
                Text(currentSkin.baseName).font(.caption).lineLimit(1).foregroundColor(.primary)
                if let sub = subtitle {
                    Text(sub).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Text("库存: \(count)").font(.caption2).padding(.horizontal, 8).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.2)).cornerRadius(4).foregroundColor(.primary)
        } else {
            Image(systemName: "plus").font(.largeTitle).foregroundColor(Color.gray.opacity(0.3)).frame(height: 60)
            Text("点击选择").font(.caption).foregroundColor(.secondary)
        }
    }
}

struct RecipeResultCard: View {
    let recipe: OptimizedRecipe
    var roiColor: Color { recipe.roi > 0 ? .red : (recipe.roi < -0.2 ? .gray : .green) }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("配方 #\(recipe.index)").font(.headline).foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6).background(roiColor).cornerRadius(8)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("期望: ¥\(String(format: "%.1f", recipe.expectedOutputValue))").font(.system(size: 14, weight: .bold)).foregroundColor(roiColor)
                    Text("ROI: \(recipe.roi > 0 ? "+" : "")\(String(format: "%.1f", recipe.roi * 100))%").font(.caption).foregroundColor(.secondary)
                }
            }
            .padding().background(roiColor.opacity(0.1))
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("平均磨损").font(.caption).foregroundColor(.secondary)
                    Text(String(format: "%.6f", recipe.avgWear)).font(.system(size: 12, design: .monospaced)).fontWeight(.medium)
                    Spacer()
                    Text("成本: ¥\(String(format: "%.1f", recipe.cost))").font(.caption).foregroundColor(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(recipe.allItems, id: \.self) { item in InventorySlotMini(item: item) }
                    }
                }
            }
            .padding()
        }
        .background(Color(UIColor.systemBackground)).cornerRadius(16).shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 5).padding(.horizontal)
    }
}

struct InventorySlotMini: View {
    let item: InventoryItem
    var wearColor: Color {
        if item.wear < 0.07 { return Color(hex: "#2ebf58")! }
        if item.wear < 0.15 { return Color(hex: "#87c34a")! }
        if item.wear < 0.38 { return Color(hex: "#eabd38")! }
        return Color(hex: "#e24e4d")!
    }
    
    var body: some View {
        VStack(spacing: 0) {
            CachedImage(url: item.skin.imageURL, transition: false).frame(width: 36, height: 28)
            Rectangle().fill(wearColor).frame(height: 2)
            Text(String(format: "%.3f", item.wear)).font(.system(size: 7)).foregroundColor(.secondary).padding(.top, 2)
        }
        .frame(width: 40).padding(4).background(Color(UIColor.secondarySystemBackground)).cornerRadius(4)
    }
}

struct StatValue: View {
    let label: String
    let value: String
    var color: Color = .primary
    
    var body: some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(value).font(.headline).foregroundColor(color)
        }
    }
}
