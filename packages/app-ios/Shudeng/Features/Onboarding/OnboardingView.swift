// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// 启动动画：黑白的一盏灯，淡出。纯装饰，不拦点击（盖住界面 1 秒多容易让人以为卡死）。
struct SplashOverlay: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 44, weight: .light))
                Text("书灯")
                    .font(.title.weight(.semibold))
                Text("一盏照书的灯")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("splash")
        .allowsHitTesting(false)
    }
}

/// 首次启动的一页引导：只讲「怎么开始」，看完点一下就进书库。
struct OnboardingView: View {
    var onDone: () -> Void

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 16) {
                    LampMark(size: 96)
                    Text("书灯")
                        .font(.title.weight(.semibold))
                    Text("一盏照书的灯。\n陪你读懂每一页。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer(minLength: 0)
                VStack(spacing: 12) {
                    Button {
                        onDone()
                    } label: {
                        Text("开始阅读")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color(.systemBackground))
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(Color.primary, in: Capsule())
                    }
                    .accessibilityIdentifier("onboarding.start")
                    Text("继续即开始使用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 28)
        }
    }
}

/// 书灯的标记：圆形灯头 + 一束光。
struct LampMark: View {
    var size: CGFloat = 96

    var body: some View {
        VStack(spacing: size * 0.04) {
            Circle()
                .fill(Color.primary)
                .frame(width: size * 0.18, height: size * 0.18)
            Capsule()
                .fill(Color.primary)
                .frame(width: size * 0.045, height: size * 0.16)
            LightCone()
                .fill(Color(.systemGray5))
                .frame(width: size * 0.6, height: size * 0.3)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 灯下的一束光：上窄下宽的梯形。
private struct LightCone: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset = rect.width * 0.16
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
