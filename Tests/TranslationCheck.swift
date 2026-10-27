import Foundation

@main struct TranslationCheck {
    static func main() async throws {
        let original = "World leaders agree to a ceasefire after emergency talks"
        let result = try await translatePublicHeadline(original)
        assert(result != original && result.range(of: "[\u{4e00}-\u{9fff}]", options: .regularExpression) != nil)
        print("PASS: 公开英文标题已实际翻译为中文：\(result)")
    }
}
