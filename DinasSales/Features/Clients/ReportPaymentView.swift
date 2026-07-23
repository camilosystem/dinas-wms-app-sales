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
    @State private var amount: Double = 0
    @State private var method: AccountPaymentMethod = .efectivo
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reportar") { Task { await submit() } }
                        .disabled(amount <= 0 || submitting)
                }
            }
        }
    }

    // MARK: - Filas

    private func invoiceRow(_ invoice: OpenInvoiceSummary) -> some View {
        let isOn = selected.contains(invoice.invoiceDocNum)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                toggle(invoice)
            } label: {
                HStack {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Factura \(invoice.invoiceDocNum)").font(.body.weight(.medium))
                        Text("Saldo \(MoneyFormat.string(invoice.amount)) · vence \(invoice.dueDate.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isOn {
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
            TextField("0", value: $amount, format: .number)
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
    }

    private func submit() async {
        submitting = true; errorMessage = nil
        defer { submitting = false }

        let apps = client.openInvoices
            .filter { selected.contains($0.invoiceDocNum) }
            .map { InvoiceApplication(invoiceDocNum: $0.invoiceDocNum,
                                      amount: appliedAmount[$0.invoiceDocNum] ?? $0.amount) }
        let draft = PaymentDraft(
            clientCode: client.clientCode, method: method, amount: amount, paymentDate: paymentDate,
            comments: comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : comments,
            proposedApplications: apps)
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
