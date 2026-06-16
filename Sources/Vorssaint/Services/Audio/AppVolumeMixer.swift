// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Accelerate
import AppKit
import AudioToolbox
import Combine
import CoreAudio

/// One app in the mixer: every audio-producing process it is responsible for,
/// rolled into a single row.
struct MixerApp: Identifiable, Equatable {
    /// Stable identity for persistence: the bundle id when there is one,
    /// otherwise the process name (pids recycle, names don't).
    let id: String
    let ownerPid: pid_t
    let name: String
    let audioObjects: [AudioObjectID]
    /// True while the app is actually emitting sound right now (shown as a
    /// live indicator). Apps appear in the mixer even when momentarily silent,
    /// as long as they hold an audio connection.
    let isPlaying: Bool
    var volume: Double
}

/// Per-app volume control, something macOS does not offer natively.
///
/// For every app the user turns down, a muted CoreAudio process tap removes
/// the app's sound from the output device, and an aggregate device re-renders
/// the tapped stream with the chosen gain (public API since macOS 14.4). Apps
/// at 100% are left completely untouched —
/// bit-perfect passthrough, zero overhead. Volumes persist per app and
/// re-apply when the app plays again.
final class AppVolumeMixer: ObservableObject {
    static let shared = AppVolumeMixer()

    static var isSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    /// Volumes run 0...2: 1.0 is 100% (untouched passthrough), up to 2.0 is a
    /// 200% boost for sources that play too quietly.
    static let maxVolume: Double = 2.0

    @Published private(set) var apps: [MixerApp] = []
    /// Set when tap creation fails with a permission error, so the panel can
    /// point at the System Audio Recording consent.
    @Published private(set) var needsPermission = false

    private var engines: [String: any GainEngine] = [:]
    /// Apps whose engine is being built off-main; suppresses duplicate builds
    /// while the slider keeps dragging.
    private var buildingEngines = Set<String>()
    private var lastAudibleVolume: [String: Double] = [:]
    private var listenerInstalled = false
    private var runningListeners = Set<AudioObjectID>()
    private var currentOutputDeviceUID: String?
    private var stopped = false
    private let buildQueue = DispatchQueue(label: "com.vorssaint.utils.mixer", qos: .userInitiated)

    private init() {}

    // MARK: - Lifecycle

    /// Starts watching audio processes. Saved volumes re-apply as soon as the
    /// matching app produces sound — no panel interaction needed.
    func start() {
        guard Self.isSupported else { return }
        stopped = false
        guard !listenerInstalled else { return }
        listenerInstalled = true
        installListener(selector: kAudioHardwarePropertyProcessObjectList)
        installListener(selector: kAudioHardwarePropertyDefaultOutputDevice)
        refreshApps()
    }

    /// Tears every tap down so all apps return to untouched system output.
    func stopAll() {
        stopped = true
        buildingEngines.removeAll()
        for engine in engines.values { engine.stop() }
        engines.removeAll()
    }

    private func installListener(selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            self?.refreshApps()
        }
    }

    private func subscribeToRunningChanges(of object: AudioObjectID) {
        guard !runningListeners.contains(object) else { return }
        runningListeners.insert(object)
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(object, &address, .main) { [weak self] _, _ in
            self?.refreshApps()
        }
    }

    // MARK: - Volume API (panel)

    /// 100% means bit-perfect passthrough (no tap). A value the UI would round to
    /// 100% counts as unity, so dragging near 100% or tapping reset both restore
    /// true passthrough; anything else (quieter or boosted) runs the gain engine.
    private func isUnity(_ volume: Double) -> Bool { abs(volume - 1) < 0.005 }

    func setVolume(_ volume: Double, for app: MixerApp) {
        let clamped = Defaults.sanitizedAppVolume(volume)
        persistVolume(clamped, for: app.id)
        if clamped > 0.001 { lastAudibleVolume[app.id] = clamped }
        if let index = apps.firstIndex(where: { $0.id == app.id }) {
            apps[index].volume = clamped
        }
        applyVolume(clamped, for: app)
    }

    func toggleMute(_ app: MixerApp) {
        if app.volume > 0.001 {
            lastAudibleVolume[app.id] = app.volume
            setVolume(0, for: app)
        } else {
            setVolume(lastAudibleVolume[app.id] ?? 1, for: app)
        }
    }

    /// Main-thread only. Engine creation happens off-main (CoreAudio object
    /// setup takes tens of milliseconds) and lands back here exactly once.
    private func applyVolume(_ volume: Double, for app: MixerApp) {
        guard !stopped else { return }
        if isUnity(volume) {
            // 100% only: remove the tap entirely, for true passthrough.
            engines.removeValue(forKey: app.id)?.stop()
            clearPermissionIfNoActiveAdjustments()
            return
        }
        if let engine = engines[app.id] {
            engine.gain = Float(volume)
            return
        }
        guard #available(macOS 14.4, *), !buildingEngines.contains(app.id) else { return }

        buildingEngines.insert(app.id)
        buildQueue.async { [weak self] in
            let engine = TapGainEngine(objects: app.audioObjects, gain: Float(volume))
            DispatchQueue.main.async {
                guard let self else {
                    engine?.stop()
                    return
                }
                self.buildingEngines.remove(app.id)
                guard !self.stopped else {
                    engine?.stop()
                    return
                }
                guard let engine else {
                    self.needsPermission = true
                    return
                }
                self.needsPermission = false
                // The slider may have moved (or returned to 100%) while the
                // engine was being built, or the app's audio objects may have
                // changed. Honor the latest state, never an old tap target.
                guard let latestApp = self.apps.first(where: { $0.id == app.id }) else {
                    engine.stop()
                    return
                }
                let latest = latestApp.volume
                if latestApp.audioObjects != engine.tappedObjects {
                    engine.stop()
                    self.applyVolume(latest, for: latestApp)
                    return
                }
                if engine.outputDeviceUID != self.currentOutputDeviceUID {
                    engine.stop()
                    self.applyVolume(latest, for: latestApp)
                    return
                }
                if self.isUnity(latest) {
                    engine.stop()
                    self.clearPermissionIfNoActiveAdjustments()
                } else {
                    engine.gain = Float(latest)
                    self.engines[app.id] = engine
                }
            }
        }
    }

    // MARK: - Process discovery

    private func refreshApps() {
        guard Self.isSupported else { return }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let saved = savedVolumes()
        let outputUID = Self.defaultOutputDeviceUID()
        let outputChanged = currentOutputDeviceUID != nil && outputUID != currentOutputDeviceUID
        if outputChanged {
            buildingEngines.removeAll()
            for engine in engines.values { engine.stop() }
            engines.removeAll()
        }
        currentOutputDeviceUID = outputUID

        var groups: [pid_t: [AudioObjectID]] = [:]
        var playing: Set<pid_t> = []
        var bundleHints: [pid_t: String] = [:]
        for object in Self.audioProcessObjects() {
            // Audio starting/stopping in a process flips IsRunningOutput
            // without changing the object list — subscribe per object.
            subscribeToRunningChanges(of: object)

            var pid: pid_t = -1
            guard Self.read(object, kAudioProcessPropertyPID, &pid), pid > 0, pid != ownPid else { continue }

            // Show every regular app that holds an audio connection, not only
            // the ones making sound this instant, so apps are adjustable before
            // they play and stay put between sounds.
            let owner = ResponsibleProcess.owner(of: pid)
            guard let app = NSRunningApplication(processIdentifier: owner),
                  app.activationPolicy == .regular else { continue }

            var running: UInt32 = 0
            _ = Self.read(object, kAudioProcessPropertyIsRunningOutput, &running)
            if running != 0 { playing.insert(owner) }

            groups[owner, default: []].append(object)
            if bundleHints[owner] == nil {
                bundleHints[owner] = app.bundleIdentifier
            }
        }

        var next: [MixerApp] = []
        for (owner, objects) in groups {
            let name = ResponsibleProcess.displayName(pid: owner, fallback: "pid \(owner)")
            let id = bundleHints[owner] ?? name
            next.append(MixerApp(id: id,
                                 ownerPid: owner,
                                 name: name,
                                 audioObjects: objects.sorted(),
                                 isPlaying: playing.contains(owner),
                                 volume: saved[id] ?? 1))
        }
        next.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        guard outputChanged || next != apps else { return }
        apps = next
        reconcileEngines(with: next)
        clearPermissionIfNoActiveAdjustments()
    }

    /// Brings the running engines in line with the current app list: drops
    /// taps for apps that stopped playing, retargets taps whose process set
    /// changed (new helper spawned), and applies saved volumes to newcomers.
    private func reconcileEngines(with apps: [MixerApp]) {
        let byId = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })

        for (id, engine) in Array(engines) {
            guard let app = byId[id] else {
                engine.stop()
                engines.removeValue(forKey: id)
                continue
            }
            if engine.tappedObjects != app.audioObjects {
                let gain = engine.gain
                engine.stop()
                engines.removeValue(forKey: id)
                applyVolume(Double(gain), for: app)
            }
        }

        for app in apps where !isUnity(app.volume) && engines[app.id] == nil {
            applyVolume(app.volume, for: app)
        }
    }

    // MARK: - Persistence

    private func savedVolumes() -> [String: Double] {
        let raw = UserDefaults.standard.dictionary(forKey: DefaultsKey.appVolumes) ?? [:]
        var sanitized: [String: Double] = [:]
        for (id, value) in raw {
            let number: Double?
            if let value = value as? Double {
                number = value
            } else if let value = value as? NSNumber {
                number = value.doubleValue
            } else {
                number = nil
            }
            guard let number, number.isFinite else { continue }
            sanitized[id] = Defaults.sanitizedAppVolume(number)
        }
        return sanitized
    }

    private func persistVolume(_ volume: Double, for id: String) {
        var volumes = savedVolumes()
        if isUnity(volume) {
            volumes.removeValue(forKey: id)
        } else {
            volumes[id] = volume
        }
        UserDefaults.standard.set(volumes, forKey: DefaultsKey.appVolumes)
    }

    private func clearPermissionIfNoActiveAdjustments() {
        guard needsPermission,
              !apps.contains(where: { !isUnity($0.volume) }),
              engines.isEmpty,
              buildingEngines.isEmpty else { return }
        needsPermission = false
    }

    // MARK: - CoreAudio plumbing

    private static func audioProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func defaultOutputDeviceUID() -> String? {
        var defaultDevice = AudioObjectID(0)
        guard read(AudioObjectID(kAudioObjectSystemObject),
                   kAudioHardwarePropertyDefaultOutputDevice, &defaultDevice),
              defaultDevice != 0 else { return nil }
        var uidRef: CFString = "" as CFString
        guard read(defaultDevice, kAudioDevicePropertyDeviceUID, &uidRef) else { return nil }
        return uidRef as String
    }

    @discardableResult
    fileprivate static func read<T>(_ object: AudioObjectID,
                                    _ selector: AudioObjectPropertySelector,
                                    _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size,
                                       UnsafeMutableRawPointer(pointer)) == noErr
        }
    }
}

// MARK: - Tap engine

/// Availability-erased face of the engine, so the mixer can store engines on
/// any macOS while the implementation requires 14.4.
private protocol GainEngine: AnyObject {
    var gain: Float { get set }
    var tappedObjects: [AudioObjectID] { get }
    var outputDeviceUID: String { get }
    func stop()
}

/// The audio path for one app whose volume is not 100% (quieter or boosted): a muted process
/// tap (the app's sound no longer reaches the speakers) feeding an aggregate
/// device whose IO proc re-renders the samples scaled by `gain` onto the real
/// output device.
@available(macOS 14.4, *)
private final class TapGainEngine: GainEngine {
    let tappedObjects: [AudioObjectID]
    let outputDeviceUID: String
    var gain: Float {
        get { gainBox.value }
        set { gainBox.value = min(max(newValue, 0), Float(AppVolumeMixer.maxVolume)) }
    }

    /// Read on the realtime audio thread, written from the main thread; a
    /// torn float write is harmless here (one transient sample scale).
    private final class GainBox { var value: Float = 1 }

    private let gainBox = GainBox()
    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var ioProc: AudioDeviceIOProcID?

    init?(objects: [AudioObjectID], gain: Float) {
        tappedObjects = objects
        gainBox.value = min(max(gain, 0), Float(AppVolumeMixer.maxVolume))

        var defaultDevice = AudioObjectID(0)
        guard AppVolumeMixer.read(AudioObjectID(kAudioObjectSystemObject),
                                  kAudioHardwarePropertyDefaultOutputDevice, &defaultDevice),
              defaultDevice != 0 else { return nil }
        var uidRef: CFString = "" as CFString
        guard AppVolumeMixer.read(defaultDevice, kAudioDevicePropertyDeviceUID, &uidRef) else { return nil }
        let outputUID = uidRef as String
        outputDeviceUID = outputUID

        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr, tapID != 0 else {
            return nil
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Vorssaint Mixer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr,
              aggregateID != 0 else {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        let box = gainBox
        guard AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil, { _, input, _, output, _ in
            let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let outputBuffers = UnsafeMutableAudioBufferListPointer(output)
            var gain = box.value
            let boosting = gain > 1
            var low: Float = -1, high: Float = 1
            for (index, inputBuffer) in inputBuffers.enumerated() where index < outputBuffers.count {
                guard let source = inputBuffer.mData?.assumingMemoryBound(to: Float.self),
                      let destination = outputBuffers[index].mData?.assumingMemoryBound(to: Float.self)
                else { continue }
                let frames = min(Int(inputBuffer.mDataByteSize),
                                 Int(outputBuffers[index].mDataByteSize)) / MemoryLayout<Float>.size
                vDSP_vsmul(source, 1, &gain, destination, 1, vDSP_Length(frames))
                // A boost can push samples past [-1, 1]; hard-limit so nothing out
                // of range reaches the device (a clean clip, never garbage).
                if boosting {
                    vDSP_vclip(destination, 1, &low, &high, destination, 1, vDSP_Length(frames))
                }
            }
        }) == noErr else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        guard AudioDeviceStart(aggregateID, ioProc) == noErr else {
            stop()
            return nil
        }
    }

    func stop() {
        if let ioProc {
            AudioDeviceStop(aggregateID, ioProc)
            AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            self.ioProc = nil
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    deinit { stop() }
}
