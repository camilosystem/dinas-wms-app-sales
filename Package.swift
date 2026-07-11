// swift-tools-version:5.9
import PackageDescription

// App de Vendedores (Dinas WMS) — paquete SPM.
// El target apunta a la carpeta DinasSales/ para respetar la estructura del CLAUDE.md.
// El .xcodeproj (target de app iOS) se genera/abre desde Xcode sobre este paquete.
let package = Package(
    name: "DinasSales",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(name: "DinasSales", targets: ["DinasSales"])
    ],
    dependencies: [
        // Persistencia local SQLite (SQL-first).
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .target(
            name: "DinasSales",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "DinasSales"
        ),
        .testTarget(
            name: "DinasSalesTests",
            dependencies: ["DinasSales"],
            path: "DinasSalesTests"
        )
    ]
)
