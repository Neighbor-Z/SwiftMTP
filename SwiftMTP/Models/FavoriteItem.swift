import Foundation

struct FavoriteItem: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let name: String       // Localization key for display name
    let path: String       // Device path, e.g. "/DCIM"
    let icon: String       // SF Symbol name
    let isBuiltIn: Bool    // Built-in favorites cannot be deleted

    /// Human-readable display name (localized for built-in items)
    var displayName: String {
        if isBuiltIn {
            return String(localized: String.LocalizationValue(name))
        }
        return name
    }

    // MARK: – Built-in Favorites

    static let builtInFavorites: [FavoriteItem] = [
        FavoriteItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Photos",
            path: "/DCIM",
            icon: "photo.on.rectangle",
            isBuiltIn: true
        ),
        FavoriteItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "Downloads",
            path: "/Download",
            icon: "arrow.down.circle",
            isBuiltIn: true
        )
    ]
    
    static let defaultUserFavorites: [FavoriteItem] = [
        FavoriteItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Bluetooth",
            path: "/bluetooth",
            icon: "wave.3.right",
            isBuiltIn: false
        ),
        FavoriteItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            name: "Screenshots",
            path: "/Pictures/Screenshots",
            icon: "camera.viewfinder",
            isBuiltIn: false
        )
    ]
}
