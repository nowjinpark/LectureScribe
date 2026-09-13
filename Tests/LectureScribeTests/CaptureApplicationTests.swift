import Testing
@testable import LectureScribe

struct CaptureApplicationTests {
    private let zoom = CaptureApplication(id: 100, name: "Zoom", bundleIdentifier: "us.zoom.xos")

    @Test func selectionSurvivesRelaunchAndDisplayNameChange() {
        let relaunched = CaptureApplication(id: 200, name: "Zoom Workplace", bundleIdentifier: "us.zoom.xos")
        #expect(zoom.resolved(in: [relaunched]) == relaunched)
    }

    @Test func recycledProcessIDCannotSelectAnotherApp() {
        let unrelated = CaptureApplication(id: 100, name: "Music", bundleIdentifier: "com.apple.Music")
        #expect(zoom.resolved(in: [unrelated]) == nil)
    }

    @Test func identicallyNamedAppsAndBundlePrefixesDoNotMatch() {
        let renamed = CaptureApplication(id: 200, name: "Zoom", bundleIdentifier: "example.unrelated")
        let helper = CaptureApplication(id: 201, name: "Zoom", bundleIdentifier: "us.zoom.xos.helper")
        #expect(zoom.resolved(in: [renamed, helper]) == nil)
    }

    @Test func originalProcessIsPreferredWhenMultipleInstancesExist() {
        let another = CaptureApplication(id: 200, name: "Zoom", bundleIdentifier: "us.zoom.xos")
        #expect(zoom.resolved(in: [another, zoom]) == zoom)
        #expect([another, zoom].filter(zoom.matches).count == 2)
    }

    @Test func unbundledProcessDoesNotMatchAllUnbundledApps() {
        let selected = CaptureApplication(id: 100, name: "Player", bundleIdentifier: "")
        let other = CaptureApplication(id: 200, name: "Player", bundleIdentifier: "")
        let reused = CaptureApplication(id: 100, name: "Other", bundleIdentifier: "")
        #expect(selected.resolved(in: [other, reused]) == nil)
        #expect(selected.resolved(in: [selected]) == selected)
    }
}
