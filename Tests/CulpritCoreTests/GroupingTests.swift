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
    let processes = [
        ProcessUsage(pid: 1, path: "", app: "Chrome", cores: 0.6),
        ProcessUsage(pid: 2, path: "", app: "node", cores: 1.0),
        ProcessUsage(pid: 3, path: "", app: "Chrome", cores: 0.9),
    ]
    let sample = RawSample(totalCores: 3.0, processes: processes, sawEveryProcess: true)
    let snap = snapshot(from: sample, at: Date(timeIntervalSince1970: 0))
    #expect(snap.apps.map(\.name) == ["Chrome", "node", shortLivedName])
    let partial = RawSample(totalCores: 3.0, processes: processes, sawEveryProcess: false)
    #expect(snapshot(from: partial, at: Date()).apps.last?.name == unidentifiedName)
    #expect(abs(snap.apps[0].cores - 1.5) < 1e-9)
    #expect(abs(snap.apps[2].cores - 0.5) < 1e-9)
}

@Test func smallGapIsNotReportedAsShortLived() {
    let sample = RawSample(totalCores: 1.1, processes: [ProcessUsage(pid: 1, path: "", app: "node", cores: 1.0)], sawEveryProcess: true)
    #expect(snapshot(from: sample, at: Date()).apps.map(\.name) == ["node"])
}

@Test func interpretersAreNamedWithTheirScript() {
    let python = "/opt/homebrew/Cellar/python@3.12/3.12.7/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"
    #expect(appName(path: python, arguments: [python, "scripts/cer.py", "qwen17"]) == "Python cer.py")
    #expect(appName(path: "/opt/homebrew/bin/node", arguments: ["node", "--no-warnings", "verify_shapes.mts", "x.json"]) == "node verify_shapes.mts")
    #expect(appName(path: "/usr/bin/python3", arguments: []) == "python3")
    #expect(appName(path: "/usr/bin/clang", arguments: ["clang", "main.c"]) == "clang")
}

@Test func inlineCodeAndEmptyArgumentsFallBackToTheInterpreterName() {
    #expect(appName(path: "/usr/bin/python3", arguments: ["python3", "-c", "import time\nwhile True: pass"]) == "python3")
    #expect(appName(path: "/opt/homebrew/bin/node", arguments: ["node", "-e", "for(;;){}"]) == "node")
    #expect(appName(path: "/opt/homebrew/bin/node", arguments: ["node", ""]) == "node")
}

@Test func parsesProcArgsBuffer() {
    var buffer: [UInt8] = [2, 0, 0, 0]
    buffer += Array("/usr/bin/python3\0\0\0".utf8)
    buffer += Array("python3\0a b.py\0HOME=/x\0".utf8)
    #expect(parseProcArgs(buffer) == ["python3", "a b.py"])
    #expect(parseProcArgs([1, 0]).isEmpty)
}
