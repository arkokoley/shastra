// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shastra",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ShastraCore", targets: ["ShastraCore"]),
        .executable(name: "Shastra", targets: ["ShastraApp"]),
        .executable(name: "ShastraSelfTest", targets: ["ShastraSelfTest"]),
        .executable(name: "ShastraService", targets: ["ShastraService"]),
        .executable(name: "ShastraCLI", targets: ["ShastraCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder.git", revision: "a2bbd2796fe3064e107de18cb56031052c4fa899"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", revision: "493d99e4e3e99a27077bf24bc0e1c8d20f9f7925"),
        .package(url: "https://github.com/groue/GRDB.swift.git", revision: "b83108d10f42680d78f23fe4d4d80fc88dab3212")
    ],
    targets: [
        .target(name: "ShastraCore", dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder"), .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "ShastraApp", dependencies: ["ShastraCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "ShastraSelfTest", dependencies: ["ShastraCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "ShastraService", dependencies: ["ShastraCore"]),
        .executableTarget(name: "ShastraCLI", dependencies: ["ShastraCore"]),
        .testTarget(name: "ShastraCoreTests", dependencies: ["ShastraCore"])
    ]
)
