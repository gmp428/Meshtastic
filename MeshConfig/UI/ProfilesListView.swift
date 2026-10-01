import SwiftUI

struct ProfilesListView: View {
    @EnvironmentObject private var library: FleetLibrary
    @EnvironmentObject private var roster: DeviceRosterStore
    @State private var pendingDelete: FleetProfile?

    var body: some View {
        NavigationStack {
            List {
                ForEach(library.profiles) { profile in
                    NavigationLink(value: profile.id) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name)
                                .font(.headline)
                            Text("\(profile.lora.modemPreset.displayName) · slot \(profile.lora.frequencySlot) · \(profile.defaultRole.chipTitle)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) {
                            pendingDelete = profile
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Duplicate") {
                            library.duplicate(profile)
                        }
                        .tint(.indigo)
                    }
                }
            }
            .navigationTitle("Profiles")
            .navigationDestination(for: UUID.self) { id in
                if let binding = binding(for: id) {
                    ProfileEditorView(profile: binding)
                } else {
                    ContentUnavailableView("Profile missing", systemImage: "questionmark.circle")
                }
            }
            .toolbar {
                Button {
                    _ = library.createTAKProfile()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New TAK Tracker profile")
            }
            .overlay {
                if library.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("No profiles", systemImage: "antenna.radiowaves.left.and.right")
                    } description: {
                        Text("Create a TAK Tracker profile to configure your fleet.")
                    } actions: {
                        Button("Create TAK Tracker profile") {
                            _ = library.createTAKProfile()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
            }
            .confirmationDialog(
                "Delete this profile?",
                isPresented: deletePresented,
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { profile in
                Button("Delete profile and Keychain PSK", role: .destructive) {
                    library.delete(profile)
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDelete = nil
                }
            } message: { _ in
                Text("This removes the saved profile and its Keychain key on this phone. Radios are not reset. The key is not shown.")
            }
        }
    }

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private func binding(for id: UUID) -> Binding<FleetProfile>? {
        guard library.profile(id: id) != nil else { return nil }
        return Binding(
            get: { library.profile(id: id) ?? BuiltInProfiles.takTracker() },
            set: { library.replace($0) }
        )
    }
}
