import SwiftUI
import Combine

// MARK: - 0. 新增：库存管理器 (InventoryManager) - 完整修复版
class InventoryManager: ObservableObject {
    // 1. 底层静态存储 (所有实例共享)
    private static var _sharedStorage: [TradeItem] = []
    // 2. 静态通知器
    private static let _updateSubject = PassthroughSubject<[TradeItem], Never>()
    
    // 实例属性
    @Published var inventory: [TradeItem] = []
    @Published var isLoading: Bool = false
    
    // 🔥 修改：状态拆分，解决后台运行问题
    @Published var isFetching: Bool = false        // 逻辑状态：任务是否正在运行
    @Published var showFetchModal: Bool = false    // UI状态：是否显示全屏遮罩
    @Published var fetchProgress: String = ""
    
    // 🔥 新增：任务句柄，用于防重和取消
    private var fetchTask: Task<Void, Never>?
    
    var steamInventory: [TradeItem] {
        get { inventory }
        set { updateData(newValue) }
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        self.inventory = InventoryManager._sharedStorage
        
        InventoryManager._updateSubject
            .receive(on: RunLoop.main)
            .sink { [weak self] newItems in
                guard let self = self else { return }
                if self.inventory != newItems {
                    self.inventory = newItems
                }
            }
            .store(in: &cancellables)
    }
    
    // 统一更新入口
    func updateData(_ newItems: [TradeItem]) {
        self.inventory = newItems
        InventoryManager._sharedStorage = newItems
        InventoryManager._updateSubject.send(newItems)
    }
    
    func setInventory(_ items: [TradeItem]) {
        updateData(items)
    }
    
    func hasItems() -> Bool {
        return !inventory.isEmpty
    }
    
    // 核心功能 1：从全局缓存刷新磨损
    func refreshWearsFromCache() {
        var hasUpdates = false
        var currentItems = self.inventory
        
        for (index, item) in currentItems.enumerated() {
            if let link = item.inspectLink,
               let cachedWear = InventoryWearFetchService.shared.getCachedWear(for: link),
               abs(item.wearValue - cachedWear) > 0.0000001 {
                
                print("♻️ [InventoryManager] 从缓存同步磨损: \(item.skin.name) -> \(cachedWear)")
                currentItems[index].wearValue = cachedWear
                hasUpdates = true
            }
        }
        
        if hasUpdates {
            updateData(currentItems)
        }
    }
    
    // 🔥 核心功能 2：主动爬取 (修复崩溃逻辑)
    func fetchMissingWears(forceRestart: Bool = false) {
        // 1. 防重保护
        if isFetching && !forceRestart {
            print("⚠️ [InventoryManager] 任务正在运行，跳过重复请求")
            // 如果希望切回来能看到进度条，可以解开下面这行
            // showFetchModal = true
            return
        }
        
        // 2. 取消旧任务
        fetchTask?.cancel()
        
        let missingItems = inventory.filter { item in
            guard let link = item.inspectLink else { return false }
            return InventoryWearFetchService.shared.getCachedWear(for: link) == nil
        }
        
        if missingItems.isEmpty {
            refreshWearsFromCache()
            return
        }
        
        // 3. 启动新任务
        isFetching = true
        showFetchModal = true
        let total = missingItems.count
        
        fetchTask = Task {
            print("🚀 [InventoryManager] 开始爬取任务，目标数量: \(total)")
            
            for (index, item) in missingItems.enumerated() {
                if Task.isCancelled { break }
                
                await MainActor.run {
                    self.fetchProgress = "正在获取磨损 (\(index + 1)/\(total))..."
                }
                
                if let link = item.inspectLink {
                    await withCheckedContinuation { continuation in
                        InventoryWearFetchService.shared.fetchWear(inspectLink: link) { _ in
                            continuation.resume()
                        }
                    }
                }
                
                // 实时刷新 UI
                await MainActor.run {
                    self.refreshWearsFromCache()
                }
                
                // 间隔，防止 API 限制
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            
            await MainActor.run {
                self.isFetching = false
                self.showFetchModal = false
                self.fetchProgress = ""
                self.refreshWearsFromCache()
                print("✅ [InventoryManager] 爬取任务结束")
            }
        }
    }
    
    // 后台运行：只关弹窗，不关任务
    func runInBackground() {
        showFetchModal = false
    }
    
    // 强制停止
    func stopFetching() {
        fetchTask?.cancel()
        isFetching = false
        showFetchModal = false
    }
}

// MARK: - 1. 基础扩展与适配

extension Rarity {
    var level: Int {
        switch name {
        case "消费级", "Consumer Grade", "Base Grade": return 0
        case "工业级", "Industrial Grade": return 1
        case "军规级", "Mil-Spec Grade": return 2
        case "受限", "受限级", "Restricted", "Restricted Grade": return 3
        case "保密", "保密级", "Classified", "Classified Grade": return 4
        case "隐秘", "隐秘级", "隐密", "Covert", "Covert Grade": return 5
        case "违禁", "违禁级", "Contraband", "非凡", "非凡级", "Extraordinary", "金色": return 6
        default: return -1
        }
    }
}

extension Skin {
    var canBeStatTrak: Bool { self.stattrak ?? false }
    
    var baseName: String {
        var n = name
            .replacingOccurrences(of: "StatTrak™ ", with: "")
            .replacingOccurrences(of: "（StatTrak™）", with: "")
            .replacingOccurrences(of: " (StatTrak™)", with: "")
        
        for wear in Wear.allCases {
            n = n.replacingOccurrences(of: " (\(wear.rawValue))", with: "")
                 .replacingOccurrences(of: "(\(wear.rawValue))", with: "")
        }
        return n.trimmingCharacters(in: CharacterSet.whitespaces)
    }
    
    func getSearchName(isStatTrak: Bool, wear: Double) -> String {
        let wearName = Wear.allCases.first { $0.range.contains(wear) }?.rawValue ?? "崭新出厂"
        let base = self.baseName
        
        if isStatTrak {
            if base.contains(" | ") {
                let statTrakBase = base.replacingOccurrences(of: " | ", with: "（StatTrak™） | ")
                return "\(statTrakBase) (\(wearName))"
            } else {
                return "\(base)（StatTrak™） (\(wearName))"
            }
        } else {
            return "\(base) (\(wearName))"
        }
    }
}

// MARK: - 智能价格服务
class FuzzyPriceHelper {
    static func getPrice(skin: Skin, wear: Double, isStatTrak: Bool) -> Double {
        let basePrice = fetchBasePrice(skin: skin, wear: wear, isStatTrak: isStatTrak)
        if basePrice <= 0 { return 0 }
        
        guard let currentWear = Wear.allCases.first(where: { $0.range.contains(wear) }) else { return basePrice }
        
        let range = currentWear.range
        let rangeSpan = range.upperBound - range.lowerBound
        let qualityRatio = rangeSpan > 0 ? (range.upperBound - wear) / rangeSpan : 0
        
        var ceilingPrice: Double = 0.0
        if let betterWear = getBetterWear(for: currentWear) {
            let dummyFloat = (betterWear.range.lowerBound + betterWear.range.upperBound) / 2.0
            ceilingPrice = fetchBasePrice(skin: skin, wear: dummyFloat, isStatTrak: isStatTrak)
        }
        
        if ceilingPrice > basePrice {
            var ratioFactor = 0.75
            if currentWear == .fieldTested { ratioFactor = 0.85 }
            else if currentWear == .minimalWear { ratioFactor = 0.80 }
            
            let anchorPrice = ceilingPrice * ratioFactor
            if anchorPrice > basePrice {
                let priceGap = anchorPrice - basePrice
                let interpolatedPrice = basePrice + (priceGap * qualityRatio)
                return min(interpolatedPrice, ceilingPrice * 0.95)
            }
        }
        
        if currentWear == .factoryNew {
            let multiplier = 1.0 + (qualityRatio * 1.5)
            return basePrice * multiplier
        }
        
        return basePrice * (1.0 + qualityRatio * 0.05)
    }
    
    static func getBasePrice(skin: Skin, wear: Double, isStatTrak: Bool) -> Double {
        return fetchBasePrice(skin: skin, wear: wear, isStatTrak: isStatTrak)
    }
    
    private static func getBetterWear(for wear: Wear) -> Wear? {
        switch wear {
        case .battleScarred: return .wellWorn
        case .wellWorn: return .fieldTested
        case .fieldTested: return .minimalWear
        case .minimalWear: return .factoryNew
        case .factoryNew: return nil
        }
    }
    
    private static func fetchBasePrice(skin: Skin, wear: Double, isStatTrak: Bool) -> Double {
        let wearName = Wear.allCases.first { $0.range.contains(wear) }?.rawValue ?? "崭新出厂"
        let base = skin.baseName
        let prefix = isStatTrak ? "（StatTrak™）" : ""
        
        var standardName = ""
        if isStatTrak && base.contains(" | ") {
            standardName = base.replacingOccurrences(of: " | ", with: "\(prefix) | ") + " (\(wearName))"
        } else {
            standardName = "\(base)\(prefix) (\(wearName))"
        }
        
        if let p = check(standardName) { return p }
        
        if isStatTrak {
             let altPrefix = "StatTrak™ "
             let altName = "\(altPrefix)\(base) (\(wearName))"
             if let p = check(altName) { return p }
        }
        
        let noSpaceBase = base.replacingOccurrences(of: " ", with: "")
        if noSpaceBase != base {
            var variantName = ""
            if isStatTrak && noSpaceBase.contains("|") {
                 variantName = noSpaceBase.replacingOccurrences(of: "|", with: "\(prefix)|") + " (\(wearName))"
            } else {
                 variantName = "\(noSpaceBase)\(prefix) (\(wearName))"
            }
            if let p = check(variantName) { return p }
        }
        
        if let p = fetchFuzzyPrice(base: base, wearName: wearName, prefix: prefix) { return p }
        return 0.0
    }
    
    private static func fetchFuzzyPrice(base: String, wearName: String, prefix: String) -> Double? {
        let parts = base.components(separatedBy: " | ")
        guard parts.count == 2 else { return nil }
        
        let weaponRaw = parts[0]
        let skinName = parts[1]
        
        let fuzzyRules: [(String, [String])] = [
            ("加利尔", ["加利尔 AR", "加利尔", "Galil AR"]),
            ("USP", ["USP 消音版", "USP-S", "USP"]),
            ("格洛克", ["格洛克 18 型", "格洛克 18", "格洛克", "Glock-18"]),
            ("CZ75", ["CZ75 自动手枪", "CZ75-Auto", "CZ75"]),
            ("沙漠之鹰", ["沙漠之鹰", "Desert Eagle"]),
            ("FN57", ["FN57", "Five-SeveN"]),
            ("双持贝瑞塔", ["双持贝瑞塔", "Dual Berettas"]),
            ("M4A1", ["M4A1 消音型", "M4A1-S", "M4A1"]),
            ("MAC-10", ["MAC-10", "MAC-10 冲锋枪"]),
            ("MP9", ["MP9", "MP9 冲锋枪"]),
            ("R8", ["R8 左轮手枪", "R8 Revolver"]),
            ("SSG", ["SSG 08", "鸟狙"]),
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
            ("M249", ["M249"]),
            ("电击枪", ["宙斯 X27 电击枪"])
        ]
        
        for (keyword, replacements) in fuzzyRules {
            if weaponRaw.contains(keyword) || weaponRaw.localizedCaseInsensitiveContains(keyword) {
                for rep in replacements {
                    let tryName = "\(rep)\(prefix) | \(skinName) (\(wearName))"
                    if let p = check(tryName) { return p }
                }
            }
        }
        
        if weaponRaw.contains(" AR") {
            let simpleRep = weaponRaw.replacingOccurrences(of: " AR", with: "")
            let tryName = "\(simpleRep)\(prefix) | \(skinName) (\(wearName))"
            if let p = check(tryName) { return p }
        }
        
        return nil
    }
    
    private static func check(_ name: String) -> Double? {
        let p = DataManager.shared.getSmartPrice(for: name)
        return p > 0 ? p : nil
    }
}

// MARK: - 2. 数据模型

struct TradeItem: Identifiable, Equatable, Codable {
    let id: UUID
    let skin: Skin
    var wearValue: Double
    var isStatTrak: Bool
    var inspectLink: String?
    
    init(skin: Skin, wearValue: Double, isStatTrak: Bool, inspectLink: String? = nil) {
        self.id = UUID()
        self.skin = skin
        self.wearValue = wearValue
        self.isStatTrak = isStatTrak
        self.inspectLink = inspectLink
    }
    
    static func == (lhs: TradeItem, rhs: TradeItem) -> Bool {
        return lhs.id == rhs.id && abs(lhs.wearValue - rhs.wearValue) < 0.0000001 && lhs.isStatTrak == rhs.isStatTrak
    }
    
    var displayName: String {
        let n = skin.baseName
        if isStatTrak {
            return n.contains(" | ") ? n.replacingOccurrences(of: " | ", with: "（StatTrak™） | ") : "\(n)（StatTrak™）"
        }
        return n
    }
    
    var price: Double {
        return FuzzyPriceHelper.getPrice(skin: skin, wear: wearValue, isStatTrak: isStatTrak)
    }
    
    var outcomePrice: Double {
        return FuzzyPriceHelper.getBasePrice(skin: skin, wear: wearValue, isStatTrak: isStatTrak)
    }
}

struct SimulationResult: Identifiable {
    let id = UUID()
    let skin: Skin
    let wear: Double
    let probability: Double
    let isStatTrak: Bool
}

struct CollectionGroup: Identifiable {
    var id: String { name }
    
    let name: String
    let items: [TradeItem]
    let slotIndices: [Int]?
    let isResult: Bool
}

struct SelectableSkinWrapper: Identifiable {
    var id: String { return isStatTrak ? "\(skin.id)_st" : skin.id }
    let skin: Skin
    let isStatTrak: Bool
    
    var displayName: String {
        let n = skin.baseName
        return isStatTrak ? n.replacingOccurrences(of: " | ", with: "（StatTrak™） | ") : n
    }
    
    func getDisplayName(for wearFilter: Wear?) -> String {
        let base = displayName
        if let wear = wearFilter {
            return "\(base) (\(wear.rawValue))"
        }
        return base
    }
    
    func getPreviewPrice(for wearFilter: Wear?) -> String {
        var targetWear = skin.min_float ?? 0
        if let w = wearFilter {
            let mid = (w.range.lowerBound + w.range.upperBound) / 2
            targetWear = max(targetWear, mid)
        } else {
            targetWear = max(targetWear, 0.035)
        }
        let price = FuzzyPriceHelper.getBasePrice(skin: skin, wear: targetWear, isStatTrak: isStatTrak)
        return price > 0 ? String(format: "¥%.2f", price) : "---"
    }
}

// MARK: - 3. ViewModel

@Observable
class TradeUpViewModel {
    var slots: [TradeItem?] = Array(repeating: nil, count: 10)
    var isEditing = false
    
    var simulationResults: [CollectionGroup] = []
    var hasCalculated = false
    var validationError: String? = nil
    var showValidationError = false
    
    var expectedValue: Double = 0.0
    var roi: Double = 0.0
    
    private var originalSnapshot: [TradeItem] = []
    
    var currentEditingRecipeId: UUID? = nil {
        didSet {
            if currentEditingRecipeId != nil {
                snapshotState()
            } else {
                originalSnapshot = []
            }
        }
    }
    var currentEditingRecipeTitle: String = ""
    
    var hasUnsavedChanges: Bool {
        guard currentEditingRecipeId != nil else { return false }
        let currentItems = slots.compactMap { $0 }
        return currentItems != originalSnapshot
    }
    
    func snapshotState() {
        originalSnapshot = slots.compactMap { $0 }
    }
    
    var filledCount: Int { slots.compactMap { $0 }.count }
    var countString: String { "\(filledCount)/10" }
    var isFull: Bool { filledCount >= 10 }
    
    var groupedSlots: [CollectionGroup] {
        var groups: [String: [(Int, TradeItem)]] = [:]
        for (index, slot) in slots.enumerated() {
            if let item = slot {
                let rawName = DataManager.shared.getCollectionName(for: item.skin)
                let dispName = rawName.replacingOccurrences(of: "收藏品", with: "").trimmingCharacters(in: CharacterSet.whitespaces) + " 收藏品"
                if groups[dispName] == nil { groups[dispName] = [] }
                groups[dispName]?.append((index, item))
            }
        }
        let sortedKeys = groups.keys.sorted()
        return sortedKeys.map { key in
            let items = groups[key]!
            return CollectionGroup(
                name: key,
                items: items.map { $0.1 },
                slotIndices: items.map { $0.0 },
                isResult: false
            )
        }
    }
    
    var currentConstraints: (Int?, Bool?) {
        let items = slots.compactMap { $0 }
        guard let first = items.first else { return (nil, nil) }
        return (first.skin.rarity?.level, first.isStatTrak)
    }
    
    func getSelectableSkins(from allSkins: [Skin], filterStatTrak: Int, filterWear: Wear?) -> [SelectableSkinWrapper] {
        let (reqLevel, reqST) = currentConstraints
        var result: [SelectableSkinWrapper] = []
        
        for skin in allSkins {
            if !isValidInput(skin) { continue }
            if let targetLv = reqLevel, let skinLv = skin.rarity?.level, skinLv != targetLv { continue }
            if let wear = filterWear { if !skin.supports(wear: wear) { continue } }
            
            let matchNormal = (reqST == nil || reqST == false) && (filterStatTrak == 0 || filterStatTrak == 2)
            let matchST = (reqST == nil || reqST == true) && (filterStatTrak == 0 || filterStatTrak == 1) && skin.canBeStatTrak
            
            if matchNormal { result.append(SelectableSkinWrapper(skin: skin, isStatTrak: false)) }
            if matchST { result.append(SelectableSkinWrapper(skin: skin, isStatTrak: true)) }
        }
        return result
    }
    
    func updateSlot(index: Int, wrapper: SelectableSkinWrapper, wear: Double) {
        let newItem = TradeItem(skin: wrapper.skin, wearValue: wear, isStatTrak: wrapper.isStatTrak)
        slots[index] = newItem
        resetResult()
    }
    
    func updateSlotWithItem(index: Int, item: TradeItem) {
        slots[index] = item
        resetResult()
    }
    
    func updateWear(index: Int, wear: Double) {
        guard var item = slots[index] else { return }
        item.wearValue = wear
        slots[index] = item
        resetResult()
    }
    
    func deleteSlot(at index: Int) {
        slots.remove(at: index)
        slots.append(nil)
        if filledCount == 0 { isEditing = false }
        resetResult()
    }
    
    func duplicateSlot(at index: Int) {
        guard let sourceItem = slots[index] else { return }
        if let firstEmptyIndex = slots.firstIndex(where: { $0 == nil }) {
            let newItem = TradeItem(skin: sourceItem.skin, wearValue: sourceItem.wearValue, isStatTrak: sourceItem.isStatTrak)
            slots[firstEmptyIndex] = newItem
            resetResult()
        }
    }
    
    func resetResult() {
        hasCalculated = false
        simulationResults = []
        expectedValue = 0.0
        roi = 0.0
    }
    
    func exitEditMode() {
        currentEditingRecipeId = nil
        currentEditingRecipeTitle = ""
    }
    
    func clearAll() {
        slots = Array(repeating: nil, count: 10)
        resetResult()
        currentEditingRecipeId = nil
        currentEditingRecipeTitle = ""
        isEditing = false
    }
    
    func simulate() {
        if !validateTradeUp() { showValidationError = true; return }
        let inputs = slots.compactMap { $0 }
        let (_, results) = performSimulation(inputs: inputs)
        
        if results.isEmpty {
            validationError = "未找到有效产物。\n请检查：\n1. 输入皮肤的收藏品是否有上级。\n2. 数据源名称是否匹配。"
            showValidationError = true
            return
        }
        
        var groups: [String: [TradeItem]] = [:]
        var probs: [UUID: Double] = [:]
        var totalEV = 0.0
        
        for res in results {
            let rawName = DataManager.shared.getCollectionName(for: res.skin)
            let dispName = rawName.replacingOccurrences(of: "收藏品", with: "").trimmingCharacters(in: CharacterSet.whitespaces) + " 收藏品"
            if groups[dispName] == nil { groups[dispName] = [] }
            
            let item = TradeItem(skin: res.skin, wearValue: res.wear, isStatTrak: res.isStatTrak)
            probs[item.id] = res.probability
            groups[dispName]?.append(item)
            
            let price = FuzzyPriceHelper.getBasePrice(skin: res.skin, wear: res.wear, isStatTrak: res.isStatTrak)
            totalEV += price * res.probability
        }
        
        self.simulationResults = groups.keys.sorted().map { key in
            CollectionGroup(name: key, items: groups[key]!, slotIndices: nil, isResult: true)
        }
        
        DataManager.shared.tempProbabilities = probs
        self.expectedValue = totalEV
        let cost = calculateTotalCost()
        if cost > 0 { self.roi = (totalEV - cost) / cost } else { self.roi = 0 }
        hasCalculated = true
    }
    
    private func performSimulation(inputs: [TradeItem]) -> (Double, [SimulationResult]) {
        let count = Double(inputs.count)
        if count == 0 { return (0, []) }
        
        let totalDef = inputs.reduce(0.0) { sum, item in
            sum + calcDeformedValue(targetFloat: item.wearValue, minF: item.skin.min_float ?? 0, maxF: item.skin.max_float ?? 1)
        }
        let activeAvgDef = totalDef / 10.0
        
        var outcomeMap: [String: (skin: Skin, prob: Double)] = [:]
        let inputLevel = inputs[0].skin.rarity?.level ?? 0
        let isStattrakInput = inputs[0].isStatTrak
        let nextLevel = inputLevel + 1
        
        for item in inputs {
            let rawCol = DataManager.shared.getCollectionName(for: item.skin)
            let outcomes = DataManager.shared.getSkinsByLevelSmart(collectionRawName: rawCol, level: nextLevel)
            if outcomes.isEmpty { continue }
            
            let probShare = 0.1 / Double(outcomes.count)
            for outSkin in outcomes {
                let key = outSkin.id
                if let existing = outcomeMap[key] {
                    outcomeMap[key] = (outSkin, existing.prob + probShare)
                } else {
                    outcomeMap[key] = (outSkin, probShare)
                }
            }
        }
        
        var results: [SimulationResult] = []
        for (_, val) in outcomeMap {
            let outSkin = val.skin
            let outMin = outSkin.min_float ?? 0
            let outMax = outSkin.max_float ?? 1
            let resFloat = activeAvgDef * (outMax - outMin) + outMin
            results.append(SimulationResult(skin: outSkin, wear: resFloat, probability: val.prob, isStatTrak: isStattrakInput))
        }
        results.sort { $0.probability > $1.probability }
        return (0, results)
    }
    
    func calcDeformedValue(targetFloat: Double, minF: Double, maxF: Double) -> Double {
        let actual = max(minF, min(maxF, targetFloat))
        let range = maxF - minF
        if range <= 0 { return 0.0 }
        return (actual - minF) / range
    }
    
    func validateTradeUp() -> Bool {
        if filledCount < 10 { validationError = "素材不足 10 个"; return false }
        let items = slots.compactMap { $0 }
        let levels = Set(items.map { $0.skin.rarity?.level })
        if levels.count > 1 { validationError = "所有素材品质必须相同"; return false }
        let sts = Set(items.map { $0.isStatTrak })
        if sts.count > 1 { validationError = "暗金状态必须统一"; return false }
        if items.first?.skin.rarity?.level == 5 {
            validationError = "隐秘级(红色)皮肤无法炼金"; return false
        }
        return true
    }
    
    func isValidInput(_ skin: Skin) -> Bool {
        let nameLower = skin.name.lowercased()
        let typeLower = skin.category?.name.lowercased() ?? ""
        let forbidden = ["knife", "glove", "wraps", "dagger", "bayonet", "karambit", "爪子", "手套", "裹手", "匕首", "刺刀", "折叠", "蝴蝶", "短剑", "系带", "纪念品", "souvenir"]
        for kw in forbidden {
            if nameLower.contains(kw) || typeLower.contains(kw) { return false }
        }
        if skin.rarity?.level == 5 { return false }
        return true
    }
    
    func calculateTotalCost() -> Double {
        slots.compactMap { $0?.price }.reduce(0.0, +)
    }
    
    var totalCostString: String {
        String(format: "¥%.2f", calculateTotalCost())
    }
}

// MARK: - 5. DataManager 扩展

extension DataManager {
    struct Holder { static var tempProbabilities: [UUID: Double] = [:] }
    var tempProbabilities: [UUID: Double] {
        get { Holder.tempProbabilities }
        set { Holder.tempProbabilities = newValue }
    }
    
    func getCollectionName(for skin: Skin) -> String {
        if let cols = skin.collections, let first = cols.first {
            return first.name
        }
        return "未知收藏品"
    }
    
    func getSkinsByLevelSmart(collectionRawName: String, level: Int) -> [Skin] {
        let targetKey = normalizeKey(collectionRawName)
        let all = getAllSkins()
        
        return all.filter { skin in
            guard let l = skin.rarity?.level, l == level else { return false }
            let skinCols = skin.collections ?? []
            for col in skinCols {
                if normalizeKey(col.name) == targetKey { return true }
            }
            return false
        }
    }
    
    private func normalizeKey(_ s: String) -> String {
        var res = s.lowercased()
        let removeList = ["收藏品", "武器箱", "collection", "case", "大行动", "operation", "map", "地图"]
        for word in removeList {
            res = res.replacingOccurrences(of: word, with: "")
        }
        let unsafeChars = CharacterSet.alphanumerics.inverted
        res = res.components(separatedBy: unsafeChars).joined()
        return res
    }
    
    func getAllSkins() -> [Skin] {
        return self.allSkins
    }
    
    func getSmartPrice(for searchName: String) -> Double {
        let p1 = getPriceInternal(name: searchName)
        if p1 > 0 { return p1 }
        
        let norm1 = searchName.replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")")
        let p2 = getPriceInternal(name: norm1)
        if p2 > 0 { return p2 }
        
        if searchName.contains("StatTrak") {
            let alt = searchName.replacingOccurrences(of: "StatTrak™", with: "StatTrak")
            let p4 = getPriceInternal(name: alt)
            if p4 > 0 { return p4 }
        }
        return 0.0
    }
    
    private func getPriceInternal(name: String) -> Double {
        return self.getRawPrice(for: name)
    }
}

// MARK: - 6. 视图组件

enum activeSheet: Identifiable {
    case selector(slotIndex: Int)
    case editor(slotIndex: Int)
    
    var id: String {
        switch self {
        case .selector(let index): return "sel-\(index)"
        case .editor(let index): return "edit-\(index)"
        }
    }
}

struct ContentView: View {
    @State private var viewModel = TradeUpViewModel()
    @StateObject private var inventoryManager = InventoryManager()
    
    @State private var activeSheetItem: activeSheet?
    @State private var pendingEditorIndex: Int?
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            CustomTradeUpView(viewModel: viewModel, inventoryManager: inventoryManager, activeSheetItem: $activeSheetItem, pendingEditorIndex: $pendingEditorIndex, selectedTab: $selectedTab)
                .tabItem { Label("新建配方", systemImage: "hammer.fill") }
                .tag(0)
            
            InventorySmartView(tradeUpViewModel: viewModel, selectedTab: $selectedTab)
                .environmentObject(inventoryManager)
                .tabItem { Label("库存配平", systemImage: "wand.and.stars") }
                .tag(1)
                
            MyRecipesView(viewModel: viewModel, selectedTab: $selectedTab)
                .tabItem { Label("我的配方", systemImage: "list.bullet.clipboard") }
                .tag(2)
        }
        .sheet(item: $activeSheetItem, onDismiss: {
            if let index = pendingEditorIndex {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    activeSheetItem = .editor(slotIndex: index)
                }
                pendingEditorIndex = nil
            }
        }) { item in
            switch item {
            case .selector(let index):
                SkinSelectorView(
                    viewModel: viewModel,
                    inventoryManager: inventoryManager,
                    slotIndex: index,
                    selectedTab: $selectedTab,
                    onSkinSelected: { wrapper, initialWear in
                        viewModel.updateSlot(index: index, wrapper: wrapper, wear: initialWear)
                        pendingEditorIndex = index
                    },
                    onInventoryItemSelected: { item in
                        viewModel.updateSlotWithItem(index: index, item: item)
                        activeSheetItem = nil
                    }
                )
                .presentationDetents([.medium, .large])
                
            case .editor(let index):
                if let item = viewModel.slots[index] {
                    let wearBinding = Binding<Double>(
                        get: { item.wearValue },
                        set: { newVal in viewModel.updateWear(index: index, wear: newVal) }
                    )
                    WearEditorView(
                        skin: item.skin,
                        wearValue: wearBinding,
                        onConfirm: { activeSheetItem = nil }
                    )
                    .presentationDetents([.fraction(0.6)])
                    .presentationDragIndicator(.visible)
                }
            }
        }
        .alert("无法开始炼金", isPresented: $viewModel.showValidationError) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(viewModel.validationError ?? "未知错误")
        }
    }
}

struct CustomTradeUpView: View {
    var viewModel: TradeUpViewModel
    @ObservedObject var inventoryManager: InventoryManager
    
    @Binding var activeSheetItem: activeSheet?
    @Binding var pendingEditorIndex: Int?
    @Binding var selectedTab: Int
    
    @State private var showSaveAlert = false
    @State private var showExitAlert = false
    @State private var saveTitle = ""
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 自定义顶部栏
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        let displayTitle = (viewModel.currentEditingRecipeId != nil && !viewModel.currentEditingRecipeTitle.isEmpty)
                            ? viewModel.currentEditingRecipeTitle
                            : "新建配方"
                            
                        Text(displayTitle)
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        
                        if viewModel.currentEditingRecipeId != nil {
                            Button(action: {
                                if viewModel.hasUnsavedChanges { showExitAlert = true }
                                else { withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { viewModel.exitEditMode() } }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.uturn.backward.circle.fill")
                                    Text("退出编辑模式")
                                }
                                .font(.caption).fontWeight(.bold).foregroundColor(.white)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(Color.red.opacity(0.9)).shadow(color: .red.opacity(0.3), radius: 4, x: 0, y: 2))
                            }
                            .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .scale.combined(with: .opacity)))
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                Text("当前为新建模式")
                            }
                            .font(.caption).fontWeight(.medium).foregroundColor(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color(UIColor.secondarySystemBackground)))
                            .transition(.opacity)
                        }
                    }
                    .animation(.default, value: viewModel.currentEditingRecipeId)
                    Spacer()
                    if viewModel.filledCount > 0 {
                        HStack(spacing: 0) {
                            Button(action: { saveTitle = viewModel.currentEditingRecipeTitle; showSaveAlert = true }) {
                                Text("保存").foregroundColor(.green).fontWeight(.medium)
                            }
                            Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 1, height: 14).padding(.horizontal, 12)
                            Button(action: { withAnimation { viewModel.isEditing.toggle() } }) {
                                Text(viewModel.isEditing ? "完成" : "编辑").fontWeight(viewModel.isEditing ? .bold : .regular).foregroundColor(.blue)
                            }
                        }.font(.system(size: 17)).padding(.top, 8)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 5).background(Color(UIColor.systemBackground))
                
                // 顶部数据栏
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        StatCard(title: "素材数量", value: viewModel.countString)
                        StatCard(title: "总成本", value: viewModel.totalCostString)
                        let displayEV = viewModel.expectedValue > 0 ? String(format: "¥%.2f", viewModel.expectedValue) : "---"
                        StatCard(title: "期望产出", value: displayEV, color: .blue)
                        let roiVal = viewModel.roi * 100
                        let roiColor: Color = roiVal > 0 ? .red : (roiVal < 0 ? .green : .primary)
                        let prefix = roiVal > 0 ? "+" : ""
                        let displayROI = viewModel.expectedValue > 0 ? "\(prefix)\(String(format: "%.1f", roiVal))%" : "---"
                        StatCard(title: "ROI", value: displayROI, color: roiColor)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
                .background(Color(UIColor.systemBackground))
                .onTapGesture { withAnimation { viewModel.isEditing = false } }
                
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(viewModel.groupedSlots.filter { !$0.isResult }) { group in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(group.name).font(.system(size: 12, weight: .bold)).foregroundColor(.secondary).padding(.horizontal, 16)
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                                        ForEach(group.items) { item in
                                            SlotView(
                                                item: item, isEditing: viewModel.isEditing, isFull: viewModel.isFull, isOutcome: false,
                                                onDelete: { if let index = viewModel.slots.firstIndex(where: { $0?.id == item.id }) { viewModel.deleteSlot(at: index) } },
                                                onDuplicate: { if let index = viewModel.slots.firstIndex(where: { $0?.id == item.id }) { viewModel.duplicateSlot(at: index) } }
                                            )
                                            .onTapGesture {
                                                if viewModel.isEditing { withAnimation { viewModel.isEditing = false } }
                                                else { if let index = viewModel.slots.firstIndex(where: { $0?.id == item.id }) { handleSlotTap(index: index) } }
                                            }
                                            .onLongPressGesture { let gen = UIImpactFeedbackGenerator(style: .heavy); gen.impactOccurred(); withAnimation { viewModel.isEditing = true } }
                                        }
                                    }.padding(.horizontal, 12)
                                }
                            }
                            if !viewModel.isFull {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                                    let firstEmptyIndex = viewModel.slots.firstIndex(where: { $0 == nil }) ?? viewModel.filledCount
                                    SlotView(item: nil, isEditing: false, isFull: false, isOutcome: false, onDelete: {}, onDuplicate: {})
                                        .onTapGesture { handleSlotTap(index: firstEmptyIndex) }
                                }.padding(.horizontal, 12)
                            }
                            if viewModel.hasCalculated && !viewModel.simulationResults.isEmpty {
                                Divider().padding(.vertical, 10).id("ResultsAnchor")
                                Text("模拟产出").font(.title3).bold().padding(.leading, 16)
                                ForEach(viewModel.simulationResults) { group in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(group.name).font(.system(size: 12, weight: .bold)).foregroundColor(.secondary).padding(.leading, 20)
                                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                                            ForEach(group.items) { item in
                                                let prob = DataManager.shared.tempProbabilities[item.id] ?? 0
                                                SlotView(item: item, isEditing: false, isFull: true, probability: prob, isOutcome: true, onDelete: {}, onDuplicate: {}).disabled(true)
                                            }
                                        }.padding(.horizontal, 12)
                                    }
                                }
                            }
                            Spacer(minLength: 100)
                        }.padding(.top, 12)
                    }
                    .onTapGesture { withAnimation { viewModel.isEditing = false } }
                    if viewModel.filledCount == 10 {
                        VStack {
                            Button(action: { withAnimation { viewModel.simulate(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { withAnimation { scrollProxy.scrollTo("ResultsAnchor", anchor: .top) } } } }) {
                                Text(viewModel.hasCalculated ? "重新计算" : "开始模拟汰换").font(.headline).foregroundColor(.white)
                                    .frame(maxWidth: .infinity).frame(height: 50).background(Color.blue).cornerRadius(12)
                            }
                        }.padding().background(Color(UIColor.secondarySystemBackground))
                        .transition(.move(edge: .bottom).combined(with: .opacity)).zIndex(1)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .alert("保存配方", isPresented: $showSaveAlert) {
                TextField("请输入配方名称", text: $saveTitle); Button("取消", role: .cancel) { }; Button("保存") { saveRecipe() }
            } message: { if viewModel.currentEditingRecipeId != nil { Text("当前正在编辑现有配方：\n“\(viewModel.currentEditingRecipeTitle)”\n保存将覆盖原记录。") } else { Text("新配方将保存到“我的配方”模块中") } }
            .alert("未保存的更改", isPresented: $showExitAlert) {
                Button("取消", role: .cancel) { }; Button("直接退出", role: .destructive) { withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { viewModel.exitEditMode() } }
            } message: { Text("您对“\(viewModel.currentEditingRecipeTitle)”进行了更改但尚未保存。\n直接退出将丢失这些更改。") }
        }
    }
    
    func handleSlotTap(index: Int) {
        if viewModel.slots[index] == nil { activeSheetItem = .selector(slotIndex: index) } else { activeSheetItem = .editor(slotIndex: index) }
    }
    
    func saveRecipe() {
        let items = viewModel.slots.compactMap { $0 }; if items.isEmpty { return }
        var bestOutcomeData: (Skin, Double, String)? = nil
        if viewModel.hasCalculated, let best = viewModel.simulationResults.flatMap({ $0.items }).first {
            let prob = DataManager.shared.tempProbabilities[best.id] ?? 0.0
            var wearName = "未知磨损"; for wear in Wear.allCases { if wear.range.contains(best.wearValue) { wearName = wear.rawValue; break } }
            bestOutcomeData = (best.skin, prob, wearName)
        }
        let recipeId = viewModel.currentEditingRecipeId ?? UUID()
        let newRecipe = SavedRecipe(id: recipeId, title: saveTitle.isEmpty ? "未命名配方" : saveTitle, items: items, ev: viewModel.expectedValue, roi: viewModel.roi, bestOutcome: bestOutcomeData)
        RecipeManager.shared.saveRecipe(newRecipe)
        viewModel.currentEditingRecipeId = newRecipe.id; viewModel.currentEditingRecipeTitle = newRecipe.title; viewModel.snapshotState()
    }
}

// MARK: - 皮肤选择器 (改进版：支持我的库存)
struct SkinSelectorView: View {
    var viewModel: TradeUpViewModel
    @ObservedObject var inventoryManager: InventoryManager
    var slotIndex: Int
    @Binding var selectedTab: Int
    
    var onSkinSelected: (SelectableSkinWrapper, Double) -> Void
    var onInventoryItemSelected: (TradeItem) -> Void
    
    @Environment(\.dismiss) var dismiss
    
    enum SelectionSource: String, CaseIterable {
        case database = "数据库搜索"
        case inventory = "我的库存"
    }
    @State private var selectionSource: SelectionSource = .database
    @State private var searchText = ""
    @State private var statTrakFilter: Int = 0
    @State private var wearFilter: Wear? = nil
    
    var allSkins: [Skin] { DataManager.shared.getAllSkins() }
    
    var filteredWrappers: [SelectableSkinWrapper] {
        let baseList = viewModel.getSelectableSkins(from: allSkins, filterStatTrak: statTrakFilter, filterWear: wearFilter)
        if searchText.isEmpty { return baseList }
        return baseList.filter { $0.skin.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    // 🔥 修复：根据配方约束 (品质/暗金) 过滤库存
    var filteredInventory: [TradeItem] {
        // 获取当前配方的约束：品质等级 (reqLevel) 和 暗金状态 (reqST)
        // 如果当前槽位是空的，这些值为 nil，表示不限制
        let (reqLevel, reqST) = viewModel.currentConstraints
        
        return inventoryManager.inventory.filter { item in
            // 1. 基础合法性 (过滤掉隐秘级、匕首、手套等不可炼金物品)
            if !viewModel.isValidInput(item.skin) { return false }
            
            // 2. 品质约束 (必须与当前配方品质一致)
            if let targetLv = reqLevel, let itemLv = item.skin.rarity?.level {
                if itemLv != targetLv { return false }
            }
            
            // 3. 暗金约束 (必须与当前配方暗金状态一致)
            if let targetST = reqST {
                if item.isStatTrak != targetST { return false }
            }
            
            // 4. 搜索文本过滤
            if !searchText.isEmpty {
                let nameMatch = item.skin.name.localizedCaseInsensitiveContains(searchText) ||
                                item.skin.baseName.localizedCaseInsensitiveContains(searchText)
                if !nameMatch { return false }
            }
            
            return true
        }
    }
    
    let inventoryGridColumns = [ GridItem(.adaptive(minimum: 110), spacing: 10) ]
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("来源", selection: $selectionSource) {
                    ForEach(SelectionSource.allCases, id: \.self) { source in Text(source.rawValue).tag(source) }
                }
                .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 10)
                .onChange(of: selectionSource) { newValue in
                    searchText = ""
                    if newValue == .inventory { inventoryManager.fetchMissingWears() }
                }
                
                if selectionSource == .database {
                    VStack(spacing: 0) {
                        Picker("类型", selection: $statTrakFilter) { Text("全部").tag(0); Text("StatTrak™").tag(1); Text("普通").tag(2) }.pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 10)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                FilterChip(title: "全部外观", isSelected: wearFilter == nil) { wearFilter = nil }
                                ForEach(Wear.allCases) { wear in FilterChip(title: wear.rawValue, isSelected: wearFilter == wear) { wearFilter = wear } }
                            }.padding(.horizontal).padding(.bottom, 10)
                        }
                        Divider()
                        List(filteredWrappers) { wrapper in
                            HStack {
                                CachedImage(url: wrapper.skin.imageURL, transition: false).frame(width: 50, height: 38)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(wrapper.getDisplayName(for: wearFilter)).font(.body).fontWeight(wrapper.isStatTrak ? .semibold : .regular).foregroundColor(wrapper.isStatTrak ? .orange : .primary)
                                    HStack {
                                        Text(wrapper.skin.rarity?.name ?? "").font(.caption).foregroundColor(wrapper.skin.rarity?.swiftColor ?? .gray)
                                        Text(wrapper.getPreviewPrice(for: wearFilter)).font(.caption).fontWeight(.bold).foregroundColor(.green)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                var initialWear = wrapper.skin.min_float ?? 0
                                if let w = wearFilter { let mid = (w.range.lowerBound + w.range.upperBound) / 2; initialWear = max(initialWear, mid) } else { initialWear = max(initialWear, 0.035) }
                                onSkinSelected(wrapper, initialWear); dismiss()
                            }
                        }
                    }
                } else {
                    ZStack {
                        Color(UIColor.systemGroupedBackground)
                        
                        // 显示结果
                        if filteredInventory.isEmpty && !searchText.isEmpty {
                            // 有搜索内容但无结果
                            VStack(spacing: 20) {
                                Image(systemName: "magnifyingglass").font(.system(size: 50)).foregroundColor(.gray)
                                Text("未找到匹配的库存物品").foregroundColor(.secondary)
                            }
                        } else if inventoryManager.inventory.isEmpty && !inventoryManager.isLoading {
                            // 库存完全为空
                            VStack(spacing: 20) {
                                Image(systemName: "archivebox").font(.system(size: 50)).foregroundColor(.gray)
                                Text("库存空空如也").foregroundColor(.secondary)
                                Button(action: { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { selectedTab = 1 } }) {
                                    Text("前往库存页面加载").fontWeight(.bold).padding().frame(width: 200).background(Color.blue).foregroundColor(.white).cornerRadius(10)
                                }
                            }
                        } else if filteredInventory.isEmpty && !inventoryManager.inventory.isEmpty {
                            // 有库存，但被品质/暗金条件过滤光了
                            VStack(spacing: 20) {
                                Image(systemName: "slider.horizontal.3").font(.system(size: 50)).foregroundColor(.gray)
                                Text("没有符合当前配方要求的物品").font(.headline).foregroundColor(.secondary)
                                Text("当前配方限制：\n品质：\(getLevelName(viewModel.currentConstraints.0))\n暗金：\(getSTName(viewModel.currentConstraints.1))").font(.caption).foregroundColor(.gray).multilineTextAlignment(.center)
                            }
                        } else {
                            ScrollView {
                                LazyVGrid(columns: inventoryGridColumns, spacing: 12) {
                                    ForEach(filteredInventory) { item in
                                        SlotView(item: item, isEditing: false, isFull: true, isOutcome: false, onDelete: {}, onDuplicate: {})
                                            .frame(height: 130)
                                            .onTapGesture { onInventoryItemSelected(item); dismiss() }
                                    }
                                }.padding()
                            }
                        }
                        
                        if inventoryManager.showFetchModal {
                            ZStack {
                                Color.black.opacity(0.4).ignoresSafeArea()
                                VStack(spacing: 20) {
                                    ProgressView().scaleEffect(1.5).tint(.white)
                                    Text(inventoryManager.fetchProgress).foregroundColor(.white).font(.headline)
                                    Button("后台运行") { inventoryManager.runInBackground() }
                                    .font(.caption).foregroundColor(.gray).padding(.top, 10)
                                }
                                .padding(30).background(Color(UIColor.secondarySystemBackground).opacity(0.95)).cornerRadius(16).shadow(radius: 20)
                            }
                            .zIndex(200)
                        } else if inventoryManager.isLoading {
                            ZStack {
                                Color.black.opacity(0.4)
                                VStack(spacing: 16) {
                                    ProgressView().scaleEffect(1.5).tint(.white)
                                    Text("正在加载库存...").foregroundColor(.white).font(.headline)
                                }.padding(30).background(Color(UIColor.secondarySystemBackground).opacity(0.9)).cornerRadius(16)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: selectionSource == .database ? "搜索皮肤数据库" : "搜索我的库存")
            .navigationTitle("选择 #\(slotIndex + 1) 素材")
            .navigationBarTitleDisplayMode(.inline)
            // 🔥 新增：仅在库存模式下显示刷新按钮
            .toolbar {
                if selectionSource == .inventory {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: {
                            // 强制刷新磨损，无视是否已缓存
                            inventoryManager.fetchMissingWears(forceRestart: true)
                        }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(inventoryManager.isFetching)
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .onAppear {
                inventoryManager.refreshWearsFromCache()
                if selectionSource == .inventory && !inventoryManager.inventory.isEmpty {
                    inventoryManager.fetchMissingWears()
                }
            }
        }
    }
    
    // 辅助函数：获取品质名称
    func getLevelName(_ level: Int?) -> String {
        guard let level = level else { return "不限" }
        switch level {
        case 0: return "消费级"
        case 1: return "工业级"
        case 2: return "军规级"
        case 3: return "受限"
        case 4: return "保密"
        case 5: return "隐秘"
        default: return "未知"
        }
    }
    
    // 辅助函数：获取暗金状态名称
    func getSTName(_ isST: Bool?) -> String {
        guard let isST = isST else { return "不限" }
        return isST ? "StatTrak™" : "普通"
    }
}

// MARK: - SlotView (修复动画闪烁)
struct SlotView: View {
    let item: TradeItem?
    let isEditing: Bool
    let isFull: Bool
    var probability: Double? = nil
    var isOutcome: Bool = false
    var onDelete: () -> Void
    var onDuplicate: () -> Void
    @State private var shakeTrigger = false
    var displayName: String { item?.displayName ?? "" }
    
    // 获取纯净的磨损名称 (例如 "略有磨损")
    var simpleWearName: String {
        guard let item = item else { return "" }
        for wear in Wear.allCases {
            if wear.range.contains(item.wearValue) { return wear.rawValue }
        }
        return "未知"
    }
    
    var wearColor: Color {
        guard let item = item else { return .gray }
        if item.wearValue < 0.07 { return Color(hex: "#2ebf58")! }
        if item.wearValue < 0.15 { return Color(hex: "#87c34a")! }
        if item.wearValue < 0.38 { return Color(hex: "#eabd38")! }
        if item.wearValue < 0.45 { return Color(hex: "#eb922a")! }
        return Color(hex: "#e24e4d")!
    }
    
    var body: some View {
        ZStack {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(UIColor.secondarySystemBackground))
                    .frame(height: 125)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(item?.skin.rarity?.swiftColor ?? Color.gray.opacity(0.3), lineWidth: item == nil ? 1 : 2)
                            .shadow(color: item?.skin.rarity?.swiftColor.opacity(0.2) ?? .clear, radius: 2)
                    )
                
                if let item = item {
                    VStack(spacing: 0) {
                        // 图片
                        CachedImage(url: item.skin.imageURL, transition: false)
                            .frame(height: 40)
                            .padding(.top, 6)
                        
                        // 文字信息区域
                        VStack(spacing: 2) {
                            // 1. 枪名
                            Text(displayName)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                                .padding(.horizontal, 2)
                            
                            // 2. 修改：枪名下方直接显示外观 (颜色对应)
                            Text(simpleWearName)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(wearColor)
                        }
                        .padding(.top, 2)
                        
                        Spacer(minLength: 0)
                        
                        // 底部磨损条和数值
                        VStack(spacing: 3) {
                            WearBarView(currentFloat: item.wearValue, minFloat: item.skin.min_float ?? 0, maxFloat: item.skin.max_float ?? 1)
                                .frame(height: 4)
                                .padding(.horizontal, 6)
                            
                            Text(String(format: "%.6f", item.wearValue))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .padding(.bottom, 8)
                    }
                    
                    // 概率显示 (如果是产物)
                    if let prob = probability {
                        Text(String(format: "%.1f%%", prob * 100))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.9))
                            .cornerRadius(4)
                            .padding(4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                } else {
                    Image(systemName: "plus")
                        .font(.title3)
                        .foregroundColor(.gray)
                }
            }
            .rotationEffect(.degrees(shakeTrigger ? 1.5 : 0))
            .animation(
                shakeTrigger ?
                Animation.easeInOut(duration: 0.12).repeatForever(autoreverses: true).delay(Double.random(in: 0...0.2)) :
                .default,
                value: shakeTrigger
            )
            .onAppear {
                if isEditing {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { shakeTrigger = true }
                }
            }
            .onChange(of: isEditing) { newValue in shakeTrigger = newValue }
            
            if isEditing && item != nil {
                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 20))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .shadow(radius: 2)
                }
                .offset(x: -6, y: -6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .zIndex(100)
                
                if !isFull {
                    Button(action: onDuplicate) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .blue)
                            .shadow(radius: 2)
                    }
                    .offset(x: 6, y: -6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .zIndex(100)
                }
            }
        }
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue : Color(UIColor.secondarySystemBackground))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(20)
            .onTapGesture(perform: action)
            .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    var color: Color? = nil
    
    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            Text(value).font(.system(size: 14, weight: .bold)).foregroundColor(color ?? .primary).minimumScaleFactor(0.5)
        }
        .frame(minWidth: 80, alignment: .leading).padding(8)
        .background(Color(UIColor.secondarySystemBackground)).cornerRadius(8)
    }
}

struct WearBarView: View {
    var currentFloat: Double
    var minFloat: Double
    var maxFloat: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(Wear.allCases, id: \.self) { wear in
                        let width = geometry.size.width * (wear.range.upperBound - wear.range.lowerBound)
                        Rectangle().fill(wearColor(wear)).frame(width: width)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
                HStack(spacing: 0) {
                    Rectangle().fill(Color.black.opacity(0.5)).frame(width: geometry.size.width * minFloat)
                    Spacer()
                    Rectangle().fill(Color.black.opacity(0.5)).frame(width: geometry.size.width * (1.0 - maxFloat))
                }
                Rectangle().fill(Color.black).frame(width: 2, height: geometry.size.height + 4).offset(x: geometry.size.width * currentFloat - 1)
            }
        }
    }
    func wearColor(_ wear: Wear) -> Color {
        switch wear {
        case .factoryNew: return Color(hex: "#2ebf58")!
        case .minimalWear: return Color(hex: "#87c34a")!
        case .fieldTested: return Color(hex: "#eabd38")!
        case .wellWorn: return Color(hex: "#eb922a")!
        case .battleScarred: return Color(hex: "#e24e4d")!
        }
    }
}

struct WearEditorView: View {
    let skin: Skin
    @Binding var wearValue: Double
    var onConfirm: () -> Void
    
    @Environment(\.dismiss) var dismiss
    @State private var sliderValue: Double = 0.0
    @State private var inputValue: String = ""
    @FocusState private var isInputFocused: Bool
    
    var minF: Double { skin.min_float ?? 0.0 }
    var maxF: Double { skin.max_float ?? 1.0 }
    var cleanName: String { return skin.baseName }
    
    var dynamicPrice: String {
        let price = FuzzyPriceHelper.getPrice(skin: skin, wear: sliderValue, isStatTrak: false)
        return price > 0 ? String(format: "¥%.2f", price) : "---"
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    HStack(spacing: 15) {
                        CachedImage(url: skin.imageURL, transition: false)
                            .frame(width: 100, height: 80)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(skin.rarity?.swiftColor ?? .gray, lineWidth: 2))
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text(cleanName).font(.headline).lineLimit(2).minimumScaleFactor(0.8)
                            HStack(spacing: 8) {
                                Text(getWearName(for: sliderValue))
                                    .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.blue.opacity(0.1)).foregroundColor(.blue).cornerRadius(4)
                                Text(dynamicPrice)
                                    .font(.caption).fontWeight(.bold).padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.green.opacity(0.1)).foregroundColor(.green).cornerRadius(4)
                            }
                        }
                        Spacer()
                    }
                    .padding().background(Color(UIColor.secondarySystemBackground)).cornerRadius(12).padding(.horizontal)
                    Divider().padding(.horizontal)
                    
                    VStack(spacing: 25) {
                        WearBarView(currentFloat: sliderValue, minFloat: minF, maxFloat: maxF).frame(height: 24)
                        HStack {
                            Text("磨损数值:").foregroundColor(.secondary).font(.subheadline)
                            Spacer()
                            TextField("0.000000", text: $inputValue)
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                                .font(.system(.title3, design: .monospaced)).fontWeight(.bold)
                                .foregroundColor(.primary).frame(width: 200).padding(4)
                                .background(Color(UIColor.secondarySystemBackground).opacity(0.5)).cornerRadius(6)
                                .focused($isInputFocused)
                                .onChange(of: inputValue) { newValue in
                                    let filtered = newValue.filter { "0123456789.".contains($0) }
                                    if filtered.filter({ $0 == "." }).count > 1 { inputValue = String(filtered.dropLast()); return }
                                    if filtered != newValue { inputValue = filtered }
                                    if let val = Double(filtered) {
                                        if val >= 0 && val <= 1 { sliderValue = min(max(val, minF), maxF) }
                                    }
                                }
                                .onSubmit { formatInputValue() }
                                .onChange(of: isInputFocused) { focused in if !focused { formatInputValue() } }
                        }
                        VStack(spacing: 5) {
                            Slider(value: $sliderValue, in: minF...maxF) { editing in if editing { isInputFocused = false } }
                                .tint(.blue)
                                .onChange(of: sliderValue) { newVal in if !isInputFocused { inputValue = String(format: "%.6f", newVal) } }
                            HStack {
                                Text(String(format: "%.2f", minF)).font(.caption2)
                                Spacer()
                                Text(String(format: "%.2f", maxF)).font(.caption2)
                            }
                            .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal)
                    Spacer(minLength: 80)
                }
                .padding(.top, 20)
            }
            .navigationTitle("调整磨损").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: { wearValue = sliderValue; onConfirm(); dismiss() }) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 28))
                            .symbolRenderingMode(.palette).foregroundStyle(.white, .green).shadow(radius: 2)
                    }
                }
            }
        }
        .onAppear { sliderValue = max(min(wearValue, maxF), minF); formatInputValue() }
    }
    
    func getWearName(for float: Double) -> String {
        for wear in Wear.allCases { if wear.range.contains(float) { return wear.rawValue } }
        return "未知"
    }
    func formatInputValue() { inputValue = String(format: "%.6f", sliderValue) }
}

#Preview {
    ContentView()
}
