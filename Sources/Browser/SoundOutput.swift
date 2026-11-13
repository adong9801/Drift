import CoreAudio
import Foundation

/// Where the Mac is sending sound right now. Only for the diagnostics report:
/// a tab WebKit swears is playing, heard by nobody, is a question for the
/// output device rather than the page.
enum SoundOutput {

    static func summary() -> String {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return "could not find the Mac's sound output"
        }

        var name = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioObjectPropertyName
        _ = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }

        address.mScope = kAudioDevicePropertyScopeOutput
        func number<T>(_ selector: AudioObjectPropertySelector, _ start: T) -> T? {
            var value = start
            var length = UInt32(MemoryLayout<T>.size)
            address.mSelector = selector
            guard AudioObjectHasProperty(device, &address),
                  AudioObjectGetPropertyData(device, &address, 0, nil, &length, &value) == noErr
            else { return nil }
            return value
        }
        let muted = number(kAudioDevicePropertyMute, UInt32(0)).map { $0 == 0 ? "no" : "yes" } ?? "unknown"
        let volume = number(kAudioDevicePropertyVolumeScalar, Float32(0)).map { String(format: "%.2f", $0) } ?? "unknown"
        address.mScope = kAudioObjectPropertyScopeGlobal
        let running = number(kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(0)).map { $0 == 0 ? "no" : "yes" } ?? "unknown"

        return "Mac sound output: \(name as String), muted: \(muted), volume: \(volume), in use by some app: \(running)"
    }
}
