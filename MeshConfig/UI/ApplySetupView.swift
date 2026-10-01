import SwiftUI
import UIKit

enum ApplyRoute: Hashable {
    case scan
    case progress
    case result
}

struct ApplySetupView: View {
    @EnvironmentObject private var library: FleetLibrary
    @EnvironmentObject private var roster: DeviceRosterStore
    @EnvironmentObject private var driver: ApplyDriver
    @EnvironmentObject private var navigation: AppNavigation

    @State private var selectedProfileID: UUID?
    @State private var function: DeviceFunction = .tracker
    @State private var wifiNetworkID: UUID?
    @State private var role: DeviceRole?
    @State private var longNameText = ""
    @State private var shortNameText = ""
    @State private var longEdited = false
    @State private var shortEdited = false
    @State private var programmaticNames = RadioNames(longName: nil, shortName: nil)
    @State private var preferredPeripheralID: UUID?
    @State private var rosterDeviceID: UUID?
    @State private var path = NavigationPath()
    @State private var setupError: String?
    @State private var didPushResult = false

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                if !driver.isReadyForNextRadio {
                    Section {
                        Text("One radio at a time. Finish or cancel the current Bluetooth session before starting another.")
                            .font(.subheadline)
                    }
                }
                Section("Profile") {
                    Picker("Fleet profile", selection: $selectedProfileID) {
                        Text("Select…").tag(Optional<UUID>.none)
                        ForEach(library.profiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    if let profile = selectedProfile {
                        Text("\(profile.lora.modemPreset.displayName) · slot \(profile.lora.frequencySlot) · \(profile.channel.name)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if profile.channel.isDisallowedPrimaryName {
                            Text("Pick a private channel name in Profiles before scanning. LongFast and ShortFast are not allowed.")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }
                Section("Function for this device") {
                    Picker("Function", selection: $function) {
                        ForEach(DeviceFunction.allCases, id: \.self) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .pickerStyle(.inline)
                    Text(function.shortHelp)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if function == .gateway {
                        if let profile = selectedProfile, profile.wifiNetworks.count > 1 {
                            Picker("Wi-Fi network", selection: $wifiNetworkID) {
                                Text("Choose…").tag(Optional<UUID>.none)
                                ForEach(profile.wifiNetworks) { network in
                                    Text(network.ssid.isEmpty ? "Untitled network" : network.ssid).tag(Optional(network.id))
                                }
                            }
                        } else if let network = selectedProfile?.wifiNetworks.first {
                            LabeledContent("Wi-Fi", value: network.ssid.isEmpty ? "Add an SSID on the profile" : network.ssid)
                        } else {
                            Text("Add a Wi-Fi network in the profile before scanning a gateway.")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        Text("Gateway uses device role CLIENT. Wi-Fi is turned on, which disables Bluetooth after the radio reboots.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if function == .tracker {
                Section("Role for this device") {
                    Picker("Role", selection: $role) {
                        Text("Choose…").tag(Optional<DeviceRole>.none)
                        Text(DeviceRole.takTracker.displayName).tag(Optional(DeviceRole.takTracker))
                        Text(DeviceRole.tak.displayName).tag(Optional(DeviceRole.tak))
                    }
                    .pickerStyle(.inline)
                    if let role {
                        Text(role.shortHelp)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Ask this for every radio. TAK Tracker is a standalone. TAK is for a phone running ATAK/iTAK on the same link.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                }
                Section {
                    TextField("Long name", text: $longNameText)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    TextField("Short name", text: $shortNameText, prompt: Text("Leave blank to keep"))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    if let nameProblem {
                        Text(nameProblem)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else if let names = resolvedNames {
                        Text(namePreview(names))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Name on TAK")
                } footer: {
                    Text("The long name is the Meshtastic name ATAK shows as this radio’s callsign. The short name is the 4-byte badge on the mesh screen. Leave a field blank to keep the radio’s current value. Leave both blank to skip the name. A known radio fills these from the last sync, and a connected radio’s own names win unless you edit the fields.")
                }
                if !roster.devices.isEmpty {
                    Section("Pick from roster") {
                        ForEach(roster.devices) { device in
                            Button {
                                selectedProfileID = device.profileID
                                function = device.function
                                wifiNetworkID = device.wifiNetworkID
                                role = device.function == .gateway ? .client : device.role
                                fillNames(long: device.longName ?? "", short: device.shortName ?? "")
                                preferredPeripheralID = device.peripheralID
                                rosterDeviceID = device.id
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(device.displayName)
                                        .font(.body)
                                    HStack {
                                        RoleChip(role: device.role)
                                        StatusBadge(status: device.lastStatus)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .disabled(!driver.isReadyForNextRadio)
                        }
                    }
                }
                #if DEBUG
                Section("Debug") {
                    Toggle("Simulated radios (DEBUG)", isOn: Binding(
                        get: { driver.useSimulation },
                        set: { driver.useSimulation = $0 }
                    ))
                    Text("Walks connect, diff, one reboot when settings differ, and verify without hardware. Rows are labeled DEBUG. This is not a real radio and it does not prove a protobuf write.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                #endif
                Section {
                    Button("Scan for radios") {
                        Task { await startScan() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(!canScan)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mesh Config connects to one radio, applies the profile, verifies the read-back, then disconnects. The next radio is never opened automatically.")
                        Text(AppVersion.display)
                    }
                }
            }
            .navigationTitle("Apply")
            .navigationDestination(for: ApplyRoute.self) { route in
                switch route {
                case .scan:
                    ScanView(
                        preferredPeripheralID: preferredPeripheralID,
                        onPick: { radio in
                            if let known = roster.device(peripheralID: radio.peripheralID) {
                                driver.noteRosterMatch(known.id)
                                rosterDeviceID = known.id
                                if !longEdited && !shortEdited {
                                    fillNames(long: known.longName ?? "", short: known.shortName ?? "")
                                }
                            }
                            preferredPeripheralID = radio.peripheralID
                            driver.select(radio)
                            path.append(ApplyRoute.progress)
                        },
                        onStop: {
                            driver.abortScan()
                            if !path.isEmpty {
                                path.removeLast()
                            }
                        }
                    )
                case .progress:
                    if let session = driver.session {
                        ApplyProgressView(session: session) {
                            Task {
                                await driver.cancel()
                                didPushResult = false
                                path = NavigationPath()
                            }
                        }
                    } else {
                        ContentUnavailableView("No active radio", systemImage: "antenna.radiowaves.left.and.right")
                    }
                case .result:
                    if let outcome = driver.outcome {
                        ApplyResultView(
                            outcome: outcome,
                            nextDevice: { clearRoleAndReturn() },
                            retry: { Task { await retry() } },
                            done: { clearRoleAndReturn() }
                        )
                    } else {
                        ContentUnavailableView("No result", systemImage: "questionmark.circle")
                    }
                }
            }
            .onAppear {
                driver.bind(library: library, roster: roster)
                if selectedProfileID == nil {
                    selectedProfileID = library.lastUsedProfileID ?? library.profiles.first?.id
                }
            }
            .onChange(of: navigation.applyPrefill) { _, prefill in
                guard let prefill, driver.isReadyForNextRadio else { return }
                selectedProfileID = prefill.profileID
                function = prefill.function
                wifiNetworkID = prefill.wifiNetworkID
                role = prefill.function == .gateway ? .client : prefill.role
                fillNames(long: prefill.longName ?? "", short: prefill.shortName ?? "")
                preferredPeripheralID = prefill.peripheralID
                rosterDeviceID = prefill.rosterDeviceID
                path = NavigationPath()
                didPushResult = false
            }
            .onChange(of: longNameText) { _, _ in
                markNameEdit()
            }
            .onChange(of: shortNameText) { _, _ in
                markNameEdit()
            }
            .onChange(of: driver.outcome?.passed) { _, passed in
                guard passed != nil, !didPushResult else { return }
                didPushResult = true
                path.append(ApplyRoute.result)
            }
            .alert("Cannot scan", isPresented: errorPresented) {
                Button("OK", role: .cancel) { setupError = nil }
            } message: {
                Text(setupError ?? "")
            }
        }
    }

    private var selectedProfile: FleetProfile? {
        selectedProfileID.flatMap { library.profile(id: $0) }
    }

    private var canScan: Bool {
        // `generation` publishes session transitions so this gate refreshes.
        _ = driver.generation
        guard driver.isReadyForNextRadio, let profile = selectedProfile, resolvedNames != nil else {
            return false
        }
        if profile.channel.isDisallowedPrimaryName { return false }
        if function == .tracker { return role != nil }
        let network = profile.wifiNetworks.first { $0.id == wifiNetworkID } ?? (profile.wifiNetworks.count == 1 ? profile.wifiNetworks.first : nil)
        return network?.ssid.isEmpty == false && network?.pskRef.isConfigured == true && profile.mqtt.passwordRef.isConfigured
    }

    private func namePreview(_ names: RadioNames) -> String {
        if names.longName == nil && names.shortName == nil {
            return "Both blank: this sync will not change the radio’s names."
        }
        var parts: [String] = []
        if let longName = names.longName {
            parts.append("Long name \(longName)")
        }
        if let shortName = names.shortName {
            parts.append("badge \(shortName)")
        }
        return parts.joined(separator: ". ") + ". A blank field stays as it is on the radio."
    }

    private func fillNames(long: String, short: String) {
        let resolved = (try? RadioNames.resolve(longName: long, shortName: short))
            ?? RadioNames(longName: nil, shortName: nil)
        programmaticNames = resolved
        longEdited = false
        shortEdited = false
        longNameText = long
        shortNameText = short
    }

    private func markNameEdit() {
        guard let resolved = try? RadioNames.resolve(longName: longNameText, shortName: shortNameText) else {
            longEdited = true
            shortEdited = true
            return
        }
        longEdited = resolved.longName != programmaticNames.longName
        shortEdited = resolved.shortName != programmaticNames.shortName
    }

    private var resolvedNames: RadioNames? {
        try? RadioNames.resolve(longName: longNameText, shortName: shortNameText)
    }

    private var nameProblem: String? {
        do {
            _ = try RadioNames.resolve(longName: longNameText, shortName: shortNameText)
            return nil
        } catch let problem as RadioNames.Problem {
            return problem.errorDescription
        } catch {
            return "Enter the long name for this radio."
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { setupError != nil },
            set: { if !$0 { setupError = nil } }
        )
    }

    private func startScan() async {
        guard let profile = selectedProfile else { return }
        let appliedRole: DeviceRole
        if function == .gateway {
            appliedRole = .client
        } else if let role {
            appliedRole = role
        } else {
            return
        }
        do {
            let names = try RadioNames.resolve(longName: longNameText, shortName: shortNameText)
            try await driver.beginScan(
                profile: profile,
                role: appliedRole,
                function: function,
                wifiNetworkID: wifiNetworkID,
                names: names,
                longEdited: longEdited,
                shortEdited: shortEdited,
                rosterDeviceID: rosterDeviceID
            )
            library.rememberLastUsed(profile.id)
            didPushResult = false
            path.append(ApplyRoute.scan)
        } catch {
            setupError = (error as? LocalizedError)?.errorDescription ?? "Could not start the scan."
        }
    }

    private func retry() async {
        path = NavigationPath()
        didPushResult = false
        await startScan()
    }

    private func clearRoleAndReturn() {
        role = nil
        function = .tracker
        wifiNetworkID = nil
        fillNames(long: "", short: "")
        preferredPeripheralID = nil
        rosterDeviceID = nil
        didPushResult = false
        path = NavigationPath()
    }
}

struct ScanView: View {
    @EnvironmentObject private var driver: ApplyDriver
    @Environment(\.openURL) private var openURL
    var preferredPeripheralID: UUID?
    var onPick: (DiscoveredRadio) -> Void
    var onStop: () -> Void

    var body: some View {
        List {
            #if DEBUG
            if driver.useSimulation {
                Section {
                    Text("DEBUG simulation. These rows are not radios. Bluetooth is not used.")
                        .font(.subheadline)
                }
            }
            #endif
            if let message = driver.bluetoothMessage {
                Section {
                    Text(message)
                        .font(.subheadline)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                }
            }
            Section {
                if radios.isEmpty && driver.bluetoothMessage == nil {
                    ContentUnavailableView(
                        "No radios yet",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("Power the radio and hold it near the phone.")
                    )
                }
                ForEach(radios) { radio in
                    Button {
                        onPick(radio)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.title2)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(radio.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                HStack {
                                    Text("RSSI \(radio.rssi)")
                                    if radio.peripheralID == preferredPeripheralID {
                                        Text("Last radio")
                                    }
                                    if radio.isSimulated {
                                        Text("DEBUG")
                                    }
                                }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Scan")
        .refreshable {
            await driver.refreshScan()
        }
        .toolbar {
            Button("Stop", action: onStop)
        }
        .onDisappear {
            if driver.session?.state == .scanning {
                driver.abortScan()
            }
        }
    }

    private var radios: [DiscoveredRadio] {
        driver.discovered.sorted { lhs, rhs in
            let leftPreferred = lhs.peripheralID == preferredPeripheralID
            let rightPreferred = rhs.peripheralID == preferredPeripheralID
            if leftPreferred != rightPreferred { return leftPreferred }
            return lhs.rssi > rhs.rssi
        }
    }
}

@MainActor
struct ApplyProgressView: View {
    @ObservedObject var session: ApplySession
    var onCancel: @MainActor () -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.profile.name)
                        .font(.headline)
                    Text(session.shownLongName.isEmpty ? "Long name unchanged" : session.shownLongName)
                        .font(.body)
                    Text(session.shownShortName.isEmpty ? "Short name unchanged" : "Mesh badge \(session.shownShortName)")
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                    RoleChip(role: session.role)
                    if let progress = session.syncProgress {
                        Text(progress.summary)
                            .font(.subheadline.weight(.semibold))
                    }
                    ProgressView(value: Double(doneCount), total: Double(steps.count))
                        .padding(.top, 4)
                }
                .padding(.vertical, 6)
            }
            Section {
                ForEach(steps) { step in
                    HStack(alignment: .center, spacing: 12) {
                        stepIcon(step.status)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                                .font(.body)
                            if let detail = step.detail {
                                Text(detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            if let progress = session.syncProgress {
                Section("Fields that differed") {
                    ForEach(progress.debugLines, id: \.self) { line in
                        Text(line)
                            .font(.footnote.monospaced())
                    }
                }
            }
        }
        .navigationTitle("Applying")
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .bottom) {
            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding()
        }
    }

    private var steps: [ApplyStepRow] {
        // Read actor-isolated fields on the main actor, then build rows from copies.
        ApplyStepRow.rows(state: session.state, progress: session.syncProgress)
    }

    private var doneCount: Int {
        steps.filter { $0.status == .done }.count
    }

    @ViewBuilder
    private func stepIcon(_ status: ApplyStepStatus) -> some View {
        switch status {
        case .waiting:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .current:
            ProgressView()
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

struct ApplyResultView: View {
    var outcome: ApplyOutcome
    var nextDevice: () -> Void
    var retry: () -> Void
    var done: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: outcome.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(outcome.passed ? .green : .red)
                    .padding(.top, 12)
                Text(outcome.passed ? "Configured" : "Failed")
                    .font(.title2.bold())
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Radio", value: outcome.deviceName)
                    LabeledContent("Long name", value: outcome.longName.isEmpty ? "Unchanged" : outcome.longName)
                    LabeledContent("Short name", value: outcome.shortName.isEmpty ? "Unchanged" : outcome.shortName)
                    LabeledContent("Profile", value: outcome.profileName)
                    LabeledContent("Role") {
                        RoleChip(role: outcome.role)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

                DisclosureGroup("Fields that differed") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(outcome.fieldDiffs, id: \.self) { line in
                            Text(line)
                                .font(.footnote.monospaced())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if outcome.passed {
                    DisclosureGroup("Checklist") {
                        checklist
                    }
                    Button("Next device", action: nextDevice)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button("Done", action: done)
                        .controlSize(.large)
                } else {
                    Text(outcome.message)
                        .font(.body)
                        .multilineTextAlignment(.center)
                    if !outcome.failedChecks.isEmpty {
                        Text(outcome.failedChecks.joined(separator: ", "))
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    checklist
                    Button("Retry this radio", action: retry)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button("Skip / Next device", action: nextDevice)
                        .controlSize(.large)
                    Button("Done", action: done)
                        .controlSize(.large)
                }
            }
            .padding(20)
        }
        .navigationTitle("Result")
        .navigationBarBackButtonHidden(true)
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(outcome.checklist) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: item.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(item.ok ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label)
                            .font(.subheadline)
                        Text(item.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
