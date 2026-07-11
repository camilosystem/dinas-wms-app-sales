import Foundation
import os

/// Loggers categorizados (unified logging de Apple).
///
/// Ver en Console.app o `log stream --predicate 'subsystem == "com.dinas.sales"'`.
///
/// Privacidad: por defecto los valores dinámicos se **redactan** en los logs. Solo se
/// marca `.public` lo que es seguro (conteos, códigos de estado HTTP, UUIDs de orden —
/// que son claves de idempotencia, no datos personales). NUNCA se loguea el JWT,
/// contraseñas ni datos del cliente.
enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.dinas.sales"

    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let api = Logger(subsystem: subsystem, category: "api")
    static let network = Logger(subsystem: subsystem, category: "network")
}
