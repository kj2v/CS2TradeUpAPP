import SwiftUI

// MARK: - 价格趋势拟合服务
class PriceCurveService {
    static let shared = PriceCurveService()
    
    func getPredictedPrice(skin: Skin, wear: Double, isStatTrak: Bool) -> Double {
        let searchName = skin.getSearchName(isStatTrak: isStatTrak, wear: wear)
        let basePrice = DataManager.shared.getSmartPrice(for: searchName)
        if basePrice <= 0 { return 0 }
        
        if let range = Wear.allCases.first(where: { $0.range.contains(wear) })?.range {
            let relativePos = (wear - range.lowerBound) / (range.upperBound - range.lowerBound)
            let premiumFactor = 1.0 + (1.0 - relativePos) * 0.05
            return basePrice * premiumFactor
        }
        return basePrice
    }
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
    var selectedFillerSkin: Skin? = nil
    
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
                        self?.rawSteamInventory = assets
                    }
                case .failure(let error):
                    self?.steamError = error.localizedDescription
                }
            }
        }
    }
    
    func processInventoryForSelectedSkins() {
        mainInventory = []
        fillerInventory = []
        
        if let mainSkin = selectedMainSkin {
            mainInventory = filterAndConvert(skin: mainSkin, from: rawSteamInventory)
        }
        
        if let fillerSkin = selectedFillerSkin {
            fillerInventory = filterAndConvert(skin: fillerSkin, from: rawSteamInventory)
        }
        
        optimizedRecipes = []
    }
    
    private func filterAndConvert(skin: Skin, from assets: [SteamAsset]) -> [InventoryItem] {
        let targetBase = skin.baseName
        
        return assets.filter { asset in
            let assetBase = cleanSteamName(asset.name)
            // 增加完全相等或包含的判断，提高命中率
            return assetBase == targetBase || assetBase.contains(targetBase) || targetBase.contains(assetBase)
        }.map { asset in
            let minF = skin.min_float ?? 0.0
            let maxF = skin.max_float ?? 1.0
            // 模拟磨损
            let simulatedWear = asset.wear ?? Double.random(in: min(0.01, minF)...min(0.25, maxF))
            
            let item = TradeItem(skin: skin, wearValue: simulatedWear, isStatTrak: asset.isStatTrak)
            return InventoryItem(tradeItem: item)
        }
    }
    
    // 辅助：清洗 Steam API 返回的名字 (中英文增强版)
    func cleanSteamName(_ name: String) -> String {
        var cleaned = name
        
        // 1. 移除磨损后缀 (中英文)
        let wears = [
            " (Factory New)", " (Minimal Wear)", " (Field-Tested)", " (Well-Worn)", " (Battle-Scarred)",
            " (崭新出厂)", " (略有磨损)", " (久经沙场)", " (破损不堪)", " (战痕累累)"
        ]
        for w in wears {
            cleaned = cleaned.replacingOccurrences(of: w, with: "")
        }
        
        // 2. 移除 StatTrak 前缀 (多种格式)
        let statTraks = ["StatTrak™ ", "StatTrak ", "（StatTrak™）", "(StatTrak™)"]
        for st in statTraks {
            cleaned = cleaned.replacingOccurrences(of: st, with: "")
        }
        
        return cleaned.trimmingCharacters(in: .whitespaces)
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

// MARK: - Steam 库存选择器
struct SteamSkinSelectorView: View {
    let inventory: [SteamAsset]
    let onSelect: (Skin) -> Void
    @Environment(\.dismiss) var dismiss
    
    struct SkinGroup: Identifiable {
        let id = UUID()
        let baseName: String
        let count: Int
        let exampleAsset: SteamAsset
        let matchedSkin: Skin?
    }
    
    @State private var groups: [SkinGroup] = []
    
    var body: some View {
        NavigationStack {
            List(groups) { group in
                Button(action: {
                    if let skin = group.matchedSkin {
                        onSelect(skin)
                        dismiss()
                    }
                }) {
                    HStack {
                        CachedImage(url: URL(string: group.exampleAsset.iconUrl), transition: false)
                            .frame(width: 60, height: 45)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.baseName)
                                .font(.headline)
                                .foregroundColor(.primary)
                            
                            HStack {
                                Text("库存: \(group.count)")
                                    .font(.subheadline)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(4)
                                    .foregroundColor(.blue)
                                
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
        // 关键：在这里也使用增强版的清洗逻辑
        let grouped = Dictionary(grouping: inventory) { asset -> String in
            // 使用内联清洗逻辑，保持与 ViewModel 一致
            var name = asset.name
            let wears = [" (Factory New)", " (Minimal Wear)", " (Field-Tested)", " (Well-Worn)", " (Battle-Scarred)",
                         " (崭新出厂)", " (略有磨损)", " (久经沙场)", " (破损不堪)", " (战痕累累)"]
            for w in wears { name = name.replacingOccurrences(of: w, with: "") }
            
            let statTraks = ["StatTrak™ ", "StatTrak ", "（StatTrak™）", "(StatTrak™)"]
            for st in statTraks { name = name.replacingOccurrences(of: st, with: "") }
            
            return name.trimmingCharacters(in: .whitespaces)
        }
        
        let allSkins = DataManager.shared.getAllSkins()
        
        self.groups = grouped.map { (baseName, assets) in
            // 匹配逻辑：尝试精确匹配或包含匹配
            // 注意：中文环境下，Skin 对象的 name 也是中文（因为 skins.json 是中文）
            let matched = allSkins.first { skin in
                // 直接比较清洗后的名字
                // 或者用 skin.baseName (它内部也有清洗逻辑，但可能不完全)
                let skinBase = skin.baseName
                return skinBase == baseName || skin.name.contains(baseName) || baseName.contains(skinBase)
            }
            
            return SkinGroup(
                baseName: baseName,
                count: assets.count,
                exampleAsset: assets.first!,
                matchedSkin: matched
            )
        }.sorted { $0.count > $1.count }
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
                                count: viewModel.mainInventory.count,
                                color: .orange,
                                action: { activeSheet = .mainSelector }
                            )
                            
                            SelectionCard(
                                title: "辅料 (Filler)",
                                skin: viewModel.selectedFillerSkin,
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
                                Text("分配方案").font(.title2).bold().padding(.horizontal).foregroundColor(.orange)
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
                    inventory: viewModel.rawSteamInventory,
                    onSelect: { skin in
                        if type == .mainSelector {
                            viewModel.selectedMainSkin = skin
                        } else {
                            viewModel.selectedFillerSkin = skin
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

// MARK: - UI 组件 (保持不变)
struct SelectionCard: View {
    let title: String
    let skin: Skin?
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
            CachedImage(url: currentSkin.imageURL, transition: false).frame(height: 60)
            Text(currentSkin.baseName).font(.caption).lineLimit(1).foregroundColor(.primary)
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
