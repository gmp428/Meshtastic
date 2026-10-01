import SwiftUI

struct DevicesRosterView: View {
    @EnvironmentObject private var library: FleetLibrary
    @EnvironmentObject private var roster: DeviceRosterStore
    @State private var pendingRemove: ConfiguredDevice?

    var body: some View {
        NavigationStack {
            List {
                ForEach(sortedDevices) { device in
                    NavigationLink(value: device.id) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(device.longName ?? device.displayName)
                                    .font(.headline)
                                if let shortName = device.shortName {
                                    Text(shortName)
                                        .font(.caption.monospaced())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                                Spacer()
                                StatusBadge(status: device.lastStatus)
                            }
                            HStack(spacing: 8) {
                                Text(device.function.displayName)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.quaternary, in: Capsule())
                                RoleChip(role: device.role)
                                Text(profileName(for: device.profileID))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Text(appliedLine(device))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            pendingRemove = device
                        }
                    }
                }
            }
            .navigationTitle("Devices")
            .navigationDestination(for: UUID.self) { id in
                if roster.device(id: id) != nil {
                    DeviceDetailView(deviceID: id)
                } else {
                    ContentUnavailableView("Radio missing", systemImage: "questionmark.circle")
                }
            }
            .overlay {
                if roster.devices.isEmpty {
                    ContentUnavailableView(
                        "No radios yet",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("A radio is added here after you apply a profile. Removing it later only edits this list.")
                    )
                }
            }
            .confirmationDialog(
                "Remove from roster?",
                isPresented: removePresented,
                titleVisibility: .visible,
                presenting: pendingRemove
            ) { device in
                Button("Remove from this phone", role: .destructive) {
                    roster.remove(device.id)
                    pendingRemove = nil
                }
                Button("Cancel", role: .cancel) { pendingRemove = nil }
            } message: { _ in
                Text("This does not factory-reset the radio. It only removes the row on this phone.")
            }
        }
    }

    private var sortedDevices: [ConfiguredDevice] {
        roster.devices.sorted { lhs, rhs in
            let left = rank(lhs.lastStatus)
            let right = rank(rhs.lastStatus)
            if left != right { return left < right }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func rank(_ status: DeviceConfigStatus) -> Int {
        switch status {
        case .roleChangedNeedsReapply: return 0
        case .failed: return 1
        case .pending: return 2
        case .configured: return 3
        }
    }

    private func profileName(for id: UUID) -> String {
        library.profile(id: id)?.name ?? "Unknown profile"
    }

    private func appliedLine(_ device: ConfiguredDevice) -> String {
        guard let date = device.lastAppliedAt else { return "Not applied yet" }
        return "Last applied \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var removePresented: Binding<Bool> {
        Binding(
            get: { pendingRemove != nil },
            set: { if !$0 { pendingRemove = nil } }
        )
    }
}

struct DeviceDetailView: View {
    let deviceID: UUID
    @EnvironmentObject private var library: FleetLibrary
    @EnvironmentObject private var roster: DeviceRosterStore
    @EnvironmentObject private var navigation: AppNavigation
    @EnvironmentObject private var driver: ApplyDriver
    @State private var pendingProfileID: UUID?

    private var device: ConfiguredDevice? {
        roster.device(id: deviceID)
    }

    var body: some View {
        Group {
            if let device {
                Form {
                    Section {
                        LabeledContent("Radio", value: device.longName ?? device.displayName)
                        LabeledContent("Long name", value: device.longName ?? "Not applied yet")
                        LabeledContent("Short name", value: device.shortName ?? "Not applied yet")
                        Text("Long name is the callsign ATAK shows. Short name is the 4-character mesh badge. Change them by re-applying this radio.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        StatusBadge(status: device.lastStatus)
                        if let peripheralID = device.peripheralID {
                            LabeledContent("Bluetooth id") {
                                Text(peripheralID.uuidString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    Section("Function") {
                        Picker("Function", selection: functionBinding) {
                            ForEach(DeviceFunction.allCases, id: \.self) { item in
                                Text(item.displayName).tag(item)
                            }
                        }
                        .pickerStyle(.inline)
                        Text(device.function.shortHelp)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if device.function == .gateway, let profile = library.profile(id: device.profileID), profile.wifiNetworks.count > 1 {
                            Picker("Wi-Fi network", selection: wifiBinding) {
                                Text("Choose at apply").tag(Optional<UUID>.none)
                                ForEach(profile.wifiNetworks) { network in
                                    Text(network.ssid.isEmpty ? "Untitled network" : network.ssid).tag(Optional(network.id))
                                }
                            }
                        }
                    }
                    if device.function == .tracker {
                    Section("Role") {
                        Picker("Role", selection: roleBinding) {
                            Text(DeviceRole.takTracker.displayName).tag(DeviceRole.takTracker)
                            Text(DeviceRole.tak.displayName).tag(DeviceRole.tak)
                        }
                        .pickerStyle(.inline)
                        Text("Changing role here does not write the radio. Status becomes Needs re-apply until you run Apply.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    } else {
                        Section("Role") {
                            LabeledContent("Role", value: DeviceRole.client.chipTitle)
                            Text("A gateway is always CLIENT. Changing function does not write the radio until you run Apply.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section("Profile") {
                        Picker("Fleet profile", selection: profileSelection) {
                            ForEach(library.profiles) { profile in
                                Text(profile.name).tag(Optional(profile.id))
                            }
                        }
                        if library.profile(id: device.profileID) == nil {
                            Text("The saved profile for this radio is gone. Pick another, then re-apply.")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                    Section("Notes") {
                        TextField("Notes", text: notesBinding, axis: .vertical)
                            .lineLimit(2...5)
                    }
                    Section {
                        Button("Re-apply now") {
                            reapply(device)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(library.profile(id: device.profileID) == nil || !driver.isReadyForNextRadio)
                    } footer: {
                        Text(driver.isReadyForNextRadio
                             ? "Opens Apply with this profile, role, and names filled in. You still confirm before connect. Nothing is written until you pick the radio."
                             : "A radio is already connected. Cancel or finish that session before re-applying.")
                    }
                }
            } else {
                ContentUnavailableView("Radio missing", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle(device?.displayName ?? "Radio")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Switch fleet profile?",
            isPresented: profileSwitchPresented,
            titleVisibility: .visible
        ) {
            Button("Switch profile") {
                if let pendingProfileID {
                    roster.setProfile(pendingProfileID, for: deviceID)
                }
                pendingProfileID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingProfileID = nil
            }
        } message: {
            Text("This phone will remember the new profile. The radio keeps its current config until you re-apply.")
        }
    }

    private var functionBinding: Binding<DeviceFunction> {
        Binding(
            get: { device?.function ?? .tracker },
            set: { roster.setFunction($0, wifiNetworkID: device?.wifiNetworkID, for: deviceID) }
        )
    }

    private var wifiBinding: Binding<UUID?> {
        Binding(
            get: { device?.wifiNetworkID },
            set: { roster.setFunction(device?.function ?? .gateway, wifiNetworkID: $0, for: deviceID) }
        )
    }

    private var roleBinding: Binding<DeviceRole> {
        Binding(
            get: { device?.role ?? .takTracker },
            set: { roster.setRole($0, for: deviceID) }
        )
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { device?.notes ?? "" },
            set: { roster.setNotes($0, for: deviceID) }
        )
    }

    private var profileSelection: Binding<UUID?> {
        Binding(
            get: { device?.profileID },
            set: { newValue in
                guard let newValue, newValue != device?.profileID else { return }
                pendingProfileID = newValue
            }
        )
    }

    private var profileSwitchPresented: Binding<Bool> {
        Binding(
            get: { pendingProfileID != nil },
            set: { if !$0 { pendingProfileID = nil } }
        )
    }

    private func reapply(_ device: ConfiguredDevice) {
        navigation.applyPrefill = ApplyPrefill(
            profileID: device.profileID,
            role: device.role,
            function: device.function,
            wifiNetworkID: device.wifiNetworkID,
            longName: device.longName,
            shortName: device.shortName,
            peripheralID: device.peripheralID,
            rosterDeviceID: device.id,
            token: UUID()
        )
        navigation.tab = .apply
    }
}
