// SPDX-License-Identifier: Apache-2.0
// BU-18: what is the macOS audio route actually doing?
//
// There is no `AVAudioSession` on macOS, so the app cannot report its own route
// the way it does on iOS (`RadioSession.lastKeyDownRoute`). This asks CoreAudio
// instead: the default input and output devices' nominal rate, and whether
// anything is running on them, every 50 ms, printing only transitions so the
// timestamps mean something. Needs no root and nothing from the app — correlate
// its output with the `=== BU-15 hold began` line the on-air test prints.
//
//     swiftc -O scripts/coreaudio-route-poll.swift -o /tmp/route-poll
//     /tmp/route-poll 240 > /tmp/rates.log &
//
// This is how BU-18 was found: a 44100 -> 16000 Hz swap on the default output is
// SCO coming up, and it stayed there for 69 s after an over.
import CoreAudio
import Foundation

func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
    return id
}

func rate(_ device: AudioDeviceID) -> Double {
    var value = Float64(0)
    var size = UInt32(MemoryLayout<Float64>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
    return value
}

func running(_ device: AudioDeviceID) -> Bool {
    var value = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
    return value != 0
}

func name(_ device: AudioDeviceID) -> String {
    // `Unmanaged`, not a bare `CFString`: this property returns a **retained**
    // reference, and handing CoreAudio a pointer to a managed variable both
    // leaks the callee's reference and lets ARC release one it never owned.
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
        let value
    else { return "?" }
    return value.takeRetainedValue() as String
}

let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
var last = ""
let deadline = Date().addingTimeInterval(Double(CommandLine.arguments.count > 1
    ? Int(CommandLine.arguments[1]) ?? 240 : 240))
while Date() < deadline {
    let input = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    let output = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    let line = "in=\(name(input)) \(Int(rate(input)))Hz running=\(running(input)) | "
        + "out=\(name(output)) \(Int(rate(output)))Hz running=\(running(output))"
    // Only transitions, so the log is readable and the timestamps mean something.
    if line != last {
        print("\(formatter.string(from: Date()))  \(line)")
        fflush(stdout)
        last = line
    }
    usleep(50_000)
}
