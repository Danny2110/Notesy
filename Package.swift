// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notesy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Notesy", targets: ["NotesyApp"])],
    targets: [
        .executableTarget(
            name: "NotesyApp",
            path: ".",
            exclude: ["dist", "docs", ".build", "scripts", "Icon", "assets", "Assets.xcassets", "tools", "website", "Notesy.icns", "Notesy_v2_large.png"],
            sources: ["Sources/NotesyApp/main.swift", "Sources/NotesyApp/NotesWorkspaceView.swift", "Sources/NotesyApp/OnboardingGuideView.swift", "Sources/NotesyApp/Theme.swift", "Sources/NotesyApp/ThemeView.swift", "NoteModel.swift", "WorkspaceScrollView.swift", "LiquidGlassBoxView.swift", "HapticCanvasView.swift", "Sources/NotesyApp/AppleNotesImporter.swift", "GlassSurface.swift"]
        )
    ]
)
