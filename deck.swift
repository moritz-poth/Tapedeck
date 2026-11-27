// The look of the 1960s tape deck from the design: grey metal panel, piano keys with a dish in a black tray,
// counter wheels, black rotary knobs. Shared by the record window, the editor and the app icon.
import SwiftUI

enum Deck {
    static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
    static let panel = rgb(0xdcdde0)
    static let ink = rgb(0x2b2b2b)
    static let label = rgb(0x3f3f3f)
    static let red = rgb(0xd63c1a)
    static let tray = rgb(0x141414)
    static let labelFont = Font.system(size: 10)
}

/// One piano key: light face, round dish darker at the top, white crescent at the bottom of the dish.
/// Pressed, it sinks 2 pt into the tray and gets darker.
struct DeckKeyFace: View {
    var down: Bool
    var dot = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let h: CGFloat = down ? 42 : 44
        let face = RoundedRectangle(cornerRadius: 4)
        ZStack(alignment: .top) {
            face.fill(LinearGradient(colors: down ? [Deck.rgb(0xcfcfd0), Deck.rgb(0xc3c3c4)] : [Deck.rgb(0xe7e7e8), Deck.rgb(0xd8d8d9)],
                                     startPoint: .top, endPoint: .bottom))
            // bevel: light top edge, darker front lip at the bottom
            VStack(spacing: 0) {
                Rectangle().fill(down ? .clear : Deck.rgb(0xf8f8f8)).frame(height: 1)
                Spacer(minLength: 0)
                Rectangle().fill(Deck.rgb(down ? 0xb3b3b4 : 0xc3c3c4)).frame(height: down ? 1 : 2)
            }
            .clipShape(face)
            if down {   // shadow of the tray edge falling onto the sunk key
                LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 4).clipShape(face)
            }
            Circle()
                .fill(LinearGradient(stops: [.init(color: Deck.rgb(down ? 0x9c9c9d : 0xb4b4b5), location: 0),
                                             .init(color: Deck.rgb(down ? 0xb8b8b9 : 0xcdcdce), location: 0.45),
                                             .init(color: Deck.rgb(down ? 0xcececf : 0xe4e4e5), location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(LinearGradient(colors: [.black.opacity(0.14), .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
                .frame(width: 36, height: 36)
                .padding(.top, down ? 2 : 3)
            Path { p in
                p.move(to: CGPoint(x: 16.5, y: 35))
                p.addQuadCurve(to: CGPoint(x: 29.5, y: 35), control: CGPoint(x: 23, y: 38.5))
            }
            .stroke(.white.opacity(down ? 0.55 : 0.95), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .offset(y: down ? -1 : 0)
            if dot {
                Circle().fill(down ? Deck.rgb(0xc2361a) : Deck.red)
                    .frame(width: 12, height: 12)
                    .padding(.top, down ? 14 : 15)
            }
        }
        .frame(width: 46, height: h)
        // disabled: washed out towards the panel colour (plain opacity would darken it over the black tray)
        .overlay(RoundedRectangle(cornerRadius: 4).fill(Deck.panel.opacity(enabled ? 0 : 0.6)))
        .padding(.top, down ? 2 : 0)
        .frame(width: 46, height: 44, alignment: .top)
        .contentShape(Rectangle())
    }
}

/// `latched` keeps the key down (a running recording, the current play direction).
struct DeckKeyStyle: ButtonStyle {
    var latched = false
    var dot = false
    func makeBody(configuration: Configuration) -> some View {
        DeckKeyFace(down: latched || configuration.isPressed, dot: dot)
    }
}

/// Keys side by side in the black tray.
struct KeyTray<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 2) { content }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Deck.tray))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 4)
    }
}

/// One-line labels under the keys of a tray, each centred under its key.
struct KeyLabels: View {
    var texts: [String]
    var spacing: CGFloat = 2   // 2 = keys in one tray; one tray per key: gap between trays + 4
    var body: some View {
        HStack(spacing: spacing) {
            ForEach(texts, id: \.self) { t in
                Text(t).font(Deck.labelFont).foregroundStyle(Deck.label).lineLimit(1).fixedSize()
                    .frame(width: 46)
            }
        }
        .padding(.horizontal, 2)
    }
}

/// Mechanical counter: white wheels with black digits; groups are set apart a little (minutes · seconds …).
struct CounterWheels: View {
    var groups: [String]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(groups.enumerated()), id: \.offset) { gi, g in
                ForEach(Array(g.enumerated()), id: \.offset) { ci, ch in
                    Text(String(ch))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Deck.rgb(0x111111))
                        .frame(width: 13, height: 18)
                        .background(LinearGradient(stops: [.init(color: Deck.rgb(0xc4c4c4), location: 0),
                                                           .init(color: Deck.rgb(0xfbfbfb), location: 0.3),
                                                           .init(color: Deck.rgb(0xfbfbfb), location: 0.7),
                                                           .init(color: Deck.rgb(0xc4c4c4), location: 1)],
                                                   startPoint: .top, endPoint: .bottom))
                        .padding(.leading, gi > 0 && ci == 0 ? 3 : 0)
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 2).fill(Deck.rgb(0x1a1a1a)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(groups.joined(separator: ":"))
    }
}

/// Selector in the counter's look: a white plate in a black frame with the current choice and a small arrow.
/// Clicking opens a normal macOS menu at the plate. `options` with an empty tag are separators.
struct DeckSelector: View {
    var title: String
    @Binding var selection: String
    var options: [(tag: String, name: String)]
    @Environment(\.isEnabled) private var enabled

    private var text: String { options.first { $0.tag == selection }?.name ?? "" }

    var body: some View {
        GeometryReader { geo in
            Button { popUp(below: geo.frame(in: .global)) } label: { plate }
                .buttonStyle(.plain)
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(text)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { popUp(below: nil) }
    }

    private var plate: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Deck.rgb(0x111111))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Deck.rgb(0x444444))
        }
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(LinearGradient(stops: [.init(color: Deck.rgb(0xc4c4c4), location: 0),
                                           .init(color: Deck.rgb(0xfbfbfb), location: 0.3),
                                           .init(color: Deck.rgb(0xfbfbfb), location: 0.7),
                                           .init(color: Deck.rgb(0xc4c4c4), location: 1)],
                                   startPoint: .top, endPoint: .bottom))
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 2).fill(Deck.rgb(0x1a1a1a)))
        .overlay(RoundedRectangle(cornerRadius: 2).fill(Deck.panel.opacity(enabled ? 0 : 0.5)))
        .contentShape(Rectangle())
    }

    /// `rect`: the plate in window coordinates (SwiftUI, top-left origin); nil = at the mouse.
    private func popUp(below rect: CGRect?) {
        let menu = NSMenu()
        for o in options {
            if o.tag.isEmpty { menu.addItem(.separator()); continue }
            let action = MenuAction { selection = o.tag }
            let item = NSMenuItem(title: o.name, action: #selector(MenuAction.run), keyEquivalent: "")
            item.target = action
            item.representedObject = action   // NSMenuItem holds its target only weakly
            item.state = o.tag == selection ? .on : .off
            menu.addItem(item)
        }
        if let rect, let view = NSApp.keyWindow?.contentView {
            menu.minimumWidth = rect.width
            // contentView is flipped-free: convert the SwiftUI top-left y to AppKit bottom-left
            let y = view.isFlipped ? rect.maxY + 2 : view.bounds.height - rect.maxY - 2
            menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: y), in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

private final class MenuAction: NSObject {
    let run_: () -> Void
    init(_ run: @escaping () -> Void) { run_ = run }
    @objc func run() { run_() }
}

/// Black rotary knob with a printed scale; drag up/down to turn it. `value` runs 0…1.
struct Knob: View {
    @Binding var value: Double
    var scale: [String]
    var name: String
    @State private var dragStart: Double?

    private func angle(_ v: Double) -> Double { -140 + v * 280 }

    var body: some View {
        ZStack {
            ForEach(Array(scale.enumerated()), id: \.offset) { i, t in
                let a = angle(Double(i) / Double(scale.count - 1)) * .pi / 180
                Text(t).font(.system(size: 7.5)).foregroundStyle(Deck.rgb(0x333333))
                    .position(x: 42 + 35 * sin(a), y: 39 - 31 * cos(a))
            }
            Circle()
                .fill(RadialGradient(colors: [Deck.rgb(0x555555), Deck.rgb(0x202020), Deck.rgb(0x121212)],
                                     center: UnitPoint(x: 0.45, y: 0.35), startRadius: 0, endRadius: 20))
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 2)
                .overlay(alignment: .top) {
                    Rectangle().fill(Deck.rgb(0xf2f2f2)).frame(width: 2, height: 11).padding(.top, 1)
                }
                .rotationEffect(.degrees(angle(value)))
                .position(x: 42, y: 39)
        }
        .frame(width: 84, height: 78)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                if dragStart == nil { dragStart = value }
                value = min(1, max(0, dragStart! - Double(g.translation.height - g.translation.width) / 160))
            }
            .onEnded { _ in dragStart = nil })
        .accessibilityElement()
        .accessibilityLabel(name)
        .accessibilityValue("\(Int((value * 100).rounded())) %")
        .accessibilityAdjustableAction { dir in
            value = min(1, max(0, value + (dir == .increment ? 0.1 : -0.1)))
        }
        .help("\(name): ziehen zum Drehen")
    }
}

// MARK: - App icon: the record and stop keys on the grey plate (`Tapedeck --render-icon out.png`)

struct IconView: View {
    var body: some View {
        Canvas { ctx, _ in
            // design units: a 200 × 200 icon, plate 196 wide → 824 px on Apple's 1024 grid
            let s = 824.0 / 196
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: (x - 100) * s + 512, y: (y - 100) * s + 512) }
            func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(origin: p(x, y), size: CGSize(width: w * s, height: h * s)) }
            func grad(_ hex: [UInt32], _ stops: [Double], _ rect: CGRect) -> GraphicsContext.Shading {
                .linearGradient(Gradient(stops: zip(hex, stops).map { .init(color: Deck.rgb($0), location: $1) }),
                                startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY))
            }
            let plateRect = r(2, 2, 196, 196)
            let plate = Path(roundedRect: plateRect, cornerRadius: 45 * s, style: .continuous)
            ctx.drawLayer { l in
                l.addFilter(.shadow(color: .black.opacity(0.3), radius: 14, y: 10))
                l.fill(plate, with: grad([0xe6e7e9, 0xd6d7da], [0, 1], plateRect))
            }
            ctx.stroke(plate, with: .color(Deck.rgb(0xb9bbbf)), lineWidth: 2 * s)
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: 4 * s))
                l.fill(Path(roundedRect: r(36, 73, 128, 66), cornerRadius: 7 * s), with: .color(.black.opacity(0.35)))
            }
            ctx.fill(Path(roundedRect: r(32, 65, 136, 70), cornerRadius: 7 * s), with: .color(Deck.tray))
            for kx in [35.0, 101] {
                let key = r(kx, 68, 64, 64)
                ctx.fill(Path(roundedRect: key, cornerRadius: 6 * s), with: grad([0xe9e9ea, 0xd5d5d6], [0, 1], key))
                var top = Path(); top.move(to: p(kx + 5, 69.5)); top.addLine(to: p(kx + 59, 69.5))
                ctx.stroke(top, with: .color(Deck.rgb(0xf9f9f9)), lineWidth: 1.5 * s)
                var lip = Path(); lip.move(to: p(kx + 4, 130)); lip.addLine(to: p(kx + 60, 130))
                ctx.stroke(lip, with: .color(Deck.rgb(0xbdbdbe)), lineWidth: 2.5 * s)
                let cx = kx + 32
                let dish = r(cx - 26, 72, 52, 52)
                ctx.fill(Path(ellipseIn: dish), with: grad([0xb2b2b3, 0xcccccd, 0xe5e5e6], [0, 0.45, 1], dish))
                var cres = Path(); cres.move(to: p(cx - 9, 119.5)); cres.addQuadCurve(to: p(cx + 9, 119.5), control: p(cx, 124.5))
                ctx.stroke(cres, with: .color(.white), style: StrokeStyle(lineWidth: 2.2 * s, lineCap: .round))
            }
            ctx.fill(Path(ellipseIn: r(58, 89, 18, 18)), with: .color(Deck.red))
        }
        .frame(width: 1024, height: 1024)
        .environment(\.colorScheme, .light)
    }
}

@MainActor func renderIcon(to path: String) {
    let r = ImageRenderer(content: IconView())
    r.scale = 1
    guard let cg = r.cgImage,
          let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { exit(1) }
    do { try png.write(to: URL(fileURLWithPath: path)) } catch { exit(1) }
}
