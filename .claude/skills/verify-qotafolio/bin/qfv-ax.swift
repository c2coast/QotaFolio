#!/usr/bin/env swift
// qfv-ax: reads and presses one QotaFolio process's accessibility tree, by pid.
//
// It is compiled by `qfv build` into the lane's state folder and is called through `qfv`.
// It never posts keyboard or mouse events. `press` performs AXPress, the action VoiceOver
// performs, on one element of the given process. Every command prints one JSON document.
//
//   qfv-ax perm
//   qfv-ax tree    <pid> [max-depth]
//   qfv-ax find    <pid> <selector>
//   qfv-ax wait    <pid> <selector> [timeout-seconds]
//   qfv-ax press   <pid> <selector>
//   qfv-ax set     <pid> <selector> <text>  sets AXValue, as dictation or VoiceOver typing does
//   qfv-ax windows <pid>
//   qfv-ax window  <pid> <selector>      the CG window number that holds the element
//
// A selector is one or more `key=value` terms joined by `&`:
//   id=qotafolio.panel            exact AXIdentifier
//   role=AXButton                 exact AXRole
//   label=Refresh                 substring of title, description, value or help
//   nth=2                         the second element that matches the other terms
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

func emit(_ object: Any) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(0)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": message], options: [.sortedKeys])) ?? Data()
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(code)
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func text(_ value: AnyObject?) -> String? {
    guard let value else { return nil }
    if let string = value as? String { return string.isEmpty ? nil : string }
    if let number = value as? NSNumber { return number.stringValue }
    if CFGetTypeID(value) == AXValueGetTypeID() {
        let axValue = value as! AXValue
        var point = CGPoint.zero
        if AXValueGetValue(axValue, .cgPoint, &point) { return "\(point.x),\(point.y)" }
    }
    return nil
}

func frame(_ element: AXUIElement) -> [String: Int]? {
    guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    var extent = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &point)
    AXValueGetValue(size as! AXValue, .cgSize, &extent)
    return ["x": Int(point.x.rounded()), "y": Int(point.y.rounded()), "w": Int(extent.width.rounded()), "h": Int(extent.height.rounded())]
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

/// The process's top-level elements: its windows, and the extras menu bar that holds the
/// status item. The app element's own children omit the extras bar.
func roots(_ app: AXUIElement) -> [AXUIElement] {
    var result = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    if let extras = attribute(app, "AXExtrasMenuBar") {
        result.insert(extras as! AXUIElement, at: 0)
    }
    return result
}

func describe(_ element: AXUIElement) -> [String: Any] {
    var node: [String: Any] = [:]
    node["role"] = text(attribute(element, kAXRoleAttribute))
    node["subrole"] = text(attribute(element, kAXSubroleAttribute))
    node["id"] = text(attribute(element, "AXIdentifier"))
    node["title"] = text(attribute(element, kAXTitleAttribute))
    node["label"] = text(attribute(element, kAXDescriptionAttribute))
    node["value"] = text(attribute(element, kAXValueAttribute))
    node["help"] = text(attribute(element, kAXHelpAttribute))
    if let enabled = attribute(element, kAXEnabledAttribute) as? Bool, !enabled { node["enabled"] = false }
    node["frame"] = frame(element)
    return node
}

func tree(_ element: AXUIElement, depth: Int, maxDepth: Int) -> [String: Any] {
    var node = describe(element)
    if depth < maxDepth {
        let kids = children(element).map { tree($0, depth: depth + 1, maxDepth: maxDepth) }
        if !kids.isEmpty { node["children"] = kids }
    }
    return node
}

struct Selector {
    var id: String?
    var role: String?
    var label: String?
    var nth = 1

    init(_ raw: String) {
        for term in raw.split(separator: "&") {
            let parts = term.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { fail("bad selector term '\(term)'; use id=, role= or label=", code: 64) }
            switch parts[0] {
            case "id": id = parts[1]
            case "role": role = parts[1]
            case "label": label = parts[1]
            case "nth": nth = max(1, Int(parts[1]) ?? 1)
            default: fail("unknown selector key '\(parts[0])'; use id=, role=, label= or nth=", code: 64)
            }
        }
    }

    func matches(_ element: AXUIElement) -> Bool {
        if let id, text(attribute(element, "AXIdentifier")) != id { return false }
        if let role, text(attribute(element, kAXRoleAttribute)) != role { return false }
        if let label {
            let fields = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute]
                .compactMap { text(attribute(element, $0)) }
            if !fields.contains(where: { $0.localizedCaseInsensitiveContains(label) }) { return false }
        }
        return true
    }
}

/// The `nth` element, in depth-first document order, that matches every other term.
func search(_ elements: [AXUIElement], _ selector: Selector) -> AXUIElement? {
    var remaining = selector.nth
    func walk(_ elements: [AXUIElement], depth: Int) -> AXUIElement? {
        guard depth < 40 else { return nil }
        for element in elements {
            if selector.matches(element) {
                remaining -= 1
                if remaining == 0 { return element }
            }
            if let found = walk(children(element), depth: depth + 1) { return found }
        }
        return nil
    }
    return walk(elements, depth: 0)
}

func application(_ pidText: String) -> AXUIElement {
    guard let pid = pid_t(pidText), kill(pid, 0) == 0 else { fail("no process with pid \(pidText)", code: 3) }
    guard AXIsProcessTrusted() else {
        fail("this terminal has no Accessibility permission; reading the tree needs it", code: 4)
    }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 3)
    return app
}

func windowList(_ pid: pid_t) -> [[String: Any]] {
    let info = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    return info.compactMap { window in
        guard (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid else { return nil }
        let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
        return [
            "number": window[kCGWindowNumber as String] as? Int ?? 0,
            "layer": window[kCGWindowLayer as String] as? Int ?? 0,
            "onscreen": window[kCGWindowIsOnscreen as String] as? Bool ?? false,
            "name": window[kCGWindowName as String] as? String ?? "",
            "frame": [
                "x": Int(bounds["X"] ?? 0), "y": Int(bounds["Y"] ?? 0),
                "w": Int(bounds["Width"] ?? 0), "h": Int(bounds["Height"] ?? 0),
            ],
        ]
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { fail("usage: qfv-ax perm|tree|find|wait|press|windows|window …", code: 64) }

switch arguments[1] {
case "perm":
    emit(["ok": true, "screenRecording": CGPreflightScreenCaptureAccess(), "accessibility": AXIsProcessTrusted()])

case "tree":
    guard arguments.count >= 3 else { fail("usage: qfv-ax tree <pid> [max-depth]", code: 64) }
    let app = application(arguments[2])
    let maxDepth = arguments.count >= 4 ? Int(arguments[3]) ?? 30 : 30
    emit(["ok": true, "pid": Int(arguments[2])!, "roots": roots(app).map { tree($0, depth: 0, maxDepth: maxDepth) }])

case "find", "press", "window", "set":
    guard arguments.count >= 4 else { fail("usage: qfv-ax \(arguments[1]) <pid> <selector>", code: 64) }
    let app = application(arguments[2])
    guard let element = search(roots(app), Selector(arguments[3])) else {
        fail("no element matches '\(arguments[3])'", code: 2)
    }
    if arguments[1] == "find" { emit(["ok": true, "element": describe(element)]) }
    if arguments[1] == "set" {
        guard arguments.count >= 5 else { fail("usage: qfv-ax set <pid> <selector> <text>", code: 64) }
        // A switch, checkbox or slider takes a number; a text field takes the string.
        let numeric = ["AXCheckBox", "AXSlider", "AXRadioButton"].contains(text(attribute(element, kAXRoleAttribute)) ?? "")
        let value: CFTypeRef = numeric ? NSNumber(value: Double(arguments[4]) ?? 0) : arguments[4] as CFString
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value)
        guard result == .success else { fail("setting AXValue failed with AXError \(result.rawValue)") }
        emit(["ok": true, "set": describe(element)])
    }
    if arguments[1] == "press" {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else { fail("AXPress failed with AXError \(result.rawValue)") }
        emit(["ok": true, "pressed": describe(element)])
    }
    // The window that holds the element: the on-screen window of this process that overlaps
    // the element's frame the most, the smallest such window on a tie.
    guard let target = frame(element) else { fail("the element has no frame") }
    let rect = CGRect(x: target["x"]!, y: target["y"]!, width: target["w"]!, height: target["h"]!)
    let candidates = windowList(pid_t(arguments[2])!).filter { ($0["onscreen"] as? Bool) == true }
    let scored = candidates.compactMap { window -> (Int, CGFloat, CGFloat, [String: Any])? in
        let f = window["frame"] as! [String: Int]
        let bounds = CGRect(x: f["x"]!, y: f["y"]!, width: f["w"]!, height: f["h"]!)
        let overlap = bounds.intersection(rect)
        guard !overlap.isNull, overlap.width * overlap.height > 0 else { return nil }
        return (window["number"] as! Int, overlap.width * overlap.height, bounds.width * bounds.height, window)
    }
    guard let best = scored.max(by: { $0.1 == $1.1 ? $0.2 > $1.2 : $0.1 < $1.1 }) else {
        fail("no on-screen window of this process holds the element")
    }
    emit(["ok": true, "window": best.3, "element": describe(element)])

case "wait":
    guard arguments.count >= 4 else { fail("usage: qfv-ax wait <pid> <selector> [timeout-seconds]", code: 64) }
    let app = application(arguments[2])
    let selector = Selector(arguments[3])
    let timeout = arguments.count >= 5 ? Double(arguments[4]) ?? 10 : 10
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if let element = search(roots(app), selector) {
            emit(["ok": true, "waitedMs": Int(Date().timeIntervalSince(start) * 1000), "element": describe(element)])
        }
        usleep(150_000)
    }
    fail("no element matched '\(arguments[3])' within \(timeout) s", code: 2)

case "windows":
    guard arguments.count >= 3, let pid = pid_t(arguments[2]) else { fail("usage: qfv-ax windows <pid>", code: 64) }
    emit(["ok": true, "pid": Int(pid), "windows": windowList(pid)])

default:
    fail("unknown command \(arguments[1])", code: 64)
}
