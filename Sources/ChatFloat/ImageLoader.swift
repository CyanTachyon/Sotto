import Foundation
import ImageIO
import UniformTypeIdentifiers
import ChatCore

struct ImagePreparation: Sendable { let images: [ModelImage]; let summary: String }
enum ImageLoader {
    struct Row: Decodable { let path: String; let status: String; let data: String? }
    struct Result: Decodable { let images: [Row] }
    static func prepare(snapshot: Snapshot, root: String, config: ModelConfig, chat: String = "") async -> ImagePreparation {
        let messages = snapshot.messages.filter { $0.image != nil }
        guard !messages.isEmpty else { return ImagePreparation(images: [], summary: "") }
        guard config.supportsVision else { return ImagePreparation(images: [], summary: "视觉已关闭 · \(messages.count) 条图片仅发送占位") }
        return await Task.detached {
            var output: [ModelImage] = []; var reasons: [String: Int] = [:]; var used = 0; var thumbnails = 0
            let paths = Array(Set(messages.compactMap { $0.image?.path }))
            var decoded: [String: Row] = [:]
            if !paths.isEmpty && !root.isEmpty && !chat.isEmpty {
                do {
                    let input = try JSONSerialization.data(withJSONObject: ["root": root, "chat": chat, "paths": paths, "inputBudget": min(400, config.imageBudgetMB * 8) * 1024 * 1024])
                    let result = try await DatabaseBridge.run(script: "media.py", input: input)
                    decoded = Dictionary(uniqueKeysWithValues: try JSONDecoder().decode(Result.self, from: result).images.map { ($0.path, $0) })
                } catch { reasons["图片读取失败", default: 0] += messages.count; return ImagePreparation(images: [], summary: "图片读取失败 · \(messages.count) 张未附上，文字照常发送") }
            }
            for message in messages {
                if Task.isCancelled { break }
                guard let path = message.image?.path, let row = decoded[path], let encoded = row.data, let data = Data(base64Encoded: encoded) else {
                    let code = message.image?.path.flatMap { decoded[$0]?.status } ?? "missing"
                    let label = ["v2_key_unavailable":"V2 图片密钥未匹配", "wxgf_requires_decoder":"WXGF 暂不能解码", "file_over_40mb":"单图超过 40 MB", "input_budget":"图片读取预算已满", "unsupported_format":"图片格式不支持"][code] ?? "附件缺失或不可读"
                    reasons[label, default: 0] += 1; continue
                }
                guard let jpeg = thumbnail(data) else { reasons["图片解码失败", default: 0] += 1; continue }
                guard used + jpeg.count <= config.imageBudgetMB * 1024 * 1024 else { reasons["图片发送预算已满", default: 0] += 1; continue }
                let isThumbnail = row.status == "decoded_thumbnail"
                if isThumbnail { thumbnails += 1 }
                used += jpeg.count; output.append(ModelImage(messageID: message.id, data: jpeg, quality: isThumbnail ? "仅缩略图，细节或文字可能不清楚" : "本地原图或中等尺寸缓存，最长边 1536 像素"))
            }
            let details = reasons.keys.sorted().map { "\($0)：\(reasons[$0]!)" }.joined(separator: "；")
            return ImagePreparation(images: output, summary: "已附 \(output.count)/\(messages.count) 张图片（其中 \(thumbnails) 张仅缩略图）· \(used / 1024) KB" + (details.isEmpty ? "" : "；未附上：" + details))
        }.value
    }
    static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1536, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let bytes = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { return nil }
        return bytes as Data
    }
}
