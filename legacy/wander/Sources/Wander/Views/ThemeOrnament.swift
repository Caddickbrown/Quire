//
//  ThemeOrnament.swift
//  Wander
//
//  The part of a theme that isn't type or colour: the ink wash behind Sumi, the
//  letterbox bars of Cinema, Constructivist's wedge, Broken grid's ghost
//  numeral, Memphis's confetti. Drawn behind the columns, never over them, and
//  never in the way of a click.
//

import SwiftUI

struct ThemeOrnament: View {
    let theme: Theme
    /// The ghost numeral, for the themes that want one.
    var caption: String = ""

    var body: some View {
        Group {
            switch theme.ornament {
            case .none:
                Color.clear
            case .wash:
                wash
            case .letterbox:
                letterbox
            case .wedge:
                wedge
            case .ghost:
                ghost
            case .confetti:
                confetti
            case .rail:
                rail
            }
        }
        .allowsHitTesting(false)
    }

    private var wash: some View {
        GeometryReader { geo in
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [theme.ink.opacity(0.13).color, theme.ink.opacity(0).color],
                                         center: .center, startRadius: 0, endRadius: geo.size.width * 0.28))
                    .frame(width: geo.size.width * 0.62, height: geo.size.width * 0.62)
                    .position(x: geo.size.width * 0.76, y: geo.size.height * 0.32)
                Circle()
                    .fill(RadialGradient(colors: [theme.ink.opacity(0.08).color, theme.ink.opacity(0).color],
                                         center: .center, startRadius: 0, endRadius: geo.size.width * 0.2))
                    .frame(width: geo.size.width * 0.4, height: geo.size.width * 0.4)
                    .position(x: geo.size.width * 0.9, y: geo.size.height * 0.86)
                Capsule()
                    .fill(theme.ink.opacity(0.16).color)
                    .frame(width: geo.size.width * 0.42, height: 15)
                    .rotationEffect(.degrees(-2))
                    .position(x: geo.size.width * 0.32, y: geo.size.height * 0.9)
            }
        }
    }

    private var letterbox: some View {
        VStack(spacing: 0) {
            Rectangle().fill(theme.panel.color).frame(height: 34)
            Spacer(minLength: 0)
            Rectangle().fill(theme.panel.color).frame(height: 34)
        }
    }

    private var wedge: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: w, y: 0))
                    path.addLine(to: CGPoint(x: w, y: h * 0.58))
                    path.addLine(to: CGPoint(x: w * 0.26, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h * 0.86))
                    path.closeSubpath()
                }
                .fill(theme.accent.opacity(0.14).color)
                Path { path in
                    path.move(to: CGPoint(x: w, y: h * 0.58))
                    path.addLine(to: CGPoint(x: w, y: h * 0.63))
                    path.addLine(to: CGPoint(x: w * 0.3, y: h))
                    path.addLine(to: CGPoint(x: w * 0.26, y: h))
                    path.closeSubpath()
                }
                .fill(theme.ink.opacity(0.18).color)
            }
        }
    }

    private var ghost: some View {
        GeometryReader { geo in
            Text(caption)
                .font(theme.displayFace.font(min(geo.size.height * 0.62, 300), weight: theme.displayWeight))
                .foregroundStyle(theme.ink.opacity(0.055).color)
                .position(x: geo.size.width * 0.13, y: geo.size.height * 0.56)
        }
    }

    /// Bauhaus's rail: the circle, triangle and square down the left edge, on a
    /// band of the theme's third colour.
    private var rail: some View {
        VStack(spacing: 18) {
            Circle().fill(theme.green.color).frame(width: 34, height: 34)
            Triangle().fill(theme.accent.color).frame(width: 36, height: 30)
            Rectangle().fill(theme.paper.color).frame(width: 32, height: 32)
            Spacer(minLength: 0)
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.tint.color)
    }

    private var confetti: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Circle().stroke(theme.tint.opacity(0.5).color, lineWidth: 6)
                    .frame(width: 62, height: 62)
                    .position(x: w * 0.08, y: h * 0.88)
                Triangle().fill(theme.green.opacity(0.65).color)
                    .frame(width: 58, height: 46)
                    .position(x: w * 0.93, y: h * 0.9)
                Squiggle().stroke(theme.accent.opacity(0.55).color,
                                  style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 120, height: 26)
                    .position(x: w * 0.82, y: h * 0.07)
                Capsule().fill(theme.tint.opacity(0.55).color)
                    .frame(width: 46, height: 10)
                    .rotationEffect(.degrees(-8))
                    .position(x: w * 0.52, y: h * 0.95)
            }
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct Squiggle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step = rect.width / 3
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for index in 0..<3 {
            let x = rect.minX + step * CGFloat(index)
            path.addQuadCurve(to: CGPoint(x: x + step, y: rect.maxY),
                              control: CGPoint(x: x + step / 2,
                                               y: index.isMultiple(of: 2) ? rect.minY : rect.maxY * 1.6))
        }
        return path
    }
}
