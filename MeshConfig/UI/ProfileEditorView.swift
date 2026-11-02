import SwiftUI

struct ProfileEditorView: View {
    @Binding var profile: FleetProfile
    @EnvironmentObject private var roster: DeviceRosterStore
    @State private var confirmRotate = false
    @State private var actionError: String?
    @State private var mqttPasswordDraft = ""
    @State private var replaceMQTTPassword = false
    @State private var wifiPasswordDrafts: [UUID: String] = [:]

    var body: some View {
        Form {
            Section("Name") {
                TextField("Profile name", text: $profile.name)
                    .textInputAutocapitalization(.words)
            }
            Section("LoRa") {
                Picker("Preset", selection: $profile.lora.modemPreset) {
                    ForEach(ModemPreset.pickerChoices(current: profile.lora.modemPreset), id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                Text("Every radio in this fleet must use the same preset. Changing it means re-applying every radio.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Stepper(value: $profile.lora.frequencySlot, in: UInt32(1)...UInt32(100)) {
                    Text("Frequency slot \(profile.lora.frequencySlot)")
                }
                LabeledContent("Ignore MQTT", value: "Off")
                LabeledContent("Hop limit", value: "3")
                LabeledContent("Transmit", value: "On")
                Text("Ignore MQTT is locked off so trackers receive iTAK/OTS messages the gateway relays over LoRa.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("Ok to MQTT (trackers)", isOn: $profile.lora.configOkToMQTT)
                Toggle("Ok to MQTT (gateway)", isOn: $profile.lora.gatewayConfigOkToMQTT)
                Text("Sets the ok_to_mqtt bit on outgoing packets. Default off: in field testing the gateway with Ok to MQTT on broke iTAK delivery.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                    Text(DeviceRole.clientBase.displayName).tag(DeviceRole.clientBase)
                    Text(DeviceRole.router.displayName).tag(DeviceRole.router)
                }
                Picker("Rebroadcast mode", selection: $profile.device.rebroadcastMode) {
                    ForEach(RebroadcastMode.fleetChoices, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text(profile.device.rebroadcastMode.shortHelp + " Applied to every radio in this fleet, every role.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("Time zone (optional POSIX TZ)", text: timezoneText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("Position") {
                Toggle("Smart Position", isOn: $profile.position.smartPosition)
                Stepper(value: $profile.position.smartMinimumDistance, in: UInt32(0)...UInt32(10_000), step: 5) {
                    Text("Smart minimum distance \(profile.position.smartMinimumDistance) m")
                }
                .disabled(!profile.position.smartPosition)
                Stepper(value: $profile.position.smartMinimumIntervalSecs, in: UInt32(0)...UInt32(86_400), step: 5) {
                    Text("Smart minimum interval \(profile.position.smartMinimumIntervalSecs) s")
                }
                .disabled(!profile.position.smartPosition)
                Stepper(value: $profile.position.broadcastSecs, in: UInt32(0)...UInt32(86_400), step: 15) {
                    Text("Broadcast interval \(profile.position.broadcastSecs) s")
                }
                Stepper(
                    value: $profile.position.gpsUpdateIntervalSecs,
                    in: PositionSettings.minimumGPSUpdateIntervalSecs...UInt32(86_400),
                    step: 30
                ) {
                    Text("GPS update interval \(profile.position.gpsUpdateIntervalSecs) s")
                }
                Text("Written in the one position config write. For distance and broadcast intervals, 0 lets the firmware use its own default. GPS update interval is at least 30 s.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
            Section("Server / MQTT") {
                TextField("MQTT host", text: $profile.mqtt.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", text: mqttPortText, prompt: Text(String(MQTTSettings.defaultPort)))
                    .keyboardType(.numberPad)
                TextField("Username", text: $profile.mqtt.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Root topic", text: $profile.mqtt.root)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if profile.mqtt.passwordRef.isConfigured && !replaceMQTTPassword {
                    LabeledContent("Password", value: "Saved in Keychain")
                    Button("Replace password") { replaceMQTTPassword = true }
                } else {
                    SecureField("MQTT password", text: $mqttPasswordDraft)
                    Button("Save password to Keychain") { saveMQTTPassword() }
                        .disabled(mqttPasswordDraft.isEmpty)
                }
                LabeledContent("Encryption", value: "Off")
                LabeledContent("JSON", value: "Off")
                LabeledContent("TLS", value: "Off")
                LabeledContent("Proxy to client", value: "Off")
                LabeledContent("Map reporting", value: "Off")
                Text("OpenTAKServer’s Meshtastic bridge only decodes unencrypted MQTT. The password is entered once and is not shown again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Wi-Fi for gateways") {
                if profile.wifiNetworks.isEmpty {
                    Text("No saved networks yet. A gateway needs one. Trackers do not receive Wi-Fi settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach($profile.wifiNetworks) { $network in
                    TextField("SSID", text: $network.ssid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if network.pskRef.isConfigured && wifiPasswordDrafts[network.id] == nil {
                        LabeledContent("Password", value: "Saved in Keychain")
                        Button("Replace password") { wifiPasswordDrafts[network.id] = "" }
                    } else {
                        SecureField("Wi-Fi password", text: wifiDraft(network.id))
                        Button("Save password to Keychain") { saveWiFiPassword(network.id) }
                            .disabled((wifiPasswordDrafts[network.id] ?? "").isEmpty)
                    }
                    Button("Remove network", role: .destructive) {
                        removeWiFi(network.id)
                    }
                }
                Button("Add Wi-Fi network") {
                    profile.wifiNetworks.append(WifiNetwork(ssid: ""))
                }
                Text("Only a device set to Gateway is given Wi-Fi. Turning Wi-Fi on disables Bluetooth after the radio reboots.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Notes") {
                TextField("Notes", text: $profile.notes, axis: .vertical)
                    .lineLimit(3...6)
            }
        }
        .navigationTitle("Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            if !mqttPasswordDraft.isEmpty { saveMQTTPassword() }
            for network in profile.wifiNetworks where !(wifiPasswordDrafts[network.id] ?? "").isEmpty {
                saveWiFiPassword(network.id)
            }
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

    /// Meshtastic stores the port inside `address` as host:port. Blank leaves no port (firmware default).
    private var mqttPortText: Binding<String> {
        Binding(
            get: { profile.mqtt.port.map(String.init) ?? "" },
            set: { text in
                let digits = text.filter(\.isNumber)
                profile.mqtt.port = digits.isEmpty ? nil : UInt16(digits)
            }
        )
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

    private func wifiDraft(_ id: UUID) -> Binding<String> {
        Binding(
            get: { wifiPasswordDrafts[id] ?? "" },
            set: { wifiPasswordDrafts[id] = $0 }
        )
    }

    private func saveMQTTPassword() {
        let secret = Data(mqttPasswordDraft.utf8)
        mqttPasswordDraft = ""
        guard !secret.isEmpty else { return }
        let account = GatewaySecretStore.mqttAccount(profileID: profile.id)
        do {
            try GatewaySecretStore.save(secret, account: account)
            profile.mqtt.passwordRef = KeychainSecretRef(keychainAccount: account)
            replaceMQTTPassword = false
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func saveWiFiPassword(_ id: UUID) {
        let draft = wifiPasswordDrafts[id] ?? ""
        wifiPasswordDrafts[id] = nil
        let secret = Data(draft.utf8)
        guard !secret.isEmpty, let index = profile.wifiNetworks.firstIndex(where: { $0.id == id }) else { return }
        let account = GatewaySecretStore.wifiAccount(networkID: id)
        do {
            try GatewaySecretStore.save(secret, account: account)
            profile.wifiNetworks[index].pskRef = KeychainSecretRef(keychainAccount: account)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func removeWiFi(_ id: UUID) {
        if let network = profile.wifiNetworks.first(where: { $0.id == id }) {
            try? GatewaySecretStore.delete(account: network.pskRef.keychainAccount)
        }
        wifiPasswordDrafts[id] = nil
        profile.wifiNetworks.removeAll { $0.id == id }
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
