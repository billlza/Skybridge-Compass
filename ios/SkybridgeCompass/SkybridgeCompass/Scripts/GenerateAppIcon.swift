#!/usr/bin/env swift

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    fputs("usage: GenerateAppIcon.swift <output-path>\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let size: Int = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

guard let context = CGContext(data: nil,
                              width: size,
                              height: size,
                              bitsPerComponent: 8,
                              bytesPerRow: size * 4,
                              space: colorSpace,
                              bitmapInfo: bitmapInfo) else {
    fatalError("Unable to create CGContext for icon rendering.")
}

let rect = CGRect(x: 0, y: 0, width: size, height: size)

let gradientColors = [
    CGColor(red: 0.13, green: 0.22, blue: 0.52, alpha: 1.0),
    CGColor(red: 0.23, green: 0.54, blue: 0.87, alpha: 1.0)
] as CFArray
let locations: [CGFloat] = [0.0, 1.0]
if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: locations) {
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: 0),
                               end: CGPoint(x: CGFloat(size), y: CGFloat(size)),
                               options: [])
}

let innerCircleRect = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08)
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
context.fillEllipse(in: innerCircleRect)

context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.36))
context.setLineWidth(rect.width * 0.02)
context.strokeEllipse(in: innerCircleRect)

let needlePath = CGMutablePath()
let center = CGPoint(x: rect.midX, y: rect.midY)
let northPoint = CGPoint(x: center.x, y: rect.minY + rect.height * 0.18)
let southPoint = CGPoint(x: center.x, y: rect.maxY - rect.height * 0.18)
needlePath.move(to: southPoint)
needlePath.addLine(to: center)
needlePath.addLine(to: northPoint)

context.setLineCap(.round)
context.setLineWidth(rect.width * 0.045)
context.setStrokeColor(CGColor(red: 1.0, green: 0.32, blue: 0.29, alpha: 0.95))
context.addPath(needlePath)
context.strokePath()

let tipPath = CGMutablePath()
let tipSize = rect.width * 0.12
let tipBase = CGPoint(x: center.x, y: rect.minY + rect.height * 0.20)
let tipLeft = CGPoint(x: tipBase.x - tipSize * 0.4, y: tipBase.y + tipSize * 0.9)
let tipRight = CGPoint(x: tipBase.x + tipSize * 0.4, y: tipBase.y + tipSize * 0.9)
tipPath.move(to: northPoint)
tipPath.addLine(to: tipLeft)
tipPath.addLine(to: tipRight)
tipPath.closeSubpath()
context.setFillColor(CGColor(red: 1.0, green: 0.64, blue: 0.38, alpha: 0.95))
context.addPath(tipPath)
context.fillPath()

context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.75))
let hubRadius = rect.width * 0.07
let hubRect = CGRect(x: center.x - hubRadius, y: center.y - hubRadius, width: hubRadius * 2, height: hubRadius * 2)
context.fillEllipse(in: hubRect)

context.setFillColor(CGColor(red: 0.13, green: 0.22, blue: 0.52, alpha: 0.95))
let innerHubRadius = hubRadius * 0.45
let innerHubRect = CGRect(x: center.x - innerHubRadius, y: center.y - innerHubRadius, width: innerHubRadius * 2, height: innerHubRadius * 2)
context.fillEllipse(in: innerHubRect)

guard let image = context.makeImage() else {
    fatalError("Unable to finalize icon image from context.")
}

let destinationURL = outputURL
let destinationParent = destinationURL.deletingLastPathComponent()
try? FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)

guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL,
                                                         UTType.png.identifier as CFString,
                                                         1,
                                                         nil) else {
    fatalError("Unable to create PNG destination for icon.")
}

CGImageDestinationAddImage(destination, image, nil)
if !CGImageDestinationFinalize(destination) {
    fatalError("Failed to write generated icon to \(destinationURL.path)")
}
