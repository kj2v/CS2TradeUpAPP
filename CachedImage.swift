import SwiftUI

// 1. 全局缓存池 (单例)
class ImageCache {
    // ✅ 修复点：使用闭包 {}() 来初始化并配置 shared
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // 配置缓存限制，防止内存爆炸
        cache.countLimit = 200 // 最多存200张图
        cache.totalCostLimit = 1024 * 1024 * 100 // 最多用100MB内存
        return cache
    }()
    
    // 私有化 init，防止外部意外创建 ImageCache() 实例
    private init() {}
}

// 2. 带缓存的图片视图
struct CachedImage: View {
    let url: URL?
    let transition: Bool // 是否开启动画
    
    @State private var image: UIImage?
    @State private var isLoading = false
    
    // 初始化方法，默认开启淡入动画
    init(url: URL?, transition: Bool = true) {
        self.url = url
        self.transition = transition
    }
    
    var body: some View {
        ZStack {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    // 只有刚加载出来时才做动画，如果有缓存直接显示
                    .transition(transition ? .opacity.animation(.easeOut(duration: 0.25)) : .identity)
            } else {
                // 占位图：淡淡的灰色
                Color.gray.opacity(0.1)
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                }
            }
        }
        .onAppear {
            loadImage()
        }
    }
    
    private func loadImage() {
        guard let url = url else { return }
        
        // A. 查缓存：如果内存里有，直接拿来用，不用联网！
        let cacheKey = url.absoluteString as NSString
        if let cachedImage = ImageCache.shared.object(forKey: cacheKey) {
            self.image = cachedImage
            return
        }
        
        // B. 没缓存：去下载
        isLoading = true
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let uiImage = UIImage(data: data) {
                    // C. 下载完：存入缓存，下次就不用下了
                    ImageCache.shared.setObject(uiImage, forKey: cacheKey)
                    
                    await MainActor.run {
                        self.image = uiImage
                        self.isLoading = false
                    }
                }
            } catch {
                // 下载失败保持占位图，不打印烦人的错误
                await MainActor.run { isLoading = false }
            }
        }
    }
}
