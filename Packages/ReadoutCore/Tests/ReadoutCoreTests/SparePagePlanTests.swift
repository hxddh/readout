import Foundation
import Testing
@testable import ReadoutCore

/// When the spare reader page is made again (`SparePagePlan`).
@Suite struct SparePagePlanTests {
    @Test func theNextSparePageWaitsForTheFirstPaintOrTheFallback() {
        var plan = SparePagePlan()
        // Nothing taken: a paint makes nothing.
        #expect(plan.painted() == false)
        let first = plan.taken()
        #expect(plan.waiting)
        // The page taken paints: the next spare page is made now, once.
        #expect(plan.painted() == true)
        #expect(plan.painted() == false)
        // Its fallback timer fires later: nothing is owed any more.
        #expect(plan.fallbackFired(first) == false)

        // No paint within the fallback: the timer makes it.
        let second = plan.taken()
        #expect(plan.fallbackFired(second) == true)
        #expect(plan.painted() == false)

        // Taken twice before either timer fires: only the later timer counts.
        let a = plan.taken(), b = plan.taken()
        #expect(plan.fallbackFired(a) == false)
        #expect(plan.waiting)
        #expect(plan.fallbackFired(b) == true)
        #expect(SparePagePlan.fallback == 3)
    }
}
