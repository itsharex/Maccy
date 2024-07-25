import AppKit
import Defaults
import Sauce

class Clipboard {
  static let shared = Clipboard()

  typealias OnNewCopyHook = (HistoryItem) -> Void

  private var onNewCopyHooks: [OnNewCopyHook] = []
  var changeCount: Int

  private let pasteboard = NSPasteboard.general

  private var timer: Timer?

  private let dynamicTypePrefix = "dyn."
  private let microsoftSourcePrefix = "com.microsoft.ole.source."
  private let supportedTypes: Set<NSPasteboard.PasteboardType> = [
    .fileURL,
    .html,
    .png,
    .rtf,
    .string,
    .tiff
  ]
  private let ignoredTypes: Set<NSPasteboard.PasteboardType> = [
    .autoGenerated,
    .concealed,
    .transient
  ]
  private let modifiedTypes: Set<NSPasteboard.PasteboardType> = [.modified]

  private var enabledTypes: Set<NSPasteboard.PasteboardType> { Defaults[.enabledPasteboardTypes] }
  private var disabledTypes: Set<NSPasteboard.PasteboardType> { supportedTypes.subtracting(enabledTypes) }

  private var sourceApp: NSRunningApplication? { NSWorkspace.shared.frontmostApplication }

  init() {
    changeCount = pasteboard.changeCount
  }

  func onNewCopy(_ hook: @escaping OnNewCopyHook) {
    onNewCopyHooks.append(hook)
  }

  func clearHooks() {
    onNewCopyHooks = []
  }

  func start() {
    timer = Timer.scheduledTimer(
      timeInterval: Defaults[.clipboardCheckInterval],
      target: self,
      selector: #selector(checkForChangesInPasteboard),
      userInfo: nil,
      repeats: true
    )
  }

  func restart() {
    timer?.invalidate()
    start()
  }

  @MainActor 
  func copy(_ string: String) {
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
    checkForChangesInPasteboard()
  }

  @MainActor
  func copy(_ item: HistoryItem?, removeFormatting: Bool = false) {
    guard let item else { return }

    pasteboard.clearContents()
    var contents = item.contents

    if removeFormatting {
      let stringContents = contents.filter({
        NSPasteboard.PasteboardType($0.type) == .string
      })

      // If there is no string representation of data,
      // behave like we didn't have to remove formatting.
      if !stringContents.isEmpty {
        contents = stringContents
      }
    }

    for content in contents {
      guard content.type != NSPasteboard.PasteboardType.fileURL.rawValue else { continue }
      pasteboard.setData(content.value, forType: NSPasteboard.PasteboardType(content.type))
    }

    // Use writeObjects for file URLs so that multiple files that are copied actually work.
    // Only do this for file URLs because it causes an issue with some other data types (like formatted text)
    // where the item is pasted more than once.
    let fileURLItems: [NSPasteboardItem] = contents.compactMap { item in
      guard item.type == NSPasteboard.PasteboardType.fileURL.rawValue else { return nil }
      guard let value = item.value else { return nil }
      let pasteItem = NSPasteboardItem()
      pasteItem.setData(value, forType: NSPasteboard.PasteboardType(item.type))
      return pasteItem
    }
    pasteboard.writeObjects(fileURLItems)

    pasteboard.setString("", forType: .fromMaccy)

    Task {
      Notifier.notify(body: item.title, sound: .knock)
      checkForChangesInPasteboard()
    }
  }

  // Based on https://github.com/Clipy/Clipy/blob/develop/Clipy/Sources/Services/PasteService.swift.
  func paste() {
    Accessibility.check()

    // Add flag that left/right modifier key has been pressed.
    // See https://github.com/TermiT/Flycut/pull/18 for details.
    let cmdFlag = CGEventFlags(rawValue: UInt64(KeyChord.pasteKeyModifiers.rawValue) | 0x000008)
    var vCode = Sauce.shared.keyCode(for: KeyChord.pasteKey)

    // TODO: Fix pasting in the scenario below.
    //
    // Force QWERTY keycode when keyboard layout switches to
    // QWERTY upon pressing ⌘ key (e.g. "Dvorak - QWERTY ⌘").
    // See https://github.com/p0deje/Maccy/issues/482 for details.
    if KeyboardLayout.current.commandSwitchesToQWERTY && cmdFlag.contains(.maskCommand) {
      vCode = KeyChord.pasteKey.QWERTYKeyCode
    }

    let source = CGEventSource(stateID: .combinedSessionState)
    // Disable local keyboard events while pasting
    source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                       state: .eventSuppressionStateSuppressionInterval)

    let keyVDown = CGEvent(keyboardEventSource: source, virtualKey: vCode, keyDown: true)
    let keyVUp = CGEvent(keyboardEventSource: source, virtualKey: vCode, keyDown: false)
    keyVDown?.flags = cmdFlag
    keyVUp?.flags = cmdFlag
    keyVDown?.post(tap: .cgSessionEventTap)
    keyVUp?.post(tap: .cgSessionEventTap)
  }

  func clear() {
    guard Defaults[.clearSystemClipboard] else {
      return
    }

    pasteboard.clearContents()
  }

  @objc
  @MainActor
  func checkForChangesInPasteboard() {
    guard pasteboard.changeCount != changeCount else {
      return
    }

    changeCount = pasteboard.changeCount

    if Defaults[.ignoreEvents] {
      if Defaults[.ignoreOnlyNextEvent] {
        Defaults[.ignoreEvents] = false
        Defaults[.ignoreOnlyNextEvent] = false
      }

      return
    }

    // Reading types on NSPasteboard gives all the available
    // types - even the ones that are not present on the NSPasteboardItem.
    // See https://github.com/p0deje/Maccy/issues/241.
    if shouldIgnore(Set(pasteboard.types ?? [])) {
      return
    }

    if let sourceAppBundle = sourceApp?.bundleIdentifier, shouldIgnore(sourceAppBundle) {
      return
    }

    // Some applications (BBEdit, Edge) add 2 items to pasteboard when copying
    // so it's better to merge all data into a single record.
    // - https://github.com/p0deje/Maccy/issues/78
    // - https://github.com/p0deje/Maccy/issues/472
    var contents = [HistoryItemContent]()
    pasteboard.pasteboardItems?.forEach({ item in
      var types = Set(item.types)
      if types.contains(.string) && isEmptyString(item) && !richText(item) {
        return
      }

      if shouldIgnore(item) {
        return
      }

      types = types
        .subtracting(disabledTypes)
        .filter { !$0.rawValue.starts(with: dynamicTypePrefix) }
        .filter { !$0.rawValue.starts(with: microsoftSourcePrefix) }

      // Avoid reading Microsoft Word links from bookmarks and cross-references.
      // https://github.com/p0deje/Maccy/issues/613
      // https://github.com/p0deje/Maccy/issues/770
      if types.isSuperset(of: [.microsoftLinkSource, .microsoftObjectLink]) {
        types = types.subtracting([.microsoftLinkSource, .microsoftObjectLink, .pdf])
      }

      types.forEach { type in
        contents.append(HistoryItemContent(type: type.rawValue, value: item.data(forType: type)))
      }
    })

    guard !contents.isEmpty else {
      return
    }

    let historyItem = HistoryItem()
    Storage.shared.context.insert(historyItem)

    historyItem.contents = contents
    historyItem.application = sourceApp?.bundleIdentifier
    historyItem.title = historyItem.generateTitle()

    onNewCopyHooks.forEach({ $0(historyItem) })
  }

  private func shouldIgnore(_ types: Set<NSPasteboard.PasteboardType>) -> Bool {
    let ignoredTypes = self.ignoredTypes
      .union(Defaults[.ignoredPasteboardTypes].map({ NSPasteboard.PasteboardType($0) }))

    return types.isDisjoint(with: enabledTypes) ||
      !types.isDisjoint(with: ignoredTypes)
  }

  private func shouldIgnore(_ sourceAppBundle: String) -> Bool {
    if Defaults[.ignoreAllAppsExceptListed] {
      return !Defaults[.ignoredApps].contains(sourceAppBundle)
    } else {
      return Defaults[.ignoredApps].contains(sourceAppBundle)
    }
  }

  private func shouldIgnore(_ item: NSPasteboardItem) -> Bool {
    for regexp in Defaults[.ignoreRegexp] {
      if let string = item.string(forType: .string) {
        do {
          let regex = try NSRegularExpression(pattern: regexp)
          if regex.numberOfMatches(in: string, range: NSRange(string.startIndex..., in: string)) > 0 {
            return true
          }
        } catch {
          return false
        }
      }
    }
    return false
  }

  private func isEmptyString(_ item: NSPasteboardItem) -> Bool {
    guard let string = item.string(forType: .string) else {
      return true
    }

    return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func richText(_ item: NSPasteboardItem) -> Bool {
    if let rtf = item.data(forType: .rtf) {
      if let attributedString = NSAttributedString(rtf: rtf, documentAttributes: nil) {
        return !attributedString.string.isEmpty
      }
    }

    if let html = item.data(forType: .html) {
      if let attributedString = NSAttributedString(html: html, documentAttributes: nil) {
        return !attributedString.string.isEmpty
      }
    }

    return false
  }
}
