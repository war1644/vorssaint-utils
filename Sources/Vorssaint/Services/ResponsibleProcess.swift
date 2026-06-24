// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Darwin

/// Maps helper processes to the app responsible for them and gives processes
/// a human name. Shared by the resource breakdown and the volume mixer, so
/// helper processes roll up into their app with its proper icon.
enum ResponsibleProcess {
    private static let iconCache: NSCache<NSNumber, NSImage> = {
        let cache = NSCache<NSNumber, NSImage>()
        cache.countLimit = 80
        cache.totalCostLimit = ImageThumbnailer.estimatedBitmapCost() * 80
        return cache
    }()

    /// `responsibility_get_pid_responsible_for_pid`, exported by libsystem and
    /// used by the system for the same grouping; resolved at runtime so a
    /// missing symbol degrades to per-process rows instead of breaking.
    private static let resolve: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */,
                                 "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    static func owner(of pid: pid_t) -> pid_t {
        guard let resolve else { return pid }
        let owner = resolve(pid)
        return owner > 0 ? owner : pid
    }

    /// Prefers the app's localized name; system processes fall back to their
    /// kernel-reported name (e.g. "WindowServer"), then to the caller's hint.
    static func displayName(pid: pid_t, fallback: String) -> String {
        if let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        var buffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            let name = String(cString: buffer)
            if !name.isEmpty { return name }
        }
        return fallback.trimmingCharacters(in: .whitespaces)
    }

    static func icon(for pid: pid_t) -> NSImage {
        let key = NSNumber(value: pid)
        if let cached = iconCache.object(forKey: key) { return cached }
        if isCurrentApp(pid: pid), let image = currentAppIcon() {
            iconCache.setObject(image, forKey: key, cost: ImageThumbnailer.estimatedBitmapCost())
            return image
        }
        let source = NSRunningApplication(processIdentifier: pid)?.icon
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
        let image = ImageThumbnailer.thumbnail(for: source) ?? source
        iconCache.setObject(image, forKey: key, cost: ImageThumbnailer.estimatedBitmapCost())
        return image
    }

    static func clearIconCache() {
        iconCache.removeAllObjects()
    }

    private static func isCurrentApp(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        if let bundleIdentifier = app.bundleIdentifier,
           bundleIdentifier == Bundle.main.bundleIdentifier {
            return true
        }
        return app.bundleURL?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    private static func currentAppIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = ImageThumbnailer.thumbnail(for: url) {
            return image
        }
        if let url = Bundle.main.url(forResource: "BrandMark", withExtension: "png"),
           let image = ImageThumbnailer.thumbnail(for: url) {
            return image
        }
        if let url = Bundle.main.url(forResource: "MenuBarIcon@2x", withExtension: "png"),
           let image = ImageThumbnailer.thumbnail(for: url) {
            return image
        }
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
           let image = ImageThumbnailer.thumbnail(for: url) {
            return image
        }
        return nil
    }
}
