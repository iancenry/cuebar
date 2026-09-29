import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The painting, decoded once.
///
/// A real image is what gets this right: a mesh gradient can only produce
/// smooth colour fields, and this gets its depth from *structure* behind the
/// blur. A portrait crop suits the rail's ~0.27 aspect.
///
/// **This is Nintendo's Kirby, and it is here for local use only.** It is
/// not ours to ship, so it has to be replaced with something licensed for
/// distribution before Cuebar goes to anyone else. A generated replacement
/// was tried and rejected: it came out a plainer brown smudge with a visible
/// vignette edge, where this has a subject, a palette and a texture that
/// survive the 13pt blur. If it does get replaced, judge the candidate
/// *through* that blur — a 1/8-scale render blurred and restored is a good
/// stand-in — and don't let a substitute in without being shown it first.
///
/// Decoded once rather than per render: both the rail and the editor
/// re-render on every hover and keystroke, and re-decoding a JPEG each
/// time would show up.
enum BackdropArt {
    static let painting: NSImage? = {
        guard let url = Bundle.module.url(forResource: "Backdrop", withExtension: "jpg")
        else { return nil }
        return NSImage(contentsOf: url)
    }()

    /// Without the resource the field degrades to an elegant gradient
    /// rather than an empty rail.
    static var fallbackField: some View {
        MeshGradient(width: 4, height: 4, points: points, colors: colors, smoothsColors: true)
    }

    /// 4×4 control points in unit space. The centre is near black on
    /// purpose: the list sits there, and the field has to stay quiet where
    /// there is text.
    private static let points: [SIMD2<Float>] = [
        .init(x: 0.0, y: 0.0), .init(x: 0.33, y: 0.08), .init(x: 0.67, y: 0.04), .init(x: 1.0, y: 0.0),
        .init(x: 0.02, y: 0.35), .init(x: 0.35, y: 0.38), .init(x: 0.68, y: 0.34), .init(x: 0.98, y: 0.36),
        .init(x: 0.0, y: 0.7), .init(x: 0.34, y: 0.66), .init(x: 0.66, y: 0.72), .init(x: 1.0, y: 0.68),
        .init(x: 0.05, y: 1.0), .init(x: 0.36, y: 0.94), .init(x: 0.7, y: 0.98), .init(x: 1.0, y: 1.0),
    ]
    /// Antique palette — ochre, oxblood, verdigris, indigo.
    private static let colors: [Color] = [
        .init(red: 0.44, green: 0.27, blue: 0.11), .init(red: 0.33, green: 0.13, blue: 0.14),
        .init(red: 0.10, green: 0.26, blue: 0.27), .init(red: 0.08, green: 0.11, blue: 0.22),
        .init(red: 0.26, green: 0.17, blue: 0.10), .init(red: 0.07, green: 0.06, blue: 0.08),
        .init(red: 0.11, green: 0.10, blue: 0.20), .init(red: 0.06, green: 0.09, blue: 0.16),
        .init(red: 0.14, green: 0.10, blue: 0.13), .init(red: 0.09, green: 0.22, blue: 0.19),
        .init(red: 0.16, green: 0.11, blue: 0.10), .init(red: 0.07, green: 0.07, blue: 0.12),
        .init(red: 0.10, green: 0.19, blue: 0.16), .init(red: 0.12, green: 0.09, blue: 0.09),
        .init(red: 0.09, green: 0.14, blue: 0.22), .init(red: 0.05, green: 0.05, blue: 0.08),
    ]
}

/// The blurred painting, filling whatever it is given. No scrims — each
/// surface protects its own text differently.
struct PaintedField: View {
    var body: some View {
        if let painting = BackdropArt.painting {
            Image(nsImage: painting)
                .resizable()
                // The rail is ~0.27 aspect, the editor's is wider, and the
                // painting is 0.95 — so every use is a hard crop of the
                // middle. Scaled to fill keeps the arch and the two figures
                // and discards the wings.
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                // 13pt, not 40: enough to stop the fresco competing with
                // the text, little enough that the architecture still
                // reads as architecture. An earlier 26pt version was a
                // coloured wash with no subject in it.
                .blur(radius: 13, opaque: true)
                // Kept high, and darkened by scrims instead. The fresco's
                // mid-tones sit near 0.55; taking the image down to 0.55
                // opacity and *then* laying black over it landed the rail at
                // ~0.13 on a 0.086 base, which is arithmetically invisible.
                // Twice now "restrained" has meant "grey" — the paint has to
                // be seen, and the scrims are what protect the text.
                .opacity(0.62)
                .saturation(0.95)
        } else {
            BackdropArt.fallbackField
        }
    }
}

/// Library rail: paint behind the list, held down where the rows are.
struct SidebarBackdrop: View {
    var body: some View {
        ZStack {
            PaintedField()
            // Just enough to take the glare off the top of the fresco.
            Color.black.opacity(0.07)
            // The list is where the text is, so the paint is held down where
            // the rows are and left alone at the edges and the bottom. A
            // full-height wash would flatten the whole rail again.
            LinearGradient(colors: [CuePalette.surface.opacity(0.5),
                                    CuePalette.surface.opacity(0.14)],
                           startPoint: .top, endPoint: .bottom)
            // Separate the two columns by tone, not a hairline.
            LinearGradient(colors: [.clear, CuePalette.surface.opacity(0.6)],
                           startPoint: .leading, endPoint: .trailing)
            // Calm under the traffic lights, which float over this corner.
            LinearGradient(colors: [CuePalette.surface.opacity(0.5), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 90)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .allowsHitTesting(false)
    }
}

/// Edit mode: paint in the margins and around the page, never under the
/// writing. An editing session is minutes of looking rather than a glance,
/// and the page itself is an opaque card — so the field is only ever a
/// border here, which is what ties the two modes together without putting
/// a fresco under a paragraph.
struct EditorBackdrop: View {
    var body: some View {
        ZStack {
            PaintedField()
            // Heavier than the rail: the title and the footer sit directly
            // on this, with no card behind them to lift them off.
            LinearGradient(colors: [CuePalette.surface.opacity(0.9),
                                    CuePalette.surface.opacity(0.62),
                                    CuePalette.surface.opacity(0.78)],
                           startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }
}
