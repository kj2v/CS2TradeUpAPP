import SwiftUI
import Combine



// MARK: - 核心磨损计算公式
struct TradeUpFormula {
    static func calculateOutcomeWear(avgInputFactor: Double, outcomeSkin: Skin) -> Double {
        let minF = outcomeSkin.min_float ?? 0.0
        let maxF = outcomeSkin.max_float ?? 1.0
        let range = maxF - minF
        let wear = (avgInputFactor * range) + minF
        return Double(String(format: "%.9f", wear)) ?? wear
    }
}

// MARK: - 独立磨损查询服务
class InventoryWearFetchService {
    static let shared = InventoryWearFetchService()
    
    private let baseURL = "https://api.csgofloat.com/"
    private let cacheKey = "InventoryWearCache_v1"
    private var wearCache: [String: Double] = [:]
    
    init() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let saved = try? JSONDecoder().decode([String: Double].self, from: data) {
            wearCache = saved
        }
    }
    
    func getCachedWear(for link: String) -> Double? { return wearCache[link] }
    
    // 🔥 新增：清除缓存方法
    func clearCache() {
        wearCache.removeAll()
        UserDefaults.standard.removeObject(forKey: cacheKey)
        print("🗑️ [InventoryWearFetchService] 磨损缓存已清除")
    }
    
    func saveWear(link: String, wear: Double) {
        wearCache[link] = wear
        DispatchQueue.global(qos: .background).async {
            if let data = try? JSONEncoder().encode(self.wearCache) {
                UserDefaults.standard.set(data, forKey: self.cacheKey)
            }
        }
    }
    
    func fetchWear(inspectLink: String, completion: @escaping (Result<Double, Error>) -> Void) {
        if let cached = getCachedWear(for: inspectLink) {
            completion(.success(cached))
            return
        }
        
        let cleanLink = inspectLink.replacingOccurrences(of: "%20", with: " ")
        var components = URLComponents(string: baseURL)
        components?.queryItems = [URLQueryItem(name: "url", value: cleanLink)]
        
        guard let url = components?.url else {
            completion(.failure(URLError(.badURL)))
            return
        }
        
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        request.setValue("https://csgofloat.com", forHTTPHeaderField: "Origin")
        request.setValue("https://csgofloat.com", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data else { completion(.failure(URLError(.cannotDecodeContentData))); return }
            
            do {
                let result = try JSONDecoder().decode(FloatResponse.self, from: data)
                let floatVal = result.iteminfo.floatvalue
                self?.saveWear(link: inspectLink, wear: floatVal)
                completion(.success(floatVal))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
    
    struct FloatResponse: Decodable { let iteminfo: ItemInfo }
    struct ItemInfo: Decodable { let floatvalue: Double }
}

// MARK: - 独立价格服务
class InventoryPriceService {
    static let shared = InventoryPriceService()
    
    func getPredictedPrice(skin: Skin, wear: Double, isStatTrak: Bool) -> Double {
        return FuzzyPriceHelper.getPrice(skin: skin, wear: wear, isStatTrak: isStatTrak)
    }
    
    func getBasePrice(skin: Skin, wear: Double, isStatTrak: Bool) -> Double {
        return FuzzyPriceHelper.getBasePrice(skin: skin, wear: wear, isStatTrak: isStatTrak)
    }
}

// MARK: - 共享数据结构
struct SkinGroup: Identifiable {
    let id = UUID()
    let displayName: String
    let count: Int
    let exampleAsset: SteamAsset
    let matchedSkin: Skin?
    let basePrice: Double
}

// MARK: - 库存配平模型
struct InventoryItem: Identifiable, Equatable, Hashable {
    let id = UUID()
    var tradeItem: TradeItem
    let inspectLink: String?
    var isFetching: Bool = false
    var isExactWear: Bool = false
    
    var skin: Skin { tradeItem.skin }
    var wear: Double { tradeItem.wearValue }
    
    var estimatedValue: Double {
        InventoryPriceService.shared.getPredictedPrice(skin: skin, wear: wear, isStatTrak: tradeItem.isStatTrak)
    }
    
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: InventoryItem, rhs: InventoryItem) -> Bool {
        return lhs.id == rhs.id && lhs.wear == rhs.wear && lhs.isFetching == rhs.isFetching
    }
}

// MARK: - 优化结果配方
struct OptimizedRecipe: Identifiable {
    let id = UUID()
    let index: Int
    let mainItems: [InventoryItem]
    let fillerItems: [InventoryItem]
    
    var allItems: [InventoryItem] { mainItems + fillerItems }
    
    var avgWearFactor: Double {
        let factors = allItems.map { item -> Double in
            let minF = item.skin.min_float ?? 0.0
            let maxF = item.skin.max_float ?? 1.0
            let range = maxF - minF
            if range <= 0.0000001 { return 0 }
            let normalized = (item.wear - minF) / range
            return min(max(normalized, 0.0), 1.0)
        }
        return factors.isEmpty ? 0 : factors.reduce(0, +) / Double(factors.count)
    }
    
    var expectedOutputValue: Double {
        return calculateEV(debug: false)
    }
    
    func calculateEV(debug: Bool) -> Double {
        let items = allItems
        guard !items.isEmpty else { return 0 }
        
        let totalInputs = Double(items.count)
        let first = items[0]
        let inputLevel = first.skin.rarity?.level ?? 0
        let isStatTrak = first.tradeItem.isStatTrak
        let avgFactor = self.avgWearFactor
        
        var collectionCounts: [String: Int] = [:]
        for item in items {
            let colName = DataManager.shared.getCollectionName(for: item.skin)
            collectionCounts[colName, default: 0] += 1
        }
        
        var totalEV = 0.0
        
        for (colName, count) in collectionCounts {
            let outcomes = DataManager.shared.getSkinsByLevelSmart(collectionRawName: colName, level: inputLevel + 1)
            if outcomes.isEmpty { continue }
            let collectionProb = Double(count) / totalInputs
            let outcomeProb = collectionProb / Double(outcomes.count)
            for outcome in outcomes {
                let outputWear = TradeUpFormula.calculateOutcomeWear(avgInputFactor: avgFactor, outcomeSkin: outcome)
                let price = InventoryPriceService.shared.getBasePrice(skin: outcome, wear: outputWear, isStatTrak: isStatTrak)
                totalEV += price * outcomeProb
            }
        }
        return totalEV
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
    var nameToSkinMap: [String: Skin] = [:]
    
    var selectedMainSkin: Skin? = nil
    var selectedMainGroupName: String? = nil
    
    var selectedFillerSkin: Skin? = nil
    var selectedFillerGroupName: String? = nil
    
    var mainInventory: [InventoryItem] = []
    var fillerInventory: [InventoryItem] = []
    var cachedCompatibleFillers: [SteamAsset] = []
    
    var targetRecipeCount: Int = 3
    var mainsPerRecipe: Int = 2
    
    var optimizedRecipes: [OptimizedRecipe] = []
    var isCalculating = false
    var errorMessage: String? = nil
    
    var isFetchingWears = false
    var loadingProgress: String = ""
    var showWearFetchModal = false
    
    private var fetchTask: Task<Void, Never>? = nil
    
    var totalInventoryValue: Double {
        (mainInventory + fillerInventory).reduce(0) { $0 + $1.estimatedValue }
    }
    
    func fetchSteamInventory() {
        guard !steamId.isEmpty else { return }
        isFetchingSteam = true
        steamError = nil
        
        SteamInventoryService.shared.fetchInventory(steamId: steamId) { [weak self] result in
            DispatchQueue.main.async {
                self?.isFetchingSteam = false
                switch result {
                case .success(let assets):
                    if assets.isEmpty {
                        self?.steamError = "该账号库存为空或没有 CS2 可交易物品。"
                    } else {
                        self?.rawSteamInventory = self?.preFilterAssets(assets) ?? []
                        self?.preloadSkinMatches()
                    }
                case .failure(let error):
                    self?.steamError = error.localizedDescription
                }
            }
        }
    }
    
    private func preloadSkinMatches() {
        let assets = self.rawSteamInventory
        let allSkins = DataManager.shared.getAllSkins()
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let uniqueNames = Set(assets.map { $0.name })
            var newMap: [String: Skin] = [:]
            
            for name in uniqueNames {
                if let match = self.findBestMatch(steamName: name, in: allSkins) {
                    newMap[name] = match
                }
            }
            
            DispatchQueue.main.async {
                self.nameToSkinMap = newMap
            }
        }
    }
    
    func findBestMatch(steamName: String, in allSkins: [Skin]) -> Skin? {
        var cleanSteam = steamName
        let wears = [" (Factory New)", " (Minimal Wear)", " (Field-Tested)", " (Well-Worn)", " (Battle-Scarred)",
                     " (崭新出厂)", " (略有磨损)", " (久经沙场)", " (破损不堪)", " (战痕累累)"]
        for w in wears { cleanSteam = cleanSteam.replacingOccurrences(of: w, with: "") }
        let statTraks = ["StatTrak™ ", "StatTrak ", "（StatTrak™）", "(StatTrak™)"]
        for st in statTraks { cleanSteam = cleanSteam.replacingOccurrences(of: st, with: "") }
        
        let parts = cleanSteam.components(separatedBy: "|")
        let steamWeaponRaw = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        let steamPatternNoSpace = parts.count > 1 ? parts[1].replacingOccurrences(of: " ", with: "").lowercased() : ""
        let steamWeaponNoSpace = steamWeaponRaw.replacingOccurrences(of: " ", with: "")

        return allSkins.first { skin in
            let dbNameRaw = skin.name.lowercased()
            let dbNameNoSpace = dbNameRaw.replacingOccurrences(of: " ", with: "")
            if !steamPatternNoSpace.isEmpty {
                if !dbNameNoSpace.contains(steamPatternNoSpace) { return false }
                let fuzzyKeywords = ["usp":"usp", "cz75":"cz75", "glock":"glock", "galil":"galil", "famas":"famas", "desert":"desert", "deagle":"deagle", "m4a1":"m4a1", "m4a4":"m4a4"]
                for (key, _) in fuzzyKeywords { if steamWeaponRaw.contains(key) { return dbNameRaw.contains(key) } }
                return dbNameNoSpace.contains(steamWeaponNoSpace) || steamWeaponNoSpace.contains(dbNameNoSpace.components(separatedBy: "|").first ?? "")
            }
            return dbNameNoSpace == steamWeaponNoSpace || dbNameNoSpace.contains(steamWeaponNoSpace)
        }
    }
    
    private func preFilterAssets(_ assets: [SteamAsset]) -> [SteamAsset] {
        return assets.filter { asset in
            let name = asset.name
            if name.contains("纪念品") || name.contains("Souvenir") { return false }
            let invalidKeywords = ["匕首", "刀", "手套", "裹手", "徽章", "音乐盒", "探员"]
            for kw in invalidKeywords { if name.contains(kw) { return false } }
            return true
        }
    }
    
    func processInventoryForSelectedSkins() {
        fetchTask?.cancel()
        isFetchingWears = false
        loadingProgress = ""
        optimizedRecipes = []
        
        mainInventory = []
        fillerInventory = []
        
        if let mainSkin = selectedMainSkin, let groupName = selectedMainGroupName {
            mainInventory = filterAndConvert(skin: mainSkin, targetGroupName: groupName, from: rawSteamInventory)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                let fillers = self.filterCompatible(baseSkin: mainSkin, from: self.rawSteamInventory)
                DispatchQueue.main.async { self.cachedCompatibleFillers = fillers }
            }
        }
        
        if let fillerSkin = selectedFillerSkin, let groupName = selectedFillerGroupName {
            fillerInventory = filterAndConvert(skin: fillerSkin, targetGroupName: groupName, from: rawSteamInventory)
        }
    }
    
    private func filterAndConvert(skin: Skin, targetGroupName: String, from assets: [SteamAsset]) -> [InventoryItem] {
        return assets.filter { asset in
            return asset.name == targetGroupName
        }.map { asset in
            var wearVal: Double
            var isExact = false
            
            if let link = asset.inspectLink, let cached = InventoryWearFetchService.shared.getCachedWear(for: link) {
                wearVal = cached
                isExact = true
            } else {
                wearVal = Double.random(in:
                    max(skin.min_float ?? 0.0, inferWearRange(from: targetGroupName).lowerBound) ...
                    min(skin.max_float ?? 1.0, inferWearRange(from: targetGroupName).upperBound)
                )
            }
            let item = TradeItem(skin: skin, wearValue: wearVal, isStatTrak: asset.isStatTrak)
            return InventoryItem(tradeItem: item, inspectLink: asset.inspectLink, isExactWear: isExact)
        }
    }
    
    func inferWearRange(from name: String) -> ClosedRange<Double> {
        if name.contains("崭新") || name.contains("Factory New") { return 0.00...0.07 }
        if name.contains("略有") || name.contains("Minimal Wear") { return 0.07...0.15 }
        if name.contains("久经") || name.contains("Field-Tested") { return 0.15...0.38 }
        if name.contains("破损") || name.contains("Well-Worn") { return 0.38...0.45 }
        if name.contains("战痕") || name.contains("Battle-Scarred") { return 0.45...1.00 }
        return 0.00...1.00
    }
    
    func startOptimizationSequence() {
        errorMessage = nil
        let pendingMains = mainInventory.filter { !$0.isExactWear && $0.inspectLink != nil }
        let pendingFillers = fillerInventory.filter { !$0.isExactWear && $0.inspectLink != nil }
        let allPending = pendingMains + pendingFillers
        
        if allPending.isEmpty {
            runOptimization()
        } else {
            showWearFetchModal = true
            performWearFetch(items: allPending)
        }
    }
    
    private func performWearFetch(items: [InventoryItem]) {
        isFetchingWears = true
        let total = items.count
        loadingProgress = "正在获取磨损数据 (0/\(total))..."
        
        fetchTask = Task {
            var completed = 0
            for item in items {
                if Task.isCancelled { break }
                if let link = item.inspectLink { await fetchOneWear(item: item, link: link) }
                completed += 1
                await MainActor.run { self.loadingProgress = "正在获取磨损数据 (\(completed)/\(total))..." }
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            await MainActor.run {
                self.isFetchingWears = false
                self.showWearFetchModal = false
                self.runOptimization()
            }
        }
    }
    
    private func fetchOneWear(item: InventoryItem, link: String) async {
        return await withCheckedContinuation { continuation in
            InventoryWearFetchService.shared.fetchWear(inspectLink: link) { [weak self] result in
                Task { @MainActor in
                    if case .success(let val) = result { self?.updateItemWear(id: item.id, newWear: val) }
                    continuation.resume()
                }
            }
        }
    }
    
    @MainActor
    private func updateItemWear(id: UUID, newWear: Double) {
        if let idx = mainInventory.firstIndex(where: { $0.id == id }) {
            var newItem = mainInventory[idx]
            newItem.tradeItem.wearValue = newWear
            newItem.isExactWear = true
            mainInventory[idx] = newItem
        }
        if let idx = fillerInventory.firstIndex(where: { $0.id == id }) {
            var newItem = fillerInventory[idx]
            newItem.tradeItem.wearValue = newWear
            newItem.isExactWear = true
            fillerInventory[idx] = newItem
        }
    }
    
    func getInventoryForSelector(type: InventorySmartView.SheetType) -> [SteamAsset] {
        if type == .mainSelector {
            if let filler = selectedFillerSkin { return filterCompatible(baseSkin: filler, from: rawSteamInventory) }
            return rawSteamInventory
        } else {
            if let main = selectedMainSkin {
                if cachedCompatibleFillers.isEmpty { return filterCompatible(baseSkin: main, from: rawSteamInventory) }
                return cachedCompatibleFillers
            }
            return rawSteamInventory
        }
    }
    
    private func filterCompatible(baseSkin: Skin, from assets: [SteamAsset]) -> [SteamAsset] {
        let targetLevel = baseSkin.rarity?.level
        let isMainST = selectedMainGroupName?.contains("StatTrak") ?? false
        let hasMap = !nameToSkinMap.isEmpty
        let allSkins = hasMap ? [] : DataManager.shared.getAllSkins()
        
        return assets.filter { asset in
            if asset.isStatTrak != isMainST { return false }
            if hasMap, let matched = nameToSkinMap[asset.name] { return matched.rarity?.level == targetLevel }
            let cleanName = cleanSteamName(asset.name)
            if let matched = self.findBestMatch(steamName: cleanName, in: allSkins) { return matched.rarity?.level == targetLevel }
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
                let r1 = recipes[idx1]
                let r2 = recipes[idx2]
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
                if let best = finalRecipes.first {
                    _ = best.calculateEV(debug: true)
                }
            }
        }
    }
}

// MARK: - Steam 库存选择器 (UI保持不变)
struct SteamSkinSelectorView: View {
    let inventory: [SteamAsset]
    let onSelect: (Skin, String) -> Void
    @Environment(\.dismiss) var dismiss
    
    @State private var groups: [SkinGroup] = []
    @State private var isLoading = true
    @State private var debugInfo: String = ""
    @State private var retryAttempt = 0
    @State private var searchText = ""
    
    var filteredGroups: [SkinGroup] {
        if searchText.isEmpty { return groups }
        else { return groups.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) } }
    }
    
    var body: some View {
        NavigationStack {
            VStack {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在匹配本地数据库...").foregroundColor(.secondary)
                        if retryAttempt > 0 { Text("重试中 (\(retryAttempt))...").font(.caption2).foregroundColor(.orange) }
                        Text(debugInfo).font(.caption2).foregroundColor(.gray).padding()
                    }
                } else {
                    List(filteredGroups) { group in
                        Button(action: {
                            if let skin = group.matchedSkin { onSelect(skin, group.displayName); dismiss() }
                        }) {
                            HStack {
                                ZStack {
                                    CachedImage(url: URL(string: group.exampleAsset.iconUrl), transition: false)
                                        .frame(width: 60, height: 45)
                                }
                                .padding(2)
                                .background(RoundedRectangle(cornerRadius: 6).stroke(group.matchedSkin?.rarity?.swiftColor ?? .gray, lineWidth: 2))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.displayName).font(.subheadline).fontWeight(.medium).lineLimit(2)
                                    HStack {
                                        Text("库存: \(group.count)").font(.caption).padding(2).background(Color.blue.opacity(0.1)).cornerRadius(4).foregroundColor(.blue)
                                        if group.basePrice > 0 { Text("¥\(String(format: "%.2f", group.basePrice))").font(.caption).fontWeight(.bold).foregroundColor(.green) }
                                        else { Text("暂无报价").font(.caption).foregroundColor(.gray) }
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(.gray)
                            }
                        }.disabled(group.matchedSkin == nil)
                    }.searchable(text: $searchText, prompt: "搜索库存物品")
                }
            }
            .navigationTitle("选择库存物品")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onAppear { processGroups() }
        }
    }
    
    private func processGroups() {
        DispatchQueue.global(qos: .userInitiated).async {
            let allSkins = DataManager.shared.getAllSkins()
            let grouped = Dictionary(grouping: inventory) { $0.name }
            let computedGroups = grouped.map { (fullName, assets) -> SkinGroup in
                let matched = self.findBestMatch(steamName: fullName, in: allSkins)
                let example = assets.first!
                var dummyWear = 0.1
                if fullName.contains("崭新") { dummyWear = 0.01 }
                else if fullName.contains("略有") { dummyWear = 0.10 }
                else if fullName.contains("久经") { dummyWear = 0.20 }
                else if fullName.contains("破损") { dummyWear = 0.40 }
                else if fullName.contains("战痕") { dummyWear = 0.50 }
                
                var price = 0.0
                if let skin = matched { price = InventoryPriceService.shared.getBasePrice(skin: skin, wear: dummyWear, isStatTrak: example.isStatTrak) }
                else { price = DataManager.shared.getSmartPrice(for: fullName) }
                
                return SkinGroup(displayName: fullName, count: assets.count, exampleAsset: example, matchedSkin: matched, basePrice: price)
            }.sorted { $0.count > $1.count }
            
            DispatchQueue.main.async {
                self.groups = computedGroups
                self.isLoading = false
            }
        }
    }
    
    private func findBestMatch(steamName: String, in allSkins: [Skin]) -> Skin? {
        let vm = InventoryViewModel()
        return vm.findBestMatch(steamName: steamName, in: allSkins)
    }
}

// MARK: - InventorySmartView (主视图)
struct InventorySmartView: View {
    @State private var viewModel = InventoryViewModel()
    var tradeUpViewModel: TradeUpViewModel?
    @Binding var selectedTab: Int
    
    // 🔥 1. 注入全局库存管理器
    @EnvironmentObject var inventoryManager: InventoryManager
    
    init(tradeUpViewModel: TradeUpViewModel? = nil, selectedTab: Binding<Int> = .constant(1)) {
        self.tradeUpViewModel = tradeUpViewModel
        self._selectedTab = selectedTab
    }
    
    enum SheetType: Identifiable {
        case mainSelector, fillerSelector
        var id: Int { hashValue }
    }
    
    @State private var activeSheet: SheetType?
    @State private var showSteamIdAlert = false
    @State private var showOverwriteAlert = false
    @State private var pendingRecipe: OptimizedRecipe?
    
    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 24) {
                        // 1. 顶部操作区 (UI改进)
                        VStack(alignment: .leading, spacing: 12) {
                            // 标题 + 刷新大按钮
                            HStack {
                                Image(systemName: "person.icloud.fill").foregroundColor(.blue)
                                Text("Steam 库存连接").font(.headline)
                                Spacer()
                                // 加载按钮不随状态变动，保持"加载"或"刷新"语义，但不显示Loading
                                Button("加载 Steam 库存") { showSteamIdAlert = true }
                                    .font(.caption).buttonStyle(.borderedProminent)
                                    .disabled(viewModel.isFetchingSteam) // 加载时仅禁用
                            }
                            
                            // 下方增加：当前连接信息 + 快速刷新
                            if !viewModel.steamId.isEmpty {
                                Divider()
                                HStack {
                                    Text("当前连接:").font(.caption).foregroundColor(.secondary)
                                    // 显示 ID
                                    Text(viewModel.steamId)
                                        .font(.caption).fontWeight(.bold).monospaced()
                                    
                                    Spacer()
                                    
                                    // 静默刷新按钮
                                    Button(action: {
                                        // 触发静默刷新 (不弹窗，直接用当前 ID)
                                        viewModel.fetchSteamInventory()
                                    }) {
                                        if viewModel.isFetchingSteam {
                                            ProgressView().scaleEffect(0.7)
                                        } else {
                                            Image(systemName: "arrow.clockwise")
                                                .font(.caption)
                                                .foregroundColor(.blue)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            
                            if !viewModel.rawSteamInventory.isEmpty && !viewModel.isFetchingSteam {
                                Text("已加载 \(viewModel.rawSteamInventory.count) 件物品").font(.caption).foregroundColor(.green)
                            }
                            if let err = viewModel.steamError {
                                Text(err).font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
                            }
                            
                            // 🔥 新增：演示/调试清除缓存按钮
                            Divider()
                            Button(action: {
                                InventoryWearFetchService.shared.clearCache()
                                let gen = UIImpactFeedbackGenerator(style: .medium)
                                gen.impactOccurred()
                            }) {
                                HStack {
                                    Image(systemName: "trash")
                                    Text("清除磨损缓存 (演示用)")
                                }
                                .font(.caption)
                                .foregroundColor(.red.opacity(0.8))
                            }
                            .padding(.top, 4)
                        }
                        .padding().background(Color(UIColor.secondarySystemBackground)).cornerRadius(16).padding(.horizontal)
                        // 点击卡片背景也可触发弹窗
                        .onTapGesture { if viewModel.steamId.isEmpty { showSteamIdAlert = true } }

                        // ... (选择卡片)
                        if !viewModel.rawSteamInventory.isEmpty {
                            HStack(spacing: 16) {
                                InventorySelectionCard(title: "主料 (Main)", skin: viewModel.selectedMainSkin, subtitle: viewModel.selectedMainGroupName, count: viewModel.mainInventory.count, color: .orange, action: { activeSheet = .mainSelector })
                                InventorySelectionCard(title: "辅料 (Filler)", skin: viewModel.selectedFillerSkin, subtitle: viewModel.selectedFillerGroupName, count: viewModel.fillerInventory.count, color: .blue, action: { activeSheet = .fillerSelector })
                            }
                            .padding(.horizontal)
                        } else {
                            Button(action: { showSteamIdAlert = true }) {
                                VStack(spacing: 12) {
                                    Image(systemName: "arrow.up.circle").font(.largeTitle)
                                    Text("请先点击上方按钮\n连接 Steam 并读取数据").multilineTextAlignment(.center)
                                }
                                .foregroundColor(.secondary).frame(maxWidth: .infinity).padding(.vertical, 40)
                                .background(Color(UIColor.secondarySystemBackground).opacity(0.5)).cornerRadius(16).padding(.horizontal)
                            }
                        }
                        
                        // ... (计算控制区)
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
                                Button(action: { withAnimation { viewModel.startOptimizationSequence() } }) {
                                    HStack {
                                        if viewModel.isCalculating { ProgressView().tint(.white) } else { Image(systemName: "wand.and.stars") }
                                        Text(viewModel.isCalculating ? "计算中..." : "开始智能分配")
                                    }
                                    .font(.headline).foregroundColor(.white).frame(maxWidth: .infinity).frame(height: 54)
                                    .background(Color.blue).cornerRadius(16)
                                }
                                .disabled(viewModel.isCalculating || viewModel.isFetchingWears)
                                if let err = viewModel.errorMessage { Text(err).font(.caption).foregroundColor(.red) }
                            }
                            .padding(20).background(Color(UIColor.secondarySystemBackground)).cornerRadius(20).padding(.horizontal)
                            
                            if !viewModel.optimizedRecipes.isEmpty {
                                VStack(alignment: .leading, spacing: 16) {
                                    Text("分配方案").font(.title2).bold().padding(.horizontal).foregroundColor(.orange)
                                    ForEach(viewModel.optimizedRecipes) { recipe in
                                        InventoryRecipeResultCard(recipe: recipe)
                                            .onTapGesture { handleRecipeTap(recipe) }
                                    }
                                }
                                .padding(.bottom, 50).transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                    }
                }
                
                // ... (弹窗)
                if viewModel.showWearFetchModal {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: 20) {
                        ProgressView().scaleEffect(1.2)
                        Text("正在从 CSGOFloat 获取磨损...").font(.headline)
                        Text(viewModel.loadingProgress).font(.subheadline).foregroundColor(.secondary)
                        Button("取消") { viewModel.isFetchingWears = false; viewModel.showWearFetchModal = false }.foregroundColor(.red).padding(.top, 5)
                    }
                    .padding(30).background(Color(UIColor.systemBackground)).cornerRadius(16).shadow(radius: 20).padding(.horizontal, 40)
                }
            }
            .navigationTitle("库存配平")
            // ... (Sheets 和 Alerts)
            .sheet(item: $activeSheet) { type in
                SteamSkinSelectorView(inventory: viewModel.getInventoryForSelector(type: type), onSelect: { skin, groupName in
                    if type == .mainSelector {
                        viewModel.selectedMainSkin = skin; viewModel.selectedMainGroupName = groupName
                        if let filler = viewModel.selectedFillerSkin, filler.rarity?.level != skin.rarity?.level { viewModel.selectedFillerSkin = nil; viewModel.selectedFillerGroupName = nil }
                    } else { viewModel.selectedFillerSkin = skin; viewModel.selectedFillerGroupName = groupName }
                    viewModel.processInventoryForSelectedSkins()
                })
            }
            .alert("连接 Steam 库存", isPresented: $showSteamIdAlert) {
                TextField("Steam ID (64位)", text: $viewModel.steamId)
                Button("确定") { viewModel.fetchSteamInventory() }
                Button("取消", role: .cancel) { }
            } message: { Text("输入您的 64 位 Steam ID 以读取公开库存。") }
            .alert("覆盖未保存的更改？", isPresented: $showOverwriteAlert) {
                Button("取消", role: .cancel) { pendingRecipe = nil }
                Button("丢弃并加载", role: .destructive) { if let recipe = pendingRecipe { loadOptimizedRecipe(recipe) } }
            } message: { Text("“自定义炼金”中有未保存的草稿。加载新配方将覆盖当前内容。") }
            
            // 🔥 2. 监听数据变化并同步给 Tab 1
            .onChange(of: viewModel.nameToSkinMap) { _, newMap in
                syncInventoryToGlobal(assets: viewModel.rawSteamInventory, map: newMap)
            }
            .onChange(of: viewModel.isFetchingSteam) { _, newValue in
                inventoryManager.isLoading = newValue
            }
            
            // 首次进入自动尝试加载
            .onAppear {
                if viewModel.rawSteamInventory.isEmpty && !viewModel.steamId.isEmpty {
                    // viewModel.fetchSteamInventory() // 可以选择自动加载
                }
            }
        }
    }
    
    // 🔥 3. 同步逻辑实现
    private func syncInventoryToGlobal(assets: [SteamAsset], map: [String: Skin]) {
        guard !assets.isEmpty, !map.isEmpty else { return }
        
        print("🔄 [InventorySmartView] 正在同步 \(assets.count) 件物品到全局管理器...")
        
        DispatchQueue.global(qos: .userInitiated).async {
            var tradeItems: [TradeItem] = []
            
            for asset in assets {
                if let skin = map[asset.name] {
                    var wear: Double = 0.0
                    if let link = asset.inspectLink, let cached = InventoryWearFetchService.shared.getCachedWear(for: link) {
                        wear = cached
                    } else {
                        let range = viewModel.inferWearRange(from: asset.name)
                        wear = (range.lowerBound + range.upperBound) / 2.0
                    }
                    
                    let item = TradeItem(skin: skin, wearValue: wear, isStatTrak: asset.isStatTrak, inspectLink: asset.inspectLink)
                    tradeItems.append(item)
                }
            }
            
            DispatchQueue.main.async {
                print("✅ [InventorySmartView] 同步完成，共转换 \(tradeItems.count) 个有效物品")
                self.inventoryManager.updateData(tradeItems)
            }
        }
    }
    
    private func handleRecipeTap(_ recipe: OptimizedRecipe) {
        guard let vm = tradeUpViewModel else { return }
        if vm.filledCount == 0 || (vm.currentEditingRecipeId != nil && !vm.hasUnsavedChanges) { loadOptimizedRecipe(recipe); return }
        pendingRecipe = recipe; showOverwriteAlert = true
    }
    
    private func loadOptimizedRecipe(_ recipe: OptimizedRecipe) {
        guard let vm = tradeUpViewModel else { return }
        vm.clearAll()
        let allItems = recipe.allItems
        for (index, invItem) in allItems.enumerated() { if index < 10 { vm.slots[index] = invItem.tradeItem } }
        vm.currentEditingRecipeId = nil; vm.currentEditingRecipeTitle = "库存配平方案 #\(recipe.index)"
        selectedTab = 0
    }
}

// MARK: - UI 组件 (Helper Components)

// 🔥 新增：本地专用的 Grid 样式组件
struct InventoryGridItemView: View {
    let item: TradeItem
    var onSelect: () -> Void = {}
    
    // 获取纯净的磨损名称 (例如 "略有磨损")
    var simpleWearName: String {
        for wear in Wear.allCases {
            if wear.range.contains(item.wearValue) { return wear.rawValue }
        }
        return "未知"
    }
    
    var wearColor: Color {
        if item.wearValue < 0.07 { return Color(hex: "#2ebf58")! }
        if item.wearValue < 0.15 { return Color(hex: "#87c34a")! }
        if item.wearValue < 0.38 { return Color(hex: "#eabd38")! }
        if item.wearValue < 0.45 { return Color(hex: "#eb922a")! }
        return Color(hex: "#e24e4d")!
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(UIColor.secondarySystemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
            
            VStack(spacing: 4) {
                CachedImage(url: item.skin.imageURL, transition: false)
                    .frame(height: 50)
                    .padding(.top, 8)
                
                VStack(spacing: 2) {
                    Text(item.skin.baseName)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .foregroundColor(.primary)
                    
                    Text(simpleWearName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(wearColor)
                    
                    Text(String(format: "%.6f", item.wearValue))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 8)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(item.skin.rarity?.swiftColor ?? .gray.opacity(0.3), lineWidth: 1.5)
            )
        }
        .frame(height: 130)
        .onTapGesture { onSelect() }
    }
}

// 🔥 修复：强制刷新图片的 InventorySelectionCard
struct InventorySelectionCard: View {
    let title: String
    let skin: Skin?
    var subtitle: String? = nil
    let count: Int
    let color: Color
    let action: () -> Void
    
    // Helper function to determine wear color
    func getWearColor(_ text: String) -> Color {
        if text.contains("崭新") || text.contains("Factory New") { return Color(hex: "#2ebf58") ?? .green }
        if text.contains("略有") || text.contains("Minimal Wear") { return Color(hex: "#87c34a") ?? .green }
        if text.contains("久经") || text.contains("Field-Tested") { return Color(hex: "#eabd38") ?? .yellow }
        if text.contains("破损") || text.contains("Well-Worn") { return Color(hex: "#eb922a") ?? .orange }
        if text.contains("战痕") || text.contains("Battle-Scarred") { return Color(hex: "#e24e4d") ?? .red }
        return .secondary
    }
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Text(title).font(.subheadline).fontWeight(.bold).foregroundColor(color).frame(maxWidth: .infinity, alignment: .leading)
                
                if let currentSkin = skin {
                    // 🔥 Fix 1: 添加 .id(currentSkin.id) 强制刷新图片
                    CachedImage(url: currentSkin.imageURL, transition: false)
                        .frame(height: 50)
                        .id(currentSkin.id)
                    
                    VStack(spacing: 2) {
                        Text(currentSkin.baseName).font(.caption).lineLimit(1).foregroundColor(.primary)
                        
                        // 🔥 Fix 2: 简化副标题，去除冗余枪名
                        if let sub = subtitle {
                            // 简单的文本处理：尝试去除 baseName
                            let cleanSub = sub.replacingOccurrences(of: currentSkin.baseName, with: "")
                                              .replacingOccurrences(of: "|", with: "")
                                              .trimmingCharacters(in: CharacterSet(charactersIn: " ()（）"))
                            
                            if !cleanSub.isEmpty {
                                Text(cleanSub)
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(getWearColor(sub)) // Fix: Add color
                                    .lineLimit(1)
                            }
                        }
                    }
                    Text("库存: \(count)").font(.caption2).padding(.horizontal, 8).padding(.vertical, 2).background(Color.secondary.opacity(0.2)).cornerRadius(4).foregroundColor(.primary)
                } else {
                    Image(systemName: "plus").font(.largeTitle).foregroundColor(Color.gray.opacity(0.3)).frame(height: 60)
                    Text("点击选择").font(.caption).foregroundColor(.secondary)
                }
            }
            .padding().frame(height: 160).frame(maxWidth: .infinity).background(Color(UIColor.systemBackground)).cornerRadius(16).shadow(color: color.opacity(0.1), radius: 5, x: 0, y: 2).overlay(RoundedRectangle(cornerRadius: 16).stroke(skin != nil ? color : Color.gray.opacity(0.2), lineWidth: 2))
        }
    }
}

struct InventoryRecipeResultCard: View {
    let recipe: OptimizedRecipe
    var roiColor: Color { recipe.roi > 0 ? .red : (recipe.roi < -0.2 ? .gray : .green) }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("配方 #\(recipe.index)").font(.headline).foregroundColor(.white).padding(.horizontal, 12).padding(.vertical, 6).background(roiColor).cornerRadius(8)
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
                    Text("平均变形磨损").font(.caption).foregroundColor(.secondary)
                    Text(String(format: "%.6f", recipe.avgWearFactor)).font(.system(size: 12, design: .monospaced)).fontWeight(.medium)
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
            ZStack(alignment: .topTrailing) {
                CachedImage(url: item.skin.imageURL, transition: false).frame(width: 36, height: 28)
                if item.isFetching { ProgressView().scaleEffect(0.4).offset(x: 4, y: -4) }
                else if item.isExactWear { Image(systemName: "checkmark.circle.fill").font(.system(size: 8)).foregroundColor(.green).background(Color.white.clipShape(Circle())).offset(x: 2, y: -2) }
            }
            Rectangle().fill(wearColor).frame(height: 2)
            Text(String(format: "%.3f", item.wear)).font(.system(size: 7)).foregroundColor(.secondary).padding(.top, 2)
        }
        .frame(width: 40).padding(4).background(Color(UIColor.secondarySystemBackground)).cornerRadius(4)
    }
}
