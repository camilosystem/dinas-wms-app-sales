#!/usr/bin/env swift
// Genera un icono de app 1024×1024 (placeholder) sin herramientas externas.
//   swift Scripts/make_icon.swift <ruta_salida.png>
// Dibuja un fondo con degradado azul y una "D" blanca centrada (Dinas).

import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Foundation

let out = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon-1024.png"

let W = 1024
let space = CGColorSpaceCreateDeviceRGB()
// Sin alfa (noneSkipLast): los iconos de app no admiten canal alfa.
guard let ctx = CGContext(
    data: nil, width: W, height: W, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("No se pudo crear el contexto") }

// Fondo con degradado vertical (azul oscuro -> azul).
let colors = [
    CGColor(red: 0.06, green: 0.18, blue: 0.42, alpha: 1),
    CGColor(red: 0.10, green: 0.40, blue: 0.85, alpha: 1)
] as CFArray
if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: W),
                           end: CGPoint(x: 0, y: 0),
                           options: [])
}

// "D" blanca centrada.
let fontSize: CGFloat = 620
let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
let attrs: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String):
        CGColor(red: 1, green: 1, blue: 1, alpha: 1)
]
let attr = NSAttributedString(string: "D", attributes: attrs)
let line = CTLineCreateWithAttributedString(attr)
let bounds = CTLineGetImageBounds(line, ctx)
ctx.textPosition = CGPoint(
    x: (CGFloat(W) - bounds.width) / 2 - bounds.minX,
    y: (CGFloat(W) - bounds.height) / 2 - bounds.minY
)
CTLineDraw(line, ctx)

guard let image = ctx.makeImage() else { fatalError("No se pudo renderizar") }
let url = URL(fileURLWithPath: out) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)
else { fatalError("No se pudo crear el destino PNG") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("No se pudo escribir el PNG") }
print("Icono escrito en \(out)")
