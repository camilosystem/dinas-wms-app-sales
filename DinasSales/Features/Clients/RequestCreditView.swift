import SwiftUI
#if os(iOS)
import PhotosUI
import UIKit
#endif

/// Solicitar un crédito/ajuste de cartera del cliente (★ v0.17.0). Entra desde la sección Cartera
/// del detalle del cliente. Dos modalidades:
/// - CON_ITEMS: selector de ítems + cantidad. NO se muestra un precio "final": el crédito lo valora
///   el middleware al aprobar (último precio facturado). Si algún día mostramos un estimado, va
///   marcado claramente como estimado.
/// - SIN_ITEMS: monto manual.
///
/// `reason` (motivo) es OBLIGATORIO en ambas modalidades; `invoice_doc_num` es opcional en ambas.
/// La foto sigue la misma regla offline que Reportar Pago (reutiliza `CarteraSubmitService`):
/// sin foto va a la cola; con foto requiere conexión y, sin señal, se BLOQUEA.
struct RequestCreditView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let client: Client
    /// Se llama al terminar con éxito, con el mensaje para el padre (toast/estado).
    let onFinished: (String) -> Void

    @State private var mode: CreditRequestMode = .conItems
    @State private var reason: CreditRequestReason = .damaged
    @State private var invoiceDocNum = ""
    @State private var manualAmount: Double = 0
    @State private var lines: [CreditLineDraft] = []
    @State private var comments = ""
    @State private var photoBase64: String?
    @State private var showItemPicker = false
    @State private var submitting = false
    @State private var errorMessage: String?
    #if os(iOS)
    @State private var photoItem: PhotosPickerItem?
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section("Modalidad") {
                    Picker("Modalidad", selection: $mode) {
                        Text("Por ítems").tag(CreditRequestMode.conItems)
                        Text("Monto manual").tag(CreditRequestMode.sinItems)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Motivo") {
                    Picker("Motivo", selection: $reason) {
                        ForEach(CreditRequestReason.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }

                if mode == .conItems {
                    itemsSection
                } else {
                    Section {
                        amountRow
                    } header: {
                        Text("Monto")
                    } footer: {
                        Text("Monto solicitado. El aprobador lo confirma o ajusta.")
                    }
                }

                Section {
                    TextField("Número de factura (opcional)", text: $invoiceDocNum)
                        #if os(iOS)
                        .autocapitalization(.allCharacters)
                        #endif
                } footer: {
                    Text("Si la dejas vacía, la solicitud queda como crédito general (sin factura específica).")
                }

                Section("Comentarios") {
                    TextField("Comentarios (opcional)", text: $comments, axis: .vertical)
                }

                Section {
                    photoControl
                } header: {
                    Text("Evidencia (opcional)")
                } footer: {
                    Text("Adjuntar foto requiere conexión. Sin foto, la solicitud se guarda y se envía al sincronizar.")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Solicitar crédito")
            .navigationBarTitleDisplayModeInlineCompat()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Solicitar") { Task { await submit() } }
                        .disabled(!canSubmit || submitting)
                }
            }
            .sheet(isPresented: $showItemPicker) {
                CreditItemPickerView(database: environment.database) { item in
                    addItem(item)
                }
            }
        }
    }

    // MARK: - Sección de ítems (CON_ITEMS)

    private var itemsSection: some View {
        Section {
            ForEach($lines) { $line in
                VStack(alignment: .leading, spacing: 4) {
                    Text(line.item.name).font(.body.weight(.medium))
                    HStack {
                        Text(line.item.itemCode).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Stepper(value: $line.quantity, in: 1...9999, step: 1) {
                            Text("Cant. \(quantityLabel(line.quantity))")
                        }
                        .fixedSize()
                    }
                }
            }
            .onDelete { lines.remove(atOffsets: $0) }

            Button {
                showItemPicker = true
            } label: {
                Label("Agregar ítem", systemImage: "plus.circle")
            }
        } header: {
            Text("Ítems")
        } footer: {
            Text("Indica los ítems y la cantidad a acreditar. No se muestra un precio: el crédito lo valora el middleware al aprobar (último precio facturado).")
        }
    }

    private var amountRow: some View {
        HStack {
            Text("Monto solicitado")
            Spacer()
            TextField("0", value: $manualAmount, format: .number)
                .multilineTextAlignment(.trailing).frame(width: 120)
                .textFieldStyle(.roundedBorder)
            #if os(iOS)
                .keyboardType(.decimalPad)
            #endif
        }
    }

    @ViewBuilder private var photoControl: some View {
        #if os(iOS)
        PhotosPicker(selection: $photoItem, matching: .images) {
            Label(photoBase64 == nil ? "Adjuntar foto" : "Foto adjunta",
                  systemImage: photoBase64 == nil ? "camera" : "checkmark.circle.fill")
        }
        .onChange(of: photoItem) { newItem in Task { await loadPhoto(newItem) } }
        if photoBase64 != nil {
            Button("Quitar foto", role: .destructive) { photoBase64 = nil; photoItem = nil }
        }
        #else
        Text("Adjuntar foto no disponible en este dispositivo.").foregroundStyle(.secondary)
        #endif
    }

    // MARK: - Lógica

    /// CON_ITEMS necesita al menos una línea; SIN_ITEMS necesita un monto > 0. `reason` siempre
    /// tiene valor (obligatorio en ambas), así que no bloquea.
    private var canSubmit: Bool {
        switch mode {
        case .conItems: return !lines.isEmpty
        case .sinItems: return manualAmount > 0
        }
    }

    private func addItem(_ item: Item) {
        // Si ya está, súbele la cantidad en vez de duplicar la línea.
        if let idx = lines.firstIndex(where: { $0.item.itemCode == item.itemCode }) {
            lines[idx].quantity += 1
        } else {
            lines.append(CreditLineDraft(item: item, quantity: 1))
        }
    }

    private func quantityLabel(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private func submit() async {
        submitting = true; errorMessage = nil
        defer { submitting = false }

        let trimmedInvoice = invoiceDocNum.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedComments = comments.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cada línea hereda el motivo del encabezado (el contrato exige reason por línea).
        let lineInputs = lines.map {
            CreditRequestLineInput(itemCode: $0.item.itemCode, quantity: $0.quantity, reason: reason)
        }
        let draft = CreditRequestDraft(
            clientCode: client.clientCode, mode: mode, reason: reason,
            manualAmount: mode == .sinItems ? manualAmount : nil,
            invoiceDocNum: trimmedInvoice.isEmpty ? nil : trimmedInvoice,
            comments: trimmedComments.isEmpty ? nil : trimmedComments,
            lines: mode == .conItems ? lineInputs : [])
        let service = CarteraSubmitService(
            repo: CarteraRepository(database: environment.database), api: environment.api)

        do {
            let outcome = try await service.submitCreditRequest(
                draft, imageBase64: photoBase64, isOnline: environment.network.isOnline)
            switch outcome {
            case .blockedNeedsConnection:
                errorMessage = "Necesitas conexión para adjuntar una foto. Puedes solicitar sin foto, o intentarlo más tarde con señal."
            case .queued:
                finish("Solicitud guardada. Se enviará al sincronizar.")
            case .sent:
                finish("Solicitud de crédito enviada.")
            case .pendingUpload:
                finish("Foto subida. La solicitud se enviará al reconectar.")
            case .failed(let reason):
                finish("El servidor rechazó la solicitud: \(reason) Míralo en Ajustes → Problemas de sincronización.")
            }
        } catch {
            errorMessage = "No se pudo enviar la solicitud: \(error.localizedDescription)"
        }
    }

    private func finish(_ message: String) {
        onFinished(message)
        dismiss()
    }

    #if os(iOS)
    /// Carga la foto elegida, la reduce (~1024px, JPEG ~70%) y la deja en base64 para subir.
    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item,
              let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        photoBase64 = image.evidenceBase64()
    }
    #endif
}

/// Línea en construcción dentro de la UI (antes de encolar). Guarda el `Item` completo para
/// mostrar nombre/código; al enviar se reduce a `CreditRequestLineInput`.
private struct CreditLineDraft: Identifiable, Equatable {
    let item: Item
    var quantity: Double
    var id: String { item.itemCode }
}

/// Selector de un ítem del catálogo local (offline) para las líneas CON_ITEMS. Reutiliza la
/// misma búsqueda del catálogo (código/nombre/categoría/código de barras).
private struct CreditItemPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let database: AppDatabase
    let onPick: (Item) -> Void

    @State private var query = ""
    @State private var results: [Item] = []

    var body: some View {
        NavigationStack {
            List(results) { item in
                Button {
                    onPick(item)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.body)
                        Text(item.itemCode).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $query, prompt: "Buscar por código o nombre")
            .onChange(of: query) { _ in reload() }
            .navigationTitle("Agregar ítem")
            .navigationBarTitleDisplayModeInlineCompat()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
            }
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        results = (try? CatalogRepository(database: database).items(matching: query)) ?? []
    }
}
