import Foundation
import Testing
@testable import ClaudeStatusCore

@Test func hostIsFirstAncestorThatIsAnApp() {
    let parents: [Int32: Int32] = [100: 90, 90: 80, 80: 70, 70: 1]
    let host = ProcessTree.firstAncestor(of: 100, parent: { parents[$0] }, where: { $0 == 80 || $0 == 70 })
    #expect(host == 80)
}

@Test func hostSkipsTheSessionItself() {
    let host = ProcessTree.firstAncestor(of: 100, parent: { $0 == 100 ? 90 : nil }, where: { $0 == 100 || $0 == 90 })
    #expect(host == 90)
}

@Test func hostIsNilWithoutAppAncestor() {
    let parents: [Int32: Int32] = [100: 90, 90: 1]
    #expect(ProcessTree.firstAncestor(of: 100, parent: { parents[$0] }, where: { _ in false }) == nil)
}

@Test func hostWalkStopsOnCycle() {
    let host = ProcessTree.firstAncestor(of: 100, parent: { $0 == 100 ? 90 : 100 }, where: { _ in false })
    #expect(host == nil)
}

@Test func realParentOfCurrentProcess() {
    #expect(ProcessTree.parent(of: getpid()) == getppid())
}
