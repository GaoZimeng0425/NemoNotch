@testable import NemoNotch
import Testing

@Suite("CompletionPath")
struct CompletionPathTests {
    @Test("home prefix folds to ~")
    func foldsHome() {
        #expect(CompletionPath.display("/Users/me/Documents/NemoNotch", home: "/Users/me") == "~/Documents/NemoNotch")
    }

    @Test("home itself is ~ and a trailing slash on home is tolerated")
    func homeItself() {
        #expect(CompletionPath.display("/Users/me", home: "/Users/me/") == "~")
    }

    @Test("a sibling that merely shares the prefix is not folded")
    func siblingNotFolded() {
        #expect(CompletionPath.display("/Users/meow/proj", home: "/Users/me") == "/Users/meow/proj")
    }

    @Test("paths outside home stay absolute")
    func outsideHome() {
        #expect(CompletionPath.display("/opt/work", home: "/Users/me") == "/opt/work")
    }

    @Test("no path or an empty one shows no line")
    func missing() {
        #expect(CompletionPath.display(nil, home: "/Users/me") == nil)
        #expect(CompletionPath.display("", home: "/Users/me") == nil)
    }

    @Test("the detector carries the working directory onto the completed item")
    func detectorCarriesPath() {
        var detector = CompletionDetector()
        func candidate(_ active: Bool) -> CompletionCandidate {
            CompletionCandidate(
                key: "ai:1", name: "NemoNotch", isActive: active, source: .ai(.claude),
                subtitle: nil, tool: nil, model: nil, tokenDisplay: nil, duration: nil,
                path: "/Users/me/NemoNotch"
            )
        }
        _ = detector.step([candidate(true)])
        #expect(detector.step([candidate(false)]).first?.path == "/Users/me/NemoNotch")
    }

    @Test("a same-name refresh keeps the path unless the newer item has one")
    func mergeKeepsPath() {
        var old = CompletionItem(name: "NemoNotch", source: .ai(.claude))
        old.path = "/a"
        let bare = CompletionItem(name: "NemoNotch", source: .ai(.claude))
        #expect(CompletionFlashNames.merge(existing: [old], new: [bare]).first?.path == "/a")
        var newer = bare
        newer.path = "/b"
        #expect(CompletionFlashNames.merge(existing: [old], new: [newer]).first?.path == "/b")
    }
}
