// Synthetic fixture only; never an installed-app or physical-device reader.
import Foundation

@_cdecl("healthcomp_capture_probe_ready")
@inline(never)
func probeReady() {
    FileHandle.standardError.write(Data("healthcomp-fixture-ready\n".utf8))
}

@_cdecl("healthcomp_capture_probe_finished")
@inline(never)
func probeFinished() {
    FileHandle.standardError.write(Data("healthcomp-fixture-finished\n".utf8))
}

@main
private enum StagingOperatorDebuggerFixture {
    static func main() {
        let controls = StagingScoringOperatorControls.shared
        let owner = StagingScoringCaptureOwner()
        controls.bind(owner)
        probeReady()
        guard controls.consumeArmRequest(for: owner) != nil else { exit(1) }
        controls.recordResponse("00000000-0000-4000-8000-000000000001", for: owner)
        probeFinished()
        controls.cancel(for: owner)
    }
}
