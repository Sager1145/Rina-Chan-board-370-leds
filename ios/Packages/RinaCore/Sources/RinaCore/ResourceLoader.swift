import Foundation

/// Typed, cached loaders for the JSON resources under `RinaBoard/Resources`
/// (see `Resources/README.md`). Each document is parsed once per bundle and
/// cached, since `expression_parts.json` and `ark12.json` are multi-megabyte.
public enum RinaResources {
    public enum LoaderError: Error, Equatable {
        case resourceNotFound(name: String, ext: String)
    }

    /// Reads `<name>.<ext>` from `bundle`, throwing `LoaderError.resourceNotFound`
    /// if it isn't present.
    public static func data(named name: String, ext: String, in bundle: Bundle) throws -> Data {
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw LoaderError.resourceNotFound(name: name, ext: ext)
        }
        return try Data(contentsOf: url)
    }

    private static let lock = NSLock()
    private static var partsLibraryCache: [ObjectIdentifier: PartsLibrary] = [:]
    private static var colorPresetsCache: [ObjectIdentifier: ColorPresets] = [:]
    private static var defaultFacesCache: [ObjectIdentifier: FaceDocument] = [:]
    private static var appDefaultsCache: [ObjectIdentifier: AppDefaults] = [:]
    private static var matrixGeometryJSONCache: [ObjectIdentifier: Data] = [:]

    /// `expression_parts.json`, decoded once per `bundle`.
    public static func partsLibrary(bundle: Bundle = .main) throws -> PartsLibrary {
        let key = ObjectIdentifier(bundle)
        lock.lock()
        if let cached = partsLibraryCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let value = try PartsLibrary(jsonData: data(named: "expression_parts", ext: "json", in: bundle))
        lock.lock()
        partsLibraryCache[key] = value
        lock.unlock()
        return value
    }

    /// `color_presets.json`, decoded once per `bundle`.
    public static func colorPresets(bundle: Bundle = .main) throws -> ColorPresets {
        let key = ObjectIdentifier(bundle)
        lock.lock()
        if let cached = colorPresetsCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let value = try ColorPresets(jsonData: data(named: "color_presets", ext: "json", in: bundle))
        lock.lock()
        colorPresetsCache[key] = value
        lock.unlock()
        return value
    }

    /// `default_faces.json`, decoded once per `bundle`.
    public static func defaultFaces(bundle: Bundle = .main) throws -> FaceDocument {
        let key = ObjectIdentifier(bundle)
        lock.lock()
        if let cached = defaultFacesCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let value = try FaceDocument(jsonData: data(named: "default_faces", ext: "json", in: bundle))
        lock.lock()
        defaultFacesCache[key] = value
        lock.unlock()
        return value
    }

    /// The app-relevant subset of `webui_config.json`, merged with
    /// `scroll_text_defaults.json` where useful, decoded once per `bundle`.
    /// Falls back to `AppDefaults.fallback` if either resource is missing.
    public static func appDefaults(bundle: Bundle = .main) -> AppDefaults {
        let key = ObjectIdentifier(bundle)
        lock.lock()
        if let cached = appDefaultsCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let value: AppDefaults
        if let configData = try? data(named: "webui_config", ext: "json", in: bundle),
           let decoded = try? AppDefaults(webuiConfigJSON: configData) {
            value = decoded
        } else {
            value = .fallback
        }
        lock.lock()
        appDefaultsCache[key] = value
        lock.unlock()
        return value
    }

    /// `scroll_text_defaults.json`, or `ScrollTextDefaults.fallback` if missing.
    public static func scrollTextDefaults(bundle: Bundle = .main) -> ScrollTextDefaults {
        guard let raw = try? data(named: "scroll_text_defaults", ext: "json", in: bundle),
              let decoded = try? JSONDecoder().decode(ScrollTextDefaults.self, from: raw) else {
            return .fallback
        }
        return decoded
    }

    /// Raw `matrix_geometry.json` bytes, decoded once per `bundle`. Callers
    /// decode the fields they need (e.g. `physical_to_logical_index`).
    public static func matrixGeometryJSON(bundle: Bundle = .main) throws -> Data {
        let key = ObjectIdentifier(bundle)
        lock.lock()
        if let cached = matrixGeometryJSONCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let value = try data(named: "matrix_geometry", ext: "json", in: bundle)
        lock.lock()
        matrixGeometryJSONCache[key] = value
        lock.unlock()
        return value
    }

    /// `matrix_geometry.json`'s `physical_to_logical_index` array (370
    /// entries), for use with `PartsLibrary.frameFromStripIndices(_:physicalToLogicalIndex:)`.
    public static func physicalToLogicalIndexTable(bundle: Bundle = .main) throws -> [Int] {
        struct Doc: Codable { let physicalToLogicalIndex: [Int]
            enum CodingKeys: String, CodingKey { case physicalToLogicalIndex = "physical_to_logical_index" }
        }
        let doc = try JSONDecoder().decode(Doc.self, from: matrixGeometryJSON(bundle: bundle))
        return doc.physicalToLogicalIndex
    }
}
