import SwiftUI
import UniformTypeIdentifiers

/// Ajustes: datos del usuario logueado (solo informativo) + backup/restauración del HISTORIAL
/// de órdenes (lo único no re-sincronizable del servidor). El catálogo y los clientes no se
/// respaldan: se bajan de nuevo al sincronizar.
struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var auth: AuthSession

    @State private var shareItem: ShareItem?
    @State private var showImporter = false
    @State private var resultMessage: String?
    @State private var showResult = false
    @State private var problemCount = 0

    private var service: BackupService { BackupService(database: environment.database) }

    var body: some View {
        List {
            Section("Cuenta") {
                row("Nombre", auth.displayName ?? auth.username ?? "—")
                row("Código de vendedor", auth.salespersonCode ?? "—")
                row("Rol", auth.role ?? "—")
            }

            Section("Sincronización") {
                NavigationLink {
                    SyncProblemsView()
                } label: {
                    HStack {
                        Label("Problemas de sincronización", systemImage: "exclamationmark.triangle")
                        Spacer()
                        if problemCount > 0 {
                            Text("\(problemCount)")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.red, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }
            }

            Section {
                Button {
                    doBackup()
                } label: {
                    Label("Hacer Backup", systemImage: "square.and.arrow.up")
                }
                Button {
                    showImporter = true
                } label: {
                    Label("Restaurar Backup", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Historial de órdenes")
            } footer: {
                Text("El backup respalda tus órdenes tomadas y sincronizadas. El catálogo y los clientes no hace falta respaldarlos: se bajan de nuevo al sincronizar.")
            }
        }
        .navigationTitle("Ajustes")
        .navigationBarTitleDisplayModeInlineCompat()
        .task { problemCount = SyncProblemsView.count(database: environment.database) }
        .sheet(item: $shareItem) { item in
            #if os(iOS)
            ShareSheet(items: [item.url])
            #else
            Text(item.url.lastPathComponent)
            #endif
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .alert("Backup", isPresented: $showResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Backup

    /// Genera el JSON del historial y lo entrega al share sheet nativo (Archivos, iCloud, AirDrop…).
    private func doBackup() {
        do {
            let data = try service.exportData(username: auth.username, now: Date())
            let filename = "dinas-ventas-backup-\(safe(auth.username))-\(Self.dateStamp()).json"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            shareItem = ShareItem(url: url)
        } catch {
            resultMessage = "No se pudo generar el backup: \(error.localizedDescription)"
            showResult = true
        }
    }

    /// Parsea el archivo elegido y restaura. Maneja con gracia un archivo inválido/corrupto.
    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let data = try Data(contentsOf: url)
            let backup = try service.decode(data)
            let summary = try service.restore(backup)
            resultMessage = "Restauradas \(summary.restored) orden(es)."
                + (summary.skipped > 0 ? " \(summary.skipped) ya existían y se omitieron." : "")
            showResult = true
        } catch {
            resultMessage = (error as? BackupError)?.errorDescription
                ?? "No se pudo restaurar el archivo: \(error.localizedDescription)"
            showResult = true
        }
    }

    private func safe(_ username: String?) -> String {
        (username ?? "vendedor").replacingOccurrences(of: "/", with: "-")
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

/// URL a compartir, envuelta como Identifiable para `.sheet(item:)`.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

#if os(iOS)
import UIKit

/// Share sheet nativo (UIActivityViewController) para entregar el archivo de backup.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
