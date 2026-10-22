import Carbon.HIToolbox

/// Global keyboard shortcuts. Carbon's hot keys still work everywhere and need no extra permission.
@MainActor
final class HotKeys {
    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    /// Shortcuts another app had already claimed.
    private(set) var unavailable: [String] = []

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKeys.actions[hotKey.id]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    func register(_ label: String, key: Int, modifiers: Int, action: @escaping () -> Void) {
        let id = UInt32(actions.count + refs.count + unavailable.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: 0x5357_564C, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            actions[id] = action
        } else {
            unavailable.append(label)
        }
    }
}
