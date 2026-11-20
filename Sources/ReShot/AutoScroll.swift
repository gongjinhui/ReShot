import AppKit

/// Builds events without posting them, so their unit/axis/location contract is testable.
enum AutoScroll {
    static func event(step: Int32, at point: CGPoint) throws -> CGEvent {
        guard step > 0, let source = CGEventSource(stateID:.hidSystemState),
              let event = CGEvent(scrollWheelEvent2Source:source,units:.pixel,wheelCount:1,wheel1:-step,wheel2:0,wheel3:0) else {
            throw ReShotError(message:"无法创建自动滚动事件，请切换手动模式。")
        }
        event.location = point
        event.flags = []
        event.setIntegerValueField(.scrollWheelEventIsContinuous,value:1)
        return event
    }
    static func idleMessage(hasProgress: Bool) -> String {
        hasProgress ? "疑似到达末尾，请完成截图或继续尝试。" : "未检测到页面滚动：可能已在末尾或目标没有响应。可继续尝试或切换手动模式。"
    }
    static func selfTest() throws {
        let point = CGPoint(x:-450,y:320), scroll = try event(step:100,at:point)
        guard scroll.type == .scrollWheel, scroll.location == point, scroll.flags.isEmpty,
              scroll.getIntegerValueField(.scrollWheelEventIsContinuous) == 1,
              scroll.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -100,
              scroll.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0,
              idleMessage(hasProgress:false).contains("未检测到"), idleMessage(hasProgress:true).contains("末尾") else {
            throw ReShotError(message:"自动滚动事件或无进度提示测试失败。")
        }
        do { _ = try event(step:0,at:point); throw ReShotError(message:"零步长未被拒绝。") }
        catch let error as ReShotError where error.message == "零步长未被拒绝。" { throw error }
        catch {}
        print("PASS: downward pixel scroll, point coordinates, vertical axis, cleared modifiers, zero-step rejection and no-progress distinction; no input posted")
    }
}
