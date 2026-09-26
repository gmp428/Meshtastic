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
    @State private var role: DeviceRole?
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
                if !roster.devices.isEmpty {
                    Section("Pick from roster") {
                        ForEach(roster.devices) { device in
                            Button {
                                selectedProfileID = device.profileID
                                role = device.role
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
                    Text("Walks connect, apply, reboot, and verify without hardware. Rows are labeled DEBUG. This is not a real radio and it does not prove a protobuf write.")
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
                    Text("Mesh Config connects to one radio, applies the profile, verifies the read-back, then disconnects. The next radio is never opened automatically.")
                }
            }
            .navigationTitle("Apply")
            .navigationDestination(for: ApplyRoute.self) { route in
                switch route {
                case .scan:
                    ScanView(
                        preferredPeripheralID: preferredPeripheralID,
                        onPick: { radio in
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
                role = prefill.role
                preferredPeripheralID = prefill.peripheralID
                rosterDeviceID = prefill.rosterDeviceID
                path = NavigationPath()
                didPushResult = false
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
        guard driver.isReadyForNextRadio, let profile = selectedProfile, role != nil else { return false }
        return !profile.channel.isDisallowedPrimaryName
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { setupError != nil },
            set: { if !$0 { setupError = nil } }
        )
    }

    private func startScan() async {
        guard let profile = selectedProfile, let role else { return }
        do {
            try await driver.beginScan(profile: profile, role: role, rosterDeviceID: rosterDeviceID)
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

struct ApplyProgressView: View {
    @ObservedObject var session: ApplySession
    var onCancel: () -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.profile.name)
                        .font(.headline)
                    RoleChip(role: session.role)
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
        ApplyStepRow.rows(for: session)
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

enum ApplyStepStatus {
    case waiting, current, done, failed
}

struct ApplyStepRow: Identifiable {
    var id: String
    var title: String
    var status: ApplyStepStatus
    var detail: String?

    static func rows(for session: ApplySession) -> [ApplyStepRow] {
        let sections = session.orderedSections
        var titles = ["Connected & handshake", "Fleet PSK ready"]
        titles.append(contentsOf: sections.map(\.progressTitle))
        titles.append("Verify")
        var ids = ["handshake", "psk"]
        ids.append(contentsOf: sections.map(\.rawValue))
        ids.append("verify")

        let failedIndex = failedStepIndex(session)
        let currentIndex = failedIndex ?? activeStepIndex(session.state, sections: sections)

        return titles.indices.map { index in
            let status: ApplyStepStatus
            if let failedIndex {
                if index < failedIndex {
                    status = .done
                } else if index == failedIndex {
                    status = .failed
                } else {
                    status = .waiting
                }
            } else if session.state == .succeeded {
                status = .done
            } else if index < currentIndex {
                status = .done
            } else if index == currentIndex {
                status = .current
            } else {
                status = .waiting
            }
            let detail = index == currentIndex ? detailText(session.state) : nil
            return ApplyStepRow(id: ids[index], title: titles[index], status: status, detail: detail)
        }
    }

    private static func failedStepIndex(_ session: ApplySession) -> Int? {
        guard case .failed(let failure) = session.state else { return nil }
        return activeStepIndex(failure.stage, sections: session.orderedSections)
    }

    private static func activeStepIndex(_ state: ApplySessionState, sections: [ApplySection]) -> Int {
        switch state {
        case .idle, .scanning, .connecting, .handshaking:
            return 0
        case .ensuringPSK:
            return 1
        case .applying(let section), .waitingReboot(let section), .reconnecting(after: let section):
            return 2 + (sections.firstIndex(of: section) ?? 0)
        case .verifying, .succeeded, .disconnecting, .disconnected:
            return 2 + sections.count
        case .failed:
            return 0
        }
    }

    private static func detailText(_ state: ApplySessionState) -> String? {
        switch state {
        case .connecting:
            return "Connecting"
        case .handshaking:
            return "PhoneAPI handshake"
        case .ensuringPSK:
            return "Checking the Keychain"
        case .applying(.channel):
            return "Replacing the default primary and sending the channel"
        case .applying:
            return "Writing"
        case .waitingReboot:
            return "Waiting for the radio to reboot"
        case .reconnecting:
            return "Reconnecting"
        case .verifying:
            return "Reading back"
        case .failed(let failure):
            return failure.message
        default:
            return nil
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
                    LabeledContent("Profile", value: outcome.profileName)
                    LabeledContent("Role") {
                        RoleChip(role: outcome.role)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

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
            ForEach(Array(outcome.checklist.enumerated()), id: \.offset) { pair in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: pair.element.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(pair.element.ok ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pair.element.label)
                            .font(.subheadline)
                        Text(pair.element.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
