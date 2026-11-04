import Foundation
import Testing
@testable import ReadoutCore

/// Help ▸ Performance's numbers (`PerfLog`).
@Suite struct PerfLogTests {
    @Test func theNewestOpensAndUpdatesAreKept() {
        var log = PerfLog()
        for i in 0..<12 { log.opened("f\(i).md", applied: Double(i) / 10) }
        #expect(log.opens.count == PerfLog.kept)
        #expect(log.opens.first?.file == "f2.md")
        log.painted("f11.md", seconds: 1.5)
        #expect(log.opens.last?.painted == 1.5)
        // Painted once: a later paint of the same file is not this open's.
        log.painted("f11.md", seconds: 9)
        #expect(log.opens.last?.painted == 1.5)
        for i in 0..<15 { log.updated(seconds: Double(i)) }
        #expect(log.updates == (5..<15).map(Double.init))
    }

    @Test func timesReadInWholeMillisecondsAndTheMedianIsTheMiddle() {
        #expect(PerfLog.ms(0.4304) == "430 ms")
        #expect(PerfLog.ms(0.0386) == "39 ms")
        #expect(PerfLog.median([]) == nil)
        #expect(PerfLog.median([3, 1, 2]) == 2)
        #expect(PerfLog.median([4, 1, 2, 3]) == 2.5)
    }
}
