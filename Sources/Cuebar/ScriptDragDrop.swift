import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PromptCore

/// Dragging scripts in and out of the library.
///
/// Three kinds of drag, told apart rather than guessed at:
///
/// - **A script out.** The row is a file: a plain-text copy, so it lands in
///   Finder, Mail, or anywhere else that takes text. Tags and folders are
///   Cuebar's business and don't travel.
/// - **A file in.** Anything we can read, including a folder, which is a
///   walk. Dropped on a folder row it is *filed* there; dropped anywhere
///   else it arrives beside whatever is selected.
/// - **A script in.** Dragged from the rail onto a folder: a move, not an
///   import, and the body is not re-decoded. Text that is neither becomes a
///   script — dropping a paragraph should do the obvious thing.
///
/// The receiving end is an AppKit `NSView` in a background layer, not
/// SwiftUI's `onDrop`. Two reasons, both learned the hard way: `onDrop`
/// takes part in hit testing, so covering the window with drop targets cost
/// it its buttons; and `NSTextView` answers a file drop by *inserting the
/// path as text*, which AppKit does before any SwiftUI drop target is
/// consulted. An AppKit view in the background is below the content, so it
/// cannot take a click, and removing the file type from the editor's
/// `readablePasteboardTypes` is what lets a dropped file travel this far
/// instead of landing in the script as a filename.
enum ScriptDrag {
    /// Declared in the bundle's `UTExportedTypeDeclarations`. Exported (not
    /// imported) because only Cuebar produces it.
    static let reference = UTType(exportedAs: "com.cuebar.script")

    /// The types this app is willing to receive.
    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [NSPasteboard.PasteboardType(reference.identifier),
         .fileURL,
         .string]
    }

    /// Identifiers, for the questions asked about a drag's contents.
    static var acceptedIdentifiers: Set<String> {
        Set(acceptedTypes.map(\.rawValue))
    }

    /// The drag ghost for one script: a real file, plus our own reference
    /// on the side.
    @MainActor
    static func provider(for doc: ScriptDocument) -> NSItemProvider? {
        guard let file = ScriptIO.temporaryFile(for: doc) else { return nil }
        let provider = NSItemProvider(contentsOf: file)
        provider?.suggestedName = file.lastPathComponent
        provider?.registerDataRepresentation(
            forTypeIdentifier: reference.identifier, visibility: .ownProcess) { completion in
            completion(Data(doc.id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }
}

/// What a drop turned out to be.
enum ScriptDrop {
    /// Scripts dragged out of a Cuebar list.
    case scripts([UUID])
    /// Files (and folders) from the file system.
    case files([URL])
    /// Text that is neither.
    case text(String)

    var isEmpty: Bool {
        switch self {
        case .scripts(let ids): return ids.isEmpty
        case .files(let urls): return urls.isEmpty
        case .text(let text): return text.isEmpty
        }
    }
}

/// The receiving view. In a background layer, so it is under the content
/// and cannot intercept a click.
final class ScriptDropView: NSView {
    var onDrop: ((ScriptDrop) -> Void)?
    var onTargetedChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(ScriptDrag.acceptedTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(ScriptDrag.acceptedTypes)
    }

    private func setTargeted(_ value: Bool) {
        onTargetedChange?(value)
    }

    /// Whether this drag is one we can use. A cursor shape that changes per
    /// drag target is the only feedback a drop target gets before the drop.
    private func accepts(_ sender: (any NSDraggingInfo)?) -> Bool {
        !ScriptDropView.types(sender).isDisjoint(with: ScriptDrag.acceptedIdentifiers)
    }


    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = accepts(sender)
        setTargeted(ok)
        return ok ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setTargeted(false)
    }

    override func prepareForDragOperation(_ sender: (any NSDraggingInfo)?) -> Bool {
        accepts(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        setTargeted(false)
        onDrop?(ScriptDropReader.read(sender.draggingPasteboard as NSPasteboard))
        return true
    }

    /// The types on the drag. AppKit routes a drag to this view because it
    /// registered for these, so the check is a plain intersection — no
    /// conformance walk needed, and none available (`UTType.supertype` is
    /// not public API).
    static func types(_ sender: (any NSDraggingInfo)?) -> Set<String> {
        guard let pasteboard = sender?.draggingPasteboard as NSPasteboard? else { return [] }
        var out: Set<String> = []
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types { out.insert(type.rawValue) }
        }
        return out
    }
}

/// Classifies a drag, in one fixed order.
///
/// Read straight off the drag's pasteboard rather than through
/// `NSItemProvider`: a drag already *has* its data loaded, and the
/// provider round trip is async — which would put the classification in a
/// Task, where a drop that has already finished is no longer something
/// anybody is waiting for.
@MainActor
enum ScriptDropReader {
    static func read(_ pasteboard: NSPasteboard) -> ScriptDrop {
        // 1. A script of ours, dragged from the rail.
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(
            ScriptDrag.reference.identifier)),
           let text = String(data: data, encoding: .utf8),
           let id = UUID(uuidString: text) {
            return .scripts([id])
        }
        // 2. Files, and folders — a folder is a walk when it is read.
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
        if !urls.isEmpty { return .files(urls) }
        // 3. Anything else is text.
        //
        // Never a path: AppKit answers a file drop with the file's *path* as
        // a string too, and that is exactly how a dropped document ends up
        // in the script as its own filename.
        if let text = pasteboard.string(forType: .string),
           !text.isEmpty, !text.hasPrefix("file:") {
            return .text(text)
        }
        return .scripts([])
    }
}

/// The SwiftUI face of `ScriptDropView`.
struct ScriptDropArea: NSViewRepresentable {
    var onTargetedChange: ((Bool) -> Void)?
    var onDrop: (ScriptDrop) -> Void

    func makeNSView(context: Context) -> ScriptDropView {
        let view = ScriptDropView(frame: .zero)
        view.onTargetedChange = onTargetedChange
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ nsView: ScriptDropView, context: Context) {
        // Re-assigned every render so the handler always sees the current
        // state. Nothing here is `@State`-backed on purpose: a drop that
        // arrives after the view was rebuilt must act on the live store, not
        // on a snapshot.
        nsView.onTargetedChange = onTargetedChange
        nsView.onDrop = onDrop
    }
}

extension View {
    /// Accept a script, a file, or a run of text, anywhere in this view's
    /// bounds. What to *do* with it — which folder, whether it becomes a
    /// script at all — is the caller's.
    func scriptDropArea(onTargetedChange: ((Bool) -> Void)? = nil,
                        perform: @escaping (ScriptDrop) -> Void) -> some View {
        background {
            ScriptDropArea(onTargetedChange: onTargetedChange, onDrop: perform)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The border drawn around a live drop target.
struct DropHighlight: ViewModifier {
    let isTargeted: Bool
    var radius: CGFloat = 10

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(CuePalette.peach, lineWidth: 2)
                .background(CuePalette.peach.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: radius))
                .allowsHitTesting(false)
                .opacity(isTargeted ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.12), value: isTargeted)
    }
}

extension View {
    func dropHighlight(_ isTargeted: Bool, radius: CGFloat = 10) -> some View {
        modifier(DropHighlight(isTargeted: isTargeted, radius: radius))
    }
}