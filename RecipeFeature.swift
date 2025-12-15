import SwiftUI
import Combine // 🟢 关键修复：导入 Combine 框架以支持 ObservableObject 和 @Published

// MARK: - 1. 配方数据模型

struct SavedRecipe: Identifiable, Codable {
    let id: UUID
    let title: String
    let items: [TradeItem]
    let createdAt: Date
    
    // 预计算的缓存字段
    var cachedCost: Double?
    var cachedEV: Double?
    var cachedROI: Double?
    
    // 最佳产物展示信息
    var bestOutcomeImageURL: URL?
    var bestOutcomeRarityColor: String? // 保存 Hex 颜色字符串
    var bestOutcomeProb: Double?
    var bestOutcomeWearName: String?
    
    // 基础初始化
    init(title: String, items: [TradeItem]) {
        self.id = UUID()
        self.title = title
        self.items = items
        self.createdAt = Date()
        self.calculateStats()
    }
    
    // 全能初始化（用于保存计算结果）
    init(title: String, items: [TradeItem], ev: Double, roi: Double, bestOutcome: (Skin, Double, String)?) {
        self.id = UUID()
        self.title = title
        self.items = items
        self.createdAt = Date()
        
        self.cachedCost = items.compactMap { $0.price }.reduce(0, +)
        
        if items.count == 10 {
            self.cachedEV = ev
            self.cachedROI = roi
            if let (skin, prob, wear) = bestOutcome {
                self.bestOutcomeImageURL = skin.imageURL
                // 确保获取颜色字符串，如果没有则给个默认灰色
                self.bestOutcomeRarityColor = skin.rarity?.color ?? "#808080"
                self.bestOutcomeProb = prob
                self.bestOutcomeWearName = wear
            }
        }
    }
    
    // 内部计算统计数据（兼容旧调用）
    mutating func calculateStats() {
        self.cachedCost = items.compactMap { $0.price }.reduce(0, +)
        // 注意：不完整的计算逻辑这里略过，主要依赖 ViewModel 传入的计算结果
    }
}

// MARK: - 2. 配方管理器 (单例)
class RecipeManager: ObservableObject {
    static let shared = RecipeManager()
    
    @Published var recipes: [SavedRecipe] = []
    
    private let saveKey = "SavedRecipes_V1"
    
    init() {
        loadRecipes()
    }
    
    func saveRecipe(_ recipe: SavedRecipe) {
        // 将新配方插入到数组开头
        recipes.insert(recipe, at: 0)
        persist()
    }
    
    func deleteRecipe(at offsets: IndexSet) {
        recipes.remove(atOffsets: offsets)
        persist()
    }
    
    private func persist() {
        if let encoded = try? JSONEncoder().encode(recipes) {
            UserDefaults.standard.set(encoded, forKey: saveKey)
        }
    }
    
    private func loadRecipes() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let decoded = try? JSONDecoder().decode([SavedRecipe].self, from: data) {
            recipes = decoded
        }
    }
}

// MARK: - 3. 模块三：我的配方视图
struct MyRecipesView: View {
    @StateObject var manager = RecipeManager.shared
    @State private var sortOption: SortOption = .dateDesc
    
    enum SortOption: String, CaseIterable {
        case dateDesc = "最新创建"
        case costAsc = "成本 (低到高)"
        case costDesc = "成本 (高到低)"
        case roiDesc = "ROI (高到低)"
        case evDesc = "期望 (高到低)"
    }
    
    var sortedRecipes: [SavedRecipe] {
        let list = manager.recipes
        
        return list.sorted { r1, r2 in
            let isComplete1 = r1.items.count == 10
            let isComplete2 = r2.items.count == 10
            
            // 逻辑：不完整的配方始终置顶
            if isComplete1 != isComplete2 {
                return !isComplete1
            }
            
            switch sortOption {
            case .dateDesc: return r1.createdAt > r2.createdAt
            case .costAsc: return (r1.cachedCost ?? 0) < (r2.cachedCost ?? 0)
            case .costDesc: return (r1.cachedCost ?? 0) > (r2.cachedCost ?? 0)
            case .roiDesc: return (r1.cachedROI ?? -999) > (r2.cachedROI ?? -999)
            case .evDesc: return (r1.cachedEV ?? 0) > (r2.cachedEV ?? 0)
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack {
                // 排序栏
                HStack {
                    Text("排序方式:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("排序", selection: $sortOption) {
                        ForEach(SortOption.allCases, id: \.self) { opt in
                            Text(opt.rawValue).tag(opt)
                        }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)
                
                if sortedRecipes.isEmpty {
                    ContentUnavailableView("暂无配方", systemImage: "doc.text.magnifyingglass", description: Text("在“自定义炼金”中添加并保存你的配方"))
                } else {
                    List {
                        ForEach(sortedRecipes) { recipe in
                            RecipeRowView(recipe: recipe)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                        .onDelete(perform: manager.deleteRecipe)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("我的配方")
            .background(Color(UIColor.systemGroupedBackground))
        }
    }
}

// MARK: - 4. 配方列表行视图
struct RecipeRowView: View {
    let recipe: SavedRecipe
    
    var isComplete: Bool { recipe.items.count == 10 }
    
    var borderColor: Color {
        if let hex = recipe.bestOutcomeRarityColor {
            return Color(hex: hex) ?? .gray
        }
        return .gray
    }
    
    var roiColor: Color {
        guard let roi = recipe.cachedROI else { return .gray }
        return roi > 0 ? .red : (roi < 0 ? .green : .gray)
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // 左侧：图片区域
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(UIColor.secondarySystemBackground))
                
                if isComplete, let url = recipe.bestOutcomeImageURL {
                    CachedImage(url: url, transition: false)
                        .padding(4)
                } else {
                    // 待完善占位图
                    VStack(spacing: 4) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.title2)
                            .foregroundColor(.gray)
                        Text("待完善")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                // 仅在完整时显示覆盖信息
                if isComplete {
                    // 左上角：概率
                    if let prob = recipe.bestOutcomeProb {
                        Text(String(format: "%.1f%%", prob * 100))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(2)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(4)
                            .padding(4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    
                    // 左下角：外观
                    if let wear = recipe.bestOutcomeWearName {
                        Text(wear)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.8), radius: 1)
                            .padding(4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                }
            }
            .frame(width: 100, height: 80)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isComplete ? borderColor : Color.gray.opacity(0.3), lineWidth: 2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            // 右侧：信息区域
            VStack(alignment: .leading, spacing: 4) {
                // 标题
                Text(recipe.title)
                    .font(.headline)
                    .lineLimit(1)
                
                // 成本小标题
                if let cost = recipe.cachedCost {
                    Text("成本: ¥" + String(format: "%.2f", cost))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // 底部数据 (仅完整时显示)
                if isComplete {
                    HStack {
                        // 期望
                        if let ev = recipe.cachedEV {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("期望")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Text("¥" + String(format: "%.2f", ev))
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.primary)
                            }
                        }
                        
                        Spacer()
                        
                        // ROI
                        if let roi = recipe.cachedROI {
                            VStack(alignment: .trailing, spacing: 0) {
                                Text("ROI")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Text((roi > 0 ? "+" : "") + String(format: "%.1f%%", roi * 100))
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(roiColor)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(10)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
    }
}
