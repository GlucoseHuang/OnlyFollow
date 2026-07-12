import Foundation

/// 搜索分词 + 评分工具
/// 设计目标：
/// - 支持中日韩（CJK）：按字符 bigram 切，避免按空格切分成单字导致"周杰伦"搜不到
/// - 支持空格分隔的多关键词：用户输入"老番茄 新视频"时两个词都要匹配
/// - 支持英文/数字：按非字母数字字符切分后保留
/// - 评分简单可解释：标题命中权重 > UP 主名命中权重
/// - 预计算：VideoRecord 入库时一次性分词存到 titleTokens / authorTokens，搜索时只做交集
enum SearchTokenizer {
    /// 给一段文本做分词，返回 token 数组（不去重，调用方自行 unique）
    /// - 大写转小写
    /// - CJK 段落生成 2-char sliding window bigram + 单字
    /// - 非 CJK 段落按非字母数字字符切分，保留连续字母/数字段
    /// - 空白 / 标点 跳过（不当作 token 的一部分）
    static func tokens(for text: String) -> [String] {
        var result: [String] = []
        let lower = text.lowercased()
        var i = lower.startIndex
        while i < lower.endIndex {
            let c = lower[i]
            if isCJK(c) {
                // CJK 段：找到连续 CJK 字符
                let segStart = i
                var j = lower.index(after: i)
                while j < lower.endIndex, isCJK(lower[j]) {
                    j = lower.index(after: j)
                }
                let segment = String(lower[segStart..<j])
                emitCJKSegment(segment, into: &result)
                i = j
            } else if c.isLetter || c.isNumber {
                // 非 CJK word 段：找到连续字母/数字
                let segStart = i
                var j = lower.index(after: i)
                while j < lower.endIndex, !isCJK(lower[j]), (lower[j].isLetter || lower[j].isNumber) {
                    j = lower.index(after: j)
                }
                result.append(String(lower[segStart..<j]))
                i = j
            } else {
                // 空白 / 标点 / emoji：跳过
                i = lower.index(after: i)
            }
        }
        return result
    }

    /// 给 query 做同样的分词
    static func queryTokens(for query: String) -> [String] {
        tokens(for: query)
    }

    /// 一次性分词 + 去重 + 空格拼接,得到可存储的"预计算 token 串"
    /// - 用于 VideoRecord 入库时写到 titleTokens / authorTokens 字段
    /// - 也用于远端 DTO 缺失 token 时,merge 进本地时现场算出再写回(lazy-fill)
    static func tokenString(for text: String) -> String {
        var seen = Set<String>()
        var unique: [String] = []
        for t in tokens(for: text) where !seen.contains(t) {
            seen.insert(t)
            unique.append(t)
        }
        return unique.joined(separator: " ")
    }

    /// 计算一条 VideoRecord 对应搜索 query 的相关分
    /// 逻辑：每个 query token 在"title-tokens"和"author-tokens"里各加分
    ///   - 标题命中：每个 token +10
    ///   - UP 主名命中：每个 token +5
    /// 同时 query token 越长越值钱：单字 token 不加权，多字 token ×2
    /// - 返回 0 表示不相关
    static func score(query: [String], titleTokens: Set<String>, authorTokens: Set<String>) -> Int {
        if query.isEmpty { return 0 }
        var score = 0
        for token in query {
            let weight = token.count >= 2 ? 2 : 1
            if titleTokens.contains(token) { score += 10 * weight }
            if authorTokens.contains(token) { score += 5 * weight }
        }
        return score
    }

    // MARK: - 私有辅助

    /// 给一个纯 CJK 段生成 bigram + 单字 token
    private static func emitCJKSegment(_ segment: String, into result: inout [String]) {
        guard !segment.isEmpty else { return }
        let chars = Array(segment)
        if chars.count >= 2 {
            for k in 0..<(chars.count - 1) {
                result.append(String([chars[k], chars[k + 1]]))
            }
        }
        // 单字也保留，避免 1 字查询失败
        for ch in chars {
            result.append(String(ch))
        }
    }

    private static func isCJK(_ scalar: Character) -> Bool {
        // 覆盖：中日韩统一表意文字 + 平假名 + 片假名 + 韩文
        guard let v = scalar.unicodeScalars.first?.value else { return false }
        // 核心 CJK 范围
        if (0x4E00...0x9FFF).contains(v)        // CJK Unified Ideographs
            || (0x3040...0x309F).contains(v)    // Hiragana
            || (0x30A0...0x30FF).contains(v)    // Katakana
            || (0xAC00...0xD7AF).contains(v)    // Hangul Syllables
            || (0x3400...0x4DBF).contains(v) {  // CJK Extension A
            return true
        }
        // Halfwidth/Fullwidth Forms (0xFF00-0xFFEF):
        // 只保留字母/数字/假名,排除全角标点("！" "：" "？" 等)
        if (0xFF66...0xFF9F).contains(v) { return true }  // Halfwidth Katakana
        if (0xFFA0...0xFFDC).contains(v) { return true }  // Halfwidth Hangul
        if (0xFF10...0xFF19).contains(v) { return true }  // Fullwidth Digits
        if (0xFF21...0xFF3A).contains(v) { return true }  // Fullwidth Uppercase
        if (0xFF41...0xFF5A).contains(v) { return true }  // Fullwidth Lowercase
        return false
    }
}
