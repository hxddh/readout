import Foundation
import Testing
@testable import ReadoutCore

/// Help ▸ Performance's numbers (`PerfLog`).
@Suite struct PerfLogTests {
    @Test func theNewestOpensAndUpdatesAreKept() {
        var log = PerfLog()
        for i in 0..<12 { log.opened(i, file: "f\(i).md", applied: Double(i) / 10) }
        #expect(log.opens.count == PerfLog.kept)
        #expect(log.opens.first?.file == "f2.md")
        log.painted(11, seconds: 1.5)
        #expect(log.opens.last?.painted == 1.5)
        // Painted once: a later paint is not this open's.
        log.painted(11, seconds: 9)
        #expect(log.opens.last?.painted == 1.5)
        for i in 0..<15 { log.updated(seconds: Double(i)) }
        #expect(log.updates == (5..<15).map(Double.init))
    }

    /// Two README.md opening at once: each paint goes to its own open.
    @Test func twoFilesOfTheSameNameKeepTheirOwnTimes() {
        var log = PerfLog()
        log.opened(1, file: "README.md", applied: 0.2)
        log.opened(2, file: "README.md", applied: 0.3)
        log.painted(1, seconds: 0.4)
        log.painted(2, seconds: 0.6)
        #expect(log.opens.map(\.painted) == [0.4, 0.6])
    }

    @Test func timesReadInWholeMillisecondsAndTheMedianIsTheMiddle() {
        #expect(PerfLog.ms(0.4304) == "430 ms")
        #expect(PerfLog.ms(0.0386) == "39 ms")
        #expect(PerfLog.median([]) == nil)
        #expect(PerfLog.median([3, 1, 2]) == 2)
        #expect(PerfLog.median([4, 1, 2, 3]) == 2.5)
    }
}
