import Foundation

// ⚠️ SUPUESTO DE CONTRATO — PENDIENTE DE CONFIRMAR CON dinas-wms-contracts/openapi.yaml
//
// El contrato OpenAPI no está disponible en este entorno. Estos DTOs asumen el shape
// más estándar para `POST /auth/login`:
//
//   Request:  { "username": "...", "password": "..." }
//   Response: { "token": "<jwt>" }
//
// Es el ÚNICO lugar donde vive el formato de red de login. Cuando llegue el contrato,
// ajustar aquí (nombres de campos, envoltura, campos extra como expiración/refresh).
// Si difiere, es señal para el Arquitecto.

/// Cuerpo de `POST /auth/login`.
struct LoginRequest: Encodable {
    let username: String
    let password: String
}

/// Respuesta de `POST /auth/login`. Se extrae el JWT que se guarda en Keychain.
struct LoginResponse: Decodable {
    let token: String
}
