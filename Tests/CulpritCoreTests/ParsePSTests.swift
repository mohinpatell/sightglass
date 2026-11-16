import Testing
@testable import CulpritCore

@Test func parsesMinutesSecondsAndPathsWithSpaces() {
    let rows = parsePS("""
        0 512:07.50 kernel_task
      412 1842:31.12 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
     9001   0:00.03 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
    """)
    #expect(rows.count == 3)
    #expect(rows[0] == PSRow(pid: 0, cpuNanos: 30_727_500_000_000, path: "kernel_task"))
    #expect(rows[1].cpuNanos == 110_551_120_000_000)
    #expect(rows[2].path == "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
}

@Test func skipsGarbageLines() {
    #expect(parsePS("\nnot a row\n12 abc /bin/x\n").isEmpty)
}
