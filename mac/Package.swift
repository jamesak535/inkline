// swift-tools-version:5.9
import PackageDescription

// The Inkline macOS shell. In Phase 1 this is a tiny executable that proves the
// Swift → Rust → callback → Swift round-trip. Phase 2 grows it into the real app
// (event tap, AX reading, ghost-text overlay).
//
// Link flags (path to the built Rust core + rpath) are supplied at build time by
// ../run.sh via `-Xlinker`, so this manifest stays free of machine-specific paths.
let package = Package(
    name: "Inkline",
    platforms: [.macOS(.v13)],
    targets: [
        // C-ABI surface of the Rust core (generated header + module map).
        .systemLibrary(name: "CInklineCore", path: "Sources/CInklineCore"),
        .executableTarget(
            name: "inkline",
            dependencies: ["CInklineCore"]
        ),
    ]
)
