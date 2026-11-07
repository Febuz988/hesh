// swift-tools-version:5.9
// Libreria Rust precompilata di libsignal. DEVE coincidere con la versione del
// package LibSignalClient in project.yml (altrimenti manca signal_ffi_version_X_Y_Z).
import PackageDescription

let version = "0.106.2"
let checksum = "416ca269870a0bb1e12784dfe96bbd548b585d4aa58f1c12d82b9e19da42a157"

let package = Package(
    name: "LibSignalFfi",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "LibSignalFfi", targets: ["LibSignalFfi"]),
    ],
    targets: [
        .binaryTarget(
            name: "LibSignalFfi",
            url: "https://build-artifacts.signal.org/libraries/libsignal-client-ios-build-v\(version).xcframework.zip",
            checksum: checksum
        ),
    ]
)
