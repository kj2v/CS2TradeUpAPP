import SwiftUI

// MARK: - 数据模型：保存的配方
struct SavedRecipe: Identifiable, Codable {
    let id: UUID
    let title: String
    let date: Date
    let items: [TradeItem]
    
    // 简略的统计信息，用于列表展示
    let ev: Double
    let roi: Double
    let bestOutcome: BestOutcomeInfo? // 最佳产物预览
    
    // 标记配方是否完整 (10个)
    var isComplete: Bool { items.count == 10 }
    
    struct BestOutcomeInfo: Codable {
        // 存储完整的 Skin 对象以便获取品质颜色等信息
        let skin: Skin
        let probability: Double
        let wearName: String
    }
    
    init(id: UUID = UUID(), title: String, date: Date = Date(), items: [TradeItem], ev: Double, roi: Double, bestOutcome: (Skin, Double, String)?) {
        self.id = id
        self.title = title
        self.date = date
        self.items = items
        self.ev = ev
        self.roi = roi
        if let (skin, prob, wear) = bestOutcome {
            self.bestOutcome = BestOutcomeInfo(skin: skin, probability: prob, wearName: wear)
        } else {
            self.bestOutcome = nil
        }
    }
}

// MARK: - 配方管理器 (数据持久化)
@Observable
class RecipeManager {
    static let shared = RecipeManager()
    var recipes: [SavedRecipe] = []
    
    private let saveKey = "saved_recipes_v2" // 更新 key 以避免与旧数据结构冲突
    
    init() {
        loadRecipes()
    }
    
    func saveRecipe(_ recipe: SavedRecipe) {
        // 检查是否已存在同名或同ID的配方，如果有则更新，没有则新增
        if let index = recipes.firstIndex(where: { $0.id == recipe.id }) {
            recipes[index] = recipe
        } else {
            recipes.insert(recipe, at: 0) // 新配方插在最前面
        }
        persist()
    }
    
    func deleteRecipe(id: UUID) {
        recipes.removeAll { $0.id == id }
        persist()
    }
    
    private func persist() {
        if let data = try? JSONEncoder().encode(recipes) {
            UserDefaults.standard.set(data, forKey: saveKey)
        }
    }
    
    private func loadRecipes() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let decoded = try? JSONDecoder().decode([SavedRecipe].self, from: data) {
            recipes = decoded
        }
    }
}

// MARK: - 我的配方视图
struct MyRecipesView: View {
    // 接收 ViewModel 和 Tab 绑定，用于加载数据和跳转
    var viewModel: TradeUpViewModel?
    @Binding var selectedTab: Int
    
    var recipeManager = RecipeManager.shared
    @State private var selectedFilter = 0 // 0: 全部, 1: 完整, 2: 草稿
    
    // 用于处理覆盖确认弹窗
    @State private var showOverwriteAlert = false
    @State private var pendingRecipeToLoad: SavedRecipe?
    
    // 提供默认初始化方法，方便预览或其他不传参的调用
    init(viewModel: TradeUpViewModel? = nil, selectedTab: Binding<Int> = .constant(2)) {
        self.viewModel = viewModel
        self._selectedTab = selectedTab
    }
    
    var filteredRecipes: [SavedRecipe] {
        switch selectedFilter {
        case 1: return recipeManager.recipes.filter { $0.isComplete }
        case 2: return recipeManager.recipes.filter { !$0.isComplete }
        default: return recipeManager.recipes
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack {
                // 筛选器
                Picker("筛选", selection: $selectedFilter) {
                    Text("全部").tag(0)
                    Text("完整配方").tag(1)
                    Text("草稿").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()
                
                if filteredRecipes.isEmpty {
                    // 空状态提示
                    VStack(spacing: 20) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                        Text("暂无配方")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    // 配方列表
                    List {
                        ForEach(filteredRecipes) { recipe in
                            RecipeRow(recipe: recipe)
                                .contentShape(Rectangle()) // 确保整个区域（包括空白处）都可点击
                                .onTapGesture {
                                    handleRecipeTap(recipe)
                                }
                        }
                        .onDelete(perform: deleteRecipe) // 左滑删除功能
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("我的配方")
            .navigationBarTitleDisplayMode(.inline)
            // 覆盖确认弹窗
            .alert("覆盖当前配方？", isPresented: $showOverwriteAlert) {
                Button("取消", role: .cancel) {
                    pendingRecipeToLoad = nil
                }
                Button("覆盖", role: .destructive) {
                    if let recipe = pendingRecipeToLoad {
                        loadRecipeDirectly(recipe)
                    }
                }
            } message: {
                Text("“自定义炼金”中已有正在编辑的内容，加载新配方将覆盖当前未保存的更改。")
            }
        }
    }
    
    // MARK: - 逻辑处理
    
    // 处理列表项点击
    func handleRecipeTap(_ recipe: SavedRecipe) {
        guard let vm = viewModel else { return }
        
        // 检查当前是否有正在编辑的内容
        if vm.filledCount == 0 {
            // 如果是空的，直接加载
            loadRecipeDirectly(recipe)
        } else {
            // 如果有内容，弹出确认框
            pendingRecipeToLoad = recipe
            showOverwriteAlert = true
        }
    }
    
    // 执行加载并跳转
    func loadRecipeDirectly(_ recipe: SavedRecipe) {
        guard let vm = viewModel else { return }
        
        // 1. 重置当前 ViewModel 的数据
        vm.slots = Array(repeating: nil, count: 10)
        vm.resetResult()
        
        // 2. 填充新配方的数据
        // 确保只取前10个（理论上保存时最多也就是10个）
        let itemsToLoad = Array(recipe.items.prefix(10))
        for (index, item) in itemsToLoad.enumerated() {
            vm.slots[index] = item
        }
        
        // 关键：设置当前正在编辑的 ID，以便后续保存时覆盖而非新建
        // 注意：这里需要 TradeUpViewModel 有 currentRecipeId 属性，后续需要在 ContentView 中补充
        // vm.currentRecipeId = recipe.id
        // 临时使用扩展属性模拟，或者假设外部会处理
        vm.currentEditingRecipeId = recipe.id
        vm.currentEditingRecipeTitle = recipe.title
        
        // 3. 跳转到第一个 Tab ("自定义炼金")
        selectedTab = 0
    }
    
    // 处理删除操作
    func deleteRecipe(at offsets: IndexSet) {
        // 因为列表是经过筛选的，所以不能直接用 offsets 删除原始数组
        // 需要先找到对应配方的 ID
        let idsToDelete = offsets.map { filteredRecipes[$0].id }
        for id in idsToDelete {
            recipeManager.deleteRecipe(id: id)
        }
    }
}

// MARK: - 配方列表项视图
struct RecipeRow: View {
    let recipe: SavedRecipe
    
    var body: some View {
        HStack(spacing: 12) {
            // 左侧：配方预览图（最佳产出或首个素材）
            ZStack {
                // 背景
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(UIColor.secondarySystemBackground))
                
                if let best = recipe.bestOutcome {
                    // 显示图片
                    CachedImage(url: best.skin.imageURL, transition: false)
                        .frame(width: 70, height: 56) // 加大图片尺寸
                    
                    // 左上角：概率
                    VStack {
                        HStack {
                            Text(String(format: "%.1f%%", best.probability * 100))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(2)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(4)
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(4)
                    
                    // 左下角：外观
                    VStack {
                        Spacer()
                        HStack {
                            Text(best.wearName)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(wearColor(for: best.wearName))
                                .padding(2)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(4)
                            Spacer()
                        }
                    }
                    .padding(4)
                    
                } else if let firstItem = recipe.items.first {
                    // 如果没有计算结果，显示第一个素材作为封面
                    CachedImage(url: firstItem.skin.imageURL, transition: false)
                        .frame(width: 70, height: 56)
                } else {
                    Image(systemName: "hammer")
                        .foregroundColor(.gray)
                        .font(.title)
                }
            }
            .frame(width: 80, height: 64) // 加大整体卡片尺寸
            // 添加品质颜色的边框
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(recipe.bestOutcome?.skin.rarity?.swiftColor ?? Color.gray.opacity(0.3), lineWidth: 2)
            )
            
            // 中间：标题与信息
            VStack(alignment: .leading, spacing: 4) {
                Text(recipe.title)
                    .font(.headline)
                    .lineLimit(1)
                
                // 修改：ROI 和 EV 分两行显示
                if recipe.isComplete {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ROI: \(recipe.roi > 0 ? "+" : "")\(String(format: "%.1f", recipe.roi * 100))%")
                            .font(.subheadline)
                            .foregroundColor(recipe.roi > 0 ? .red : .green)
                            .fontWeight(.medium)
                        
                        Text("EV: ¥\(String(format: "%.2f", recipe.ev))")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    // 未完成配方显示进度
                    Text("草稿 - \(recipe.items.count)/10 素材")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                }
            }
            
            Spacer()
            
            // 右侧：时间信息
            Text(recipe.date.formatted(date: .numeric, time: .omitted))
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // 辅助函数：根据磨损名称返回对应的颜色
    func wearColor(for wearName: String) -> Color {
        switch wearName {
        case Wear.factoryNew.rawValue: return Color(hex: "#2ebf58")!
        case Wear.minimalWear.rawValue: return Color(hex: "#87c34a")!
        case Wear.fieldTested.rawValue: return Color(hex: "#eabd38")!
        case Wear.wellWorn.rawValue: return Color(hex: "#eb922a")!
        case Wear.battleScarred.rawValue: return Color(hex: "#e24e4d")!
        default: return .gray
        }
    }
}

#Preview {
    // 预览用的 Mock 数据
    MyRecipesView()
}
