import SwiftUI
#if os(iOS)
import PhotosUI
import UIKit
#endif

/// Reportar un pago de cartera del cliente (★ v0.17.0). Entra desde la sección Cartera del
/// detalle del cliente. Propone la imputación sobre las facturas abiertas (editable, no tiene
/// que cuadrar exacto), método de pago, monto, fecha, comentarios y foto OPCIONAL.
///
/// Regla offline: sin foto va a la cola (lo sube el SyncEngine). Con foto requiere conexión; si
/// el vendedor la adjunta sin señal, se BLOQUEA con un mensaje claro (no queda a medias).
struct ReportPaymentView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let client: Client
    /// Se llama al terminar con éxito, con el mensaje para el padre (toast/estado).
    let onFinished: (String) -> Void

    @State private var selected: Set<String> = []            // invoice_doc_num marcados
    @State private var appliedAmount: [String: Double] = [:]  // monto propuesto por factura
    @State private var blockedInvoices: Set<String> = []      // facturas en un pago activo (no seleccionables)
    @State private var amountField = PaymentAmountField()     // monto + auto-relleno desde facturas
    @State private var method: AccountPaymentMethod = .efectivo
    @State private var bank: TransferBankAccount?      // solo TRANSFERENCIA
    @State private var checkNumber = ""                 // solo CHEQUE
    @State private var bankCode = ""                    // solo CHEQUE
    @State private var paymentDate = Date()
    @State private var comments = ""
    @State private var photoBase64: String?
    @State private var submitting = false
    @State private var errorMessage: String?
    #if os(iOS)
    @State private var photoItem: PhotosPickerItem?
    #endif

    var body: some View {
        NavigationStack {
            Form {
                if !client.openInvoices.isEmpty {
                    Section {
                        ForEach(client.openInvoices, id: \.invoiceDocNum) { invoiceRow($0) }
                    } header: {
                        Text("Facturas abiertas")
                    } footer: {
                        Text("Marca a cuáles aplicar el pago y ajusta el monto. Es una PROPUESTA: el aprobador la confirma o la cambia; no tiene que cuadrar exacto.")
                    }
                }

                Section("Pago") {
                    amountRow
                    Picker("Método", selection: $method) {
                        ForEach(AccountPaymentMethod.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    // ★ v0.19.1 — datos condicionados por método.
                    if method == .transferencia {
                        Picker("Banco (destino)", selection: $bank) {
                            Text("Selecciona…").tag(TransferBankAccount?.none)
                            ForEach(TransferBankAccount.allCases, id: \.self) {
                                Text($0.label).tag(TransferBankAccount?.some($0))
                            }
                        }
                    } else if method == .cheque {
                        TextField("Número de cheque", text: $checkNumber)
                        TextField("Código de banco", text: $bankCode)
                            #if os(iOS)
                            .autocapitalization(.allCharacters)
                            #endif
                    }
                    DatePicker("Fecha", selection: $paymentDate, in: ...Date(),
                               displayedComponents: .date)
                    TextField("Comentarios (opcional)", text: $comments, axis: .vertical)
                }

                Section {
                    photoControl
                } header: {
                    Text("Evidencia (opcional)")
                } footer: {
                    Text("Adjuntar foto requiere conexión. Sin foto, el pago se guarda y se envía al sincronizar.")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Reportar pago")
            .navigationBarTitleDisplayModeInlineCompat()
            .task { loadBlockedInvoices() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reportar") { Task { await submit() } }
                        .disabled(amountField.amount <= 0 || !methodDetailsValid || submitting)
                }
            }
        }
    }

    /// Facturas ya incluidas en un pago activo (queued/synced) del cliente → no seleccionables.
    private func loadBlockedInvoices() {
        blockedInvoices = (try? CarteraRepository(database: environment.database)
            .activeInvoiceNumbers(clientCode: client.clientCode)) ?? []
    }

    // MARK: - Filas

    private func invoiceRow(_ invoice: OpenInvoiceSummary) -> some View {
        let blocked = blockedInvoices.contains(invoice.invoiceDocNum)
        let isOn = selected.contains(invoice.invoiceDocNum)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                if blocked {
                    errorMessage = "Ya hay un pago reportado con esta factura."
                } else {
                    toggle(invoice)
                }
            } label: {
                HStack {
                    Image(systemName: blocked ? "lock.fill" : (isOn ? "checkmark.circle.fill" : "circle"))
                        .foregroundStyle(blocked ? .secondary : (isOn ? Color.accentColor : .secondary))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Factura \(invoice.invoiceDocNum)").font(.body.weight(.medium))
                        Text("Saldo \(MoneyFormat.string(invoice.amount)) · vence \(invoice.dueDate.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                        if blocked {
                            Text("Ya incluida en un pago reportado").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                }
                .foregroundStyle(blocked ? .secondary : .primary)
                .opacity(blocked ? 0.6 : 1)
            }
            .buttonStyle(.plain)

            if isOn && !blocked {
                HStack {
                    Text("Aplicar").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    TextField("0", value: Binding(
                        get: { appliedAmount[invoice.invoiceDocNum] ?? invoice.amount },
                        set: { appliedAmount[invoice.invoiceDocNum] = $0 }
                    ), format: .number)
                    .multilineTextAlignment(.trailing).frame(width: 110)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                }
            }
        }
    }

    private var amountRow: some View {
        HStack {
            Text("Monto pagado")
            Spacer()
            // El `set` marca el monto como editado a mano → deja de auto-poblarse. El auto-relleno
            // asigna `amountField` por otro camino (selectionChanged), sin pasar por este setter.
            TextField("0", value: Binding(
                get: { amountField.amount },
                set: { amountField.userEdited($0) }
            ), format: .number)
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

    private func toggle(_ invoice: OpenInvoiceSummary) {
        if selected.contains(invoice.invoiceDocNum) {
            selected.remove(invoice.invoiceDocNum)
        } else {
            selected.insert(invoice.invoiceDocNum)
            if appliedAmount[invoice.invoiceDocNum] == nil {
                appliedAmount[invoice.invoiceDocNum] = invoice.amount
            }
        }
        // Auto-puebla "Monto pagado" con la suma de lo seleccionado (salvo que ya se editó a mano).
        amountField.selectionChanged(selectedSum: selectedInvoicesSum)
    }

    /// Suma de las facturas seleccionadas, usando el monto propuesto por factura (que por defecto
    /// es el saldo). Es lo que se auto-puebla en "Monto pagado".
    private var selectedInvoicesSum: Double {
        client.openInvoices
            .filter { selected.contains($0.invoiceDocNum) }
            .reduce(0) { $0 + (appliedAmount[$1.invoiceDocNum] ?? $1.amount) }
    }

    /// Trim de los datos de cheque (se validan/envían sin espacios).
    private var trimmedCheckNumber: String { checkNumber.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBankCode: String { bankCode.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Validación cliente de los datos condicionados por método (★ v0.19.1):
    /// TRANSFERENCIA exige banco; CHEQUE exige número y código de banco. EFECTIVO/OTRO no piden nada.
    private var methodDetailsValid: Bool {
        switch method {
        case .transferencia: return bank != nil
        case .cheque: return !trimmedCheckNumber.isEmpty && !trimmedBankCode.isEmpty
        case .efectivo, .otro: return true
        }
    }

    private func submit() async {
        submitting = true; errorMessage = nil
        defer { submitting = false }

        let apps = client.openInvoices
            .filter { selected.contains($0.invoiceDocNum) }
            .map { InvoiceApplication(invoiceDocNum: $0.invoiceDocNum,
                                      amount: appliedAmount[$0.invoiceDocNum] ?? $0.amount) }
        // Solo se adjunta el dato del método correspondiente; el resto queda nil (el contrato exige
        // null en los otros métodos). La UI condicional ya garantiza que no se mezclen.
        let draft = PaymentDraft(
            clientCode: client.clientCode, method: method, amount: amountField.amount, paymentDate: paymentDate,
            comments: comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : comments,
            proposedApplications: apps,
            transferBankAccount: method == .transferencia ? bank : nil,
            checkNumber: method == .cheque ? trimmedCheckNumber : nil,
            bankCode: method == .cheque ? trimmedBankCode : nil)
        let service = CarteraSubmitService(
            repo: CarteraRepository(database: environment.database), api: environment.api)

        do {
            let outcome = try await service.submitPayment(
                draft, imageBase64: photoBase64, isOnline: environment.network.isOnline)
            switch outcome {
            case .blockedNeedsConnection:
                // No se envía a una cola que no resolvería bien la foto: se avisa y NO se cierra.
                errorMessage = "Necesitas conexión para adjuntar una foto. Puedes reportar sin foto, o intentarlo más tarde con señal."
            case .queued:
                finish("Pago guardado. Se enviará al sincronizar.")
            case .sent:
                finish("Pago reportado.")
            case .pendingUpload:
                finish("Foto subida. El pago se enviará al reconectar.")
            case .failed(let reason):
                finish("El servidor rechazó el pago: \(reason) Míralo en Ajustes → Problemas de sincronización.")
            }
        } catch {
            errorMessage = "No se pudo reportar el pago: \(error.localizedDescription)"
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
