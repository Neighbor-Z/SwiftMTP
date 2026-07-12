import Foundation
import Combine

/// Manages sidebar favorite items with persistence via UserDefaults.
final class FavoritesManager: ObservableObject {

    @Published var favorites: [FavoriteItem] = []

    private let userDefaultsKey = "neighborz.swiftmtp.sidebarFavorites"
    private let orderKey = "neighborz.swiftmtp.sidebarFavoritesOrder"

    init() {
        loadFavorites()
    }

    // MARK: – Public API

    /// Add a user-defined favorite from a folder path.
    func addFavorite(name: String, path: String) {
        guard !contains(path: path) else { return }
        let item = FavoriteItem(
            id: UUID(),
            name: name,
            path: path,
            icon: "folder",
            isBuiltIn: false
        )
        favorites.append(item)
        save()
    }

    /// Remove a user-defined favorite. Built-in favorites cannot be removed.
    func removeFavorite(id: UUID) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        guard !favorites[index].isBuiltIn else { return }
        favorites.remove(at: index)
        save()
    }

    /// Move a favorite from one position to another (drag reorder).
    func moveFavorite(from source: IndexSet, to destination: Int) {
        favorites.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Check whether a path is already in favorites.
    func contains(path: String) -> Bool {
        favorites.contains { $0.path == path }
    }

    // MARK: – Persistence

    private func loadFavorites() {
        // Load user-added favorites from UserDefaults
        let userFavorites: [FavoriteItem]
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode([FavoriteItem].self, from: data) {
            userFavorites = decoded
        } else {
            userFavorites = FavoriteItem.defaultUserFavorites
        }

        // Load saved order (array of UUID strings)
        let savedOrder = UserDefaults.standard.stringArray(forKey: orderKey)

        // Merge built-in + user favorites
        let allItems = FavoriteItem.builtInFavorites + userFavorites

        if let savedOrder, !savedOrder.isEmpty {
            // Restore saved order
            var orderedItems: [FavoriteItem] = []
            for idString in savedOrder {
                if let uuid = UUID(uuidString: idString),
                   let item = allItems.first(where: { $0.id == uuid }) {
                    orderedItems.append(item)
                }
            }
            // Append any new items not in the saved order (e.g. new built-in items added in an update)
            for item in allItems where !orderedItems.contains(where: { $0.id == item.id }) {
                orderedItems.append(item)
            }
            favorites = orderedItems
        } else {
            favorites = allItems
        }
    }

    private func save() {
        // Save only user-added favorites
        let userFavorites = favorites.filter { !$0.isBuiltIn }
        if let data = try? JSONEncoder().encode(userFavorites) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }

        // Save the full order (all items, including built-in)
        let orderArray = favorites.map { $0.id.uuidString }
        UserDefaults.standard.set(orderArray, forKey: orderKey)
    }
}
