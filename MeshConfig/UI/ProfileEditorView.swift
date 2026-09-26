import SwiftUI

struct ProfileEditorView: View {
    @Binding var profile: FleetProfile
    @EnvironmentObject private var roster: DeviceRosterStore
    @State private var confirmRotate = false
    @State private var actionError: String?

    var body: some View {
        Form {
            Section("Name") {
                TextField("Profile name", text: $profile.name)
                    .textInputAutocapitalization(.words)
            }
            Section("LoRa") {
                LabeledContent("Preset", value: profile.lora.modemPreset.displayName)
                Text("ShortTurbo is locked for the TAK template.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Stepper(value: $profile.lora.frequencySlot, in: UInt32(1)...UInt32(100)) {
                    Text("Frequency slot \(profile.lora.frequencySlot)")
                }
                Toggle("Ignore MQTT", isOn: $profile.lora.ignoreMQTT)
                if !profile.lora.ignoreMQTT {
                    Text("TAK verify expects Ignore MQTT on. Apply will fail that check while this is off.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Picker("Region", selection: $profile.lora.region) {
                    ForEach(regionChoices, id: \.self) { region in
                        Text(region.displayName).tag(region)
                    }
                }
            }
            Section("Channel") {
                TextField("Channel name", text: $profile.channel.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if profile.channel.isDisallowedPrimaryName {
                    Text("Use a private name. LongFast and ShortFast cannot be the primary channel.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                LabeledContent("PSK") {
                    Text(profile.channel.pskRef.isConfigured ? "Key in Keychain" : "Will generate on save")
                        .foregroundStyle(.secondary)
                }
                Button("Generate if missing") {
                    do {
                        try FleetPSKStore.ensurePSK(for: &profile)
                    } catch {
                        actionError = error.localizedDescription
                    }
                }
                .disabled(profile.channel.pskRef.isConfigured)
                Button("Rotate fleet PSK…", role: .destructive) {
                    confirmRotate = true
                }
            }
            Section("Defaults for apply") {
                Picker("Default role", selection: $profile.defaultRole) {
                    Text(DeviceRole.takTracker.displayName).tag(DeviceRole.takTracker)
                    Text(DeviceRole.tak.displayName).tag(DeviceRole.tak)
                }
                LabeledContent("Rebroadcast", value: "LOCAL_ONLY")
                TextField("Time zone (optional POSIX TZ)", text: timezoneText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("Position") {
                Toggle("Smart Position", isOn: $profile.position.smartPosition)
                LabeledContent("Altitude", value: "HAE (ALTITUDE, not MSL)")
                Toggle("Geoidal separation", isOn: $profile.position.flags.geoidalSeparation)
                LabeledContent("GPS", value: profile.position.gpsMode.rawValue)
            }
            Section("Display") {
                Picker("Units", selection: $profile.display.units) {
                    Text("Imperial").tag(DisplayUnits.imperial)
                    Text("Metric").tag(DisplayUnits.metric)
                }
            }
            Section("Notes") {
                TextField("Notes", text: $profile.notes, axis: .vertical)
                    .lineLimit(3...6)
            }
        }
        .navigationTitle("Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            try? FleetPSKStore.ensurePSK(for: &profile)
            profile.updatedAt = Date()
        }
        .confirmationDialog("Rotate fleet PSK?", isPresented: $confirmRotate, titleVisibility: .visible) {
            Button("Rotate and require re-apply", role: .destructive) {
                rotate()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All radios on this fleet need a re-apply or they will not share the new channel key. This phone does not show the key.")
        }
        .alert("Could not update the key", isPresented: errorPresented) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private var regionChoices: [LoRaRegion] {
        LoRaRegion.allCases.filter { $0 != .unset || profile.lora.region == .unset }
    }

    private var timezoneText: Binding<String> {
        Binding(
            get: { profile.device.timezone ?? "" },
            set: { profile.device.timezone = $0.isEmpty ? nil : $0 }
        )
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )
    }

    private func rotate() {
        do {
            try FleetPSKStore.rotatePSK(for: &profile)
            roster.markProfileNeedsReapply(profile.id)
        } catch {
            actionError = error.localizedDescription
        }
    }
}
