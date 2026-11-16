import Foundation
import Testing
@testable import CulpritCore

@Test func helperRollsUpToOutermostApp() {
    let path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/142/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
    #expect(appName(path: path) == "Google Chrome")
}

@Test func xpcServiceBelongsToResponsibleApp() {
    let path = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
    #expect(appName(path: path, responsiblePath: "/Applications/Safari.app/Contents/MacOS/Safari") == "Safari")
    #expect(appName(path: path) == "com.apple.WebKit.WebContent")
    #expect(appName(path: path, responsiblePath: "/usr/libexec/launchd") == "com.apple.WebKit.WebContent")
}

@Test func plainBinaryKeepsItsOwnNameEvenWhenAnAppLaunchedIt() {
    #expect(appName(path: "/opt/homebrew/bin/node", responsiblePath: "/Applications/Terminal.app/Contents/MacOS/Terminal") == "node")
    #expect(appName(path: "kernel_task") == "kernel_task")
}

@Test func snapshotSumsByAppAndSortsBusiestFirst() {
    let sample = RawSample(totalCores: 3.0, processes: [
        ProcessUsage(pid: 1, path: "", app: "Chrome", cores: 0.6),
        ProcessUsage(pid: 2, path: "", app: "node", cores: 1.0),
        ProcessUsage(pid: 3, path: "", app: "Chrome", cores: 0.9),
    ])
    let snap = snapshot(from: sample, at: Date(timeIntervalSince1970: 0))
    #expect(snap.apps.map(\.name) == ["Chrome", "node", shortLivedName])
    #expect(abs(snap.apps[0].cores - 1.5) < 1e-9)
    #expect(abs(snap.apps[2].cores - 0.5) < 1e-9)
}

@Test func smallGapIsNotReportedAsShortLived() {
    let sample = RawSample(totalCores: 1.1, processes: [ProcessUsage(pid: 1, path: "", app: "node", cores: 1.0)])
    #expect(snapshot(from: sample, at: Date()).apps.map(\.name) == ["node"])
}
