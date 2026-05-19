import SwiftUI

// MARK: - Master Quality Control (compact, embeddable anywhere)

/// A self-contained quality control panel that binds to a `StreamingTuning`
/// instance. Includes a master slider with preset snap-points and optional
/// fine-tune controls for FPS, bitrate, encoder quality, and resolution cap.
struct StreamingQualityControlView: View {
    @ObservedObject var tuning: StreamingTuning
    @State private var showAdvanced = false
    
    /// Whether the host session is currently active (shows "live" indicator).
    var isLive: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Label("Streaming Quality", systemImage: "slider.horizontal.3")
                    .font(.headline)
                
                Spacer()
                
                if isLive {
                    liveBadge
                }
            }
            
            // Master slider with preset labels
            masterSlider
            
            // Effective values readout
            effectiveValuesGrid
            
            // Advanced toggle
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showAdvanced.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Fine-Tune Controls")
                        .font(.subheadline)
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            
            if showAdvanced {
                advancedControls
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
    
    // MARK: - Master Slider
    
    private var masterSlider: some View {
        VStack(spacing: 6) {
            // Preset labels above the slider
            HStack {
                ForEach(Array(StreamingTuning.presetValues.enumerated()), id: \.offset) { _, preset in
                    Text(preset.name)
                        .font(.system(.caption2, design: .rounded))
                        .fontWeight(isNearPreset(preset.quality) ? .bold : .regular)
                        .foregroundStyle(isNearPreset(preset.quality) ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            
            // The slider
            Slider(value: $tuning.quality, in: 0...1) {
                Text("Quality")
            }
            .tint(sliderTint)
            
            // Min/max labels
            HStack {
                Text("Fastest")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Best Quality")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Effective Values Grid
    
    private var effectiveValuesGrid: some View {
        HStack(spacing: 12) {
            effectiveValuePill(
                icon: "speedometer",
                label: "\(tuning.effectiveFps) fps",
                isOverridden: tuning.fpsOverride != nil
            )
            effectiveValuePill(
                icon: "arrow.up.arrow.down.circle",
                label: "\(tuning.effectiveBitrateMbps) Mbps",
                isOverridden: tuning.bitrateOverride != nil
            )
            effectiveValuePill(
                icon: "sparkles",
                label: "\(Int(tuning.effectiveEncoderQuality * 100))%",
                isOverridden: tuning.encoderQualityOverride != nil
            )
            effectiveValuePill(
                icon: "rectangle.arrowtriangle.2.outward",
                label: dimensionLabel(tuning.effectiveMaxDimension),
                isOverridden: tuning.maxDimensionOverride != nil
            )
        }
    }
    
    private func effectiveValuePill(icon: String, label: String, isOverridden: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(label)
                .font(.system(.caption, design: .monospaced))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isOverridden ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isOverridden ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }
    
    // MARK: - Advanced Controls
    
    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Override individual parameters. Overridden values ignore the master slider.")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            // FPS override
            fpsControl
            
            // Bitrate override
            bitrateControl
            
            // Encoder quality override
            encoderQualityControl
            
            // Max dimension override
            dimensionControl
            
            // Reset button
            if hasAnyOverride {
                Button {
                    withAnimation { tuning.resetOverrides() }
                } label: {
                    Label("Reset All Overrides", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
        }
        .padding(.leading, 4)
    }
    
    // MARK: - FPS Control
    
    private var fpsControl: some View {
        HStack {
            overrideToggle(
                label: "Frame Rate",
                isActive: tuning.fpsOverride != nil,
                onToggle: {
                    if tuning.fpsOverride != nil {
                        tuning.fpsOverride = nil
                    } else {
                        tuning.fpsOverride = tuning.effectiveFps
                    }
                }
            )
            
            Spacer()
            
            if tuning.fpsOverride != nil {
                Picker("", selection: Binding(
                    get: { tuning.fpsOverride ?? tuning.effectiveFps },
                    set: { tuning.fpsOverride = $0 }
                )) {
                    ForEach(StreamingTuning.fpsOptions, id: \.self) { option in
                        Text("\(option) fps").tag(option)
                    }
                }
                .frame(width: 100)
            } else {
                Text("\(tuning.effectiveFps) fps")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Bitrate Control
    
    private var bitrateControl: some View {
        HStack {
            overrideToggle(
                label: "Bitrate",
                isActive: tuning.bitrateOverride != nil,
                onToggle: {
                    if tuning.bitrateOverride != nil {
                        tuning.bitrateOverride = nil
                    } else {
                        tuning.bitrateOverride = tuning.effectiveBitrateMbps
                    }
                }
            )
            
            Spacer()
            
            if tuning.bitrateOverride != nil {
                Picker("", selection: Binding(
                    get: { tuning.bitrateOverride ?? tuning.effectiveBitrateMbps },
                    set: { tuning.bitrateOverride = $0 }
                )) {
                    ForEach(StreamingTuning.bitrateOptions, id: \.self) { option in
                        Text("\(option) Mbps").tag(option)
                    }
                }
                .frame(width: 110)
            } else {
                Text("\(tuning.effectiveBitrateMbps) Mbps")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Encoder Quality Control
    
    private var encoderQualityControl: some View {
        HStack {
            overrideToggle(
                label: "Encoder Quality",
                isActive: tuning.encoderQualityOverride != nil,
                onToggle: {
                    if tuning.encoderQualityOverride != nil {
                        tuning.encoderQualityOverride = nil
                    } else {
                        tuning.encoderQualityOverride = tuning.effectiveEncoderQuality
                    }
                }
            )
            
            Spacer()
            
            if tuning.encoderQualityOverride != nil {
                Slider(
                    value: Binding(
                        get: { Double(tuning.encoderQualityOverride ?? tuning.effectiveEncoderQuality) },
                        set: { tuning.encoderQualityOverride = Float($0) }
                    ),
                    in: 0.2...1.0
                )
                .frame(width: 120)
                
                Text("\(Int(tuning.effectiveEncoderQuality * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 36, alignment: .trailing)
            } else {
                Text("\(Int(tuning.effectiveEncoderQuality * 100))%")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Dimension Control
    
    private var dimensionControl: some View {
        HStack {
            overrideToggle(
                label: "Max Resolution",
                isActive: tuning.maxDimensionOverride != nil,
                onToggle: {
                    if tuning.maxDimensionOverride != nil {
                        tuning.maxDimensionOverride = nil
                    } else {
                        tuning.maxDimensionOverride = tuning.effectiveMaxDimension
                    }
                }
            )
            
            Spacer()
            
            if tuning.maxDimensionOverride != nil {
                Picker("", selection: Binding(
                    get: { tuning.maxDimensionOverride ?? tuning.effectiveMaxDimension },
                    set: { tuning.maxDimensionOverride = $0 }
                )) {
                    ForEach(StreamingTuning.dimensionOptions, id: \.self) { option in
                        Text(dimensionLabel(option)).tag(option)
                    }
                }
                .frame(width: 110)
            } else {
                Text(dimensionLabel(tuning.effectiveMaxDimension))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Shared Components
    
    private func overrideToggle(label: String, isActive: Bool, onToggle: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { isActive }, set: { _ in onToggle() })) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            
            Text(label)
                .font(.subheadline)
                .foregroundStyle(isActive ? .primary : .secondary)
        }
        .frame(width: 180, alignment: .leading)
    }
    
    private var liveBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(.red)
                .frame(width: 6, height: 6)
            Text("LIVE")
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.red.opacity(0.1), in: Capsule())
    }
    
    // MARK: - Helpers
    
    private var sliderTint: Color {
        let q = tuning.quality
        if q < 0.25 { return .green }
        if q < 0.50 { return .yellow }
        if q < 0.75 { return .orange }
        return .blue
    }
    
    private func isNearPreset(_ presetValue: Double) -> Bool {
        abs(tuning.quality - presetValue) < 0.08
    }
    
    private var hasAnyOverride: Bool {
        tuning.fpsOverride != nil ||
        tuning.bitrateOverride != nil ||
        tuning.encoderQualityOverride != nil ||
        tuning.maxDimensionOverride != nil
    }
    
    private func dimensionLabel(_ dim: Int) -> String {
        switch dim {
        case ...1300:  return "720p"
        case ...1950:  return "1080p"
        case ...2600:  return "1440p"
        default:       return "4K"
        }
    }
}

// MARK: - Compact Slider (for embedding in toolbars / overlays)

/// Minimal quality slider with just the master control and readout.
/// Designed for the viewer toolbar or a floating host HUD.
struct CompactQualitySlider: View {
    @ObservedObject var tuning: StreamingTuning
    var isLive: Bool = false
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tortoise")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            
            Slider(value: $tuning.quality, in: 0...1)
                .frame(width: 120)
                .tint(sliderTint)
            
            Image(systemName: "hare")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            
            Text("\(tuning.effectiveFps)fps \(tuning.effectiveBitrateMbps)Mbps")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            
            if isLive {
                Circle()
                    .fill(.red)
                    .frame(width: 5, height: 5)
            }
        }
    }
    
    private var sliderTint: Color {
        let q = tuning.quality
        if q < 0.25 { return .green }
        if q < 0.50 { return .yellow }
        if q < 0.75 { return .orange }
        return .blue
    }
}

// MARK: - Preview

struct StreamingQualityControlView_Previews: PreviewProvider {
    static var previews: some View {
        StreamingQualityControlView(
            tuning: StreamingTuning(),
            isLive: true
        )
        .frame(width: 450)
        .padding()
    }
}
