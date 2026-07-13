import Foundation

// DTOs de autenticación según `openapi.yaml` (schemas LoginRequest / LoginResponse).

/// Cuerpo de `POST /auth/login`.
struct LoginRequest: Encodable {
    let username: String
    let password: String
}

/// Respuesta de `POST /auth/login`.
struct LoginResponse: Decodable, Equatable {
    let token: String               // JWT de acceso
    let role: String?               // VENDEDOR | ADMIN (la app es de vendedores)
    let salespersonCode: String?    // código de vendedor (solo si role=VENDEDOR)
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case token, role
        case salespersonCode = "salesperson_code"
        case displayName = "display_name"
    }
}
