import Foundation

/// 一条指标的滑动历史，给侧栏那些小折线图当数据源。
///
/// 定长：满了以后从头上挤掉最旧的一个，所以 `values` 永远是「最近 capacity 次采样」，
/// 下标越大越新。图是**右对齐**画的（最新的一点贴右边缘），所以点数不足时右边有线、左边留白，
/// 而不是把几个点拉满整幅宽度 —— 后者会让 x 轴的时间刻度随点数变化，读起来是假的。
public struct MetricHistory: Equatable {

    /// 最多留几个采样点。
    public let capacity: Int

    /// 由旧到新。长度不超过 `capacity`。
    public private(set) var values: [Double] = []

    /// 默认 120 点：2 秒一采就是 4 分钟，够看出「刚才那一下尖峰」。
    public init(capacity: Int = 120) {
        self.capacity = max(1, capacity)
    }

    public var isEmpty: Bool { values.isEmpty }

    public var count: Int { values.count }

    /// 最新一个采样点。没有采样时 nil。
    public var latest: Double? { values.last }

    /// 窗口内的峰值。没有采样时 nil。折线的 y 轴上限要用它（网络、负载没有固定量程）。
    public var maximum: Double? { values.max() }

    public mutating func append(_ value: Double) {
        values.append(value)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }

    /// 数据源已经失效（例如远端重启）时清空。
    public mutating func removeAll() {
        values.removeAll()
    }
}
