import Foundation

extension LaunchRequest {
    public static let urlScheme = "zweicommander"
    /// Only navigation is transported. Import/export and executable commands
    /// cannot be requested by an external URL.
    public func navigationURL() throws -> URL {
        guard settingsImportPath == nil, settingsExportPath == nil else {
            throw CommanderError.message("Für einen Einstellungsimport die laufende App zuerst beenden.")
        }
        var items:[URLQueryItem] = []
        for (side,target) in [("left",left),("right",right)] {
            if let target {
                items.append(URLQueryItem(name:side,value:target.directory.path))
                if let selection = target.selection { items.append(URLQueryItem(name:"select-"+side,value:selection.lastPathComponent)) }
            }
        }
        if let active { items.append(URLQueryItem(name:"active",value:active.rawValue)) }
        if newTabs { items.append(URLQueryItem(name:"new-tabs",value:"1")) }
        var components = URLComponents();components.scheme = Self.urlScheme;components.host = "open"
        if !items.isEmpty { components.queryItems = items }
        guard let url = components.url else { throw CommanderError.message("Startanfrage konnte nicht erstellt werden.") }
        return url
    }
    public static func navigationRequest(_ url:URL) throws -> LaunchRequest {
        guard url.absoluteString.utf8.count <= 200_000,let components = URLComponents(url:url,resolvingAgainstBaseURL:false),
              components.scheme?.lowercased() == urlScheme,components.host?.lowercased() == "open",components.path.isEmpty || components.path == "/",
              components.user == nil,components.password == nil,components.port == nil,components.fragment == nil else {
            throw CommanderError.message("Ungültige ZweiCommander-Startadresse.")
        }
        let items = components.queryItems ?? [],allowed:Set<String> = ["left","right","select-left","select-right","active","new-tabs"]
        guard items.count <= allowed.count,Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ allowed.contains($0.name) && $0.value != nil && !$0.value!.isEmpty }) else {
            throw CommanderError.message("Unbekannte, doppelte oder leere Werte in der Startadresse.")
        }
        var arguments:[String] = []
        for item in items {
            if item.name == "new-tabs" {
                guard item.value == "1" else { throw CommanderError.message("Ungültige Taboption in der Startadresse.") }
                arguments.append("--new-tabs")
            } else {
                let value = item.value!
                arguments += ["--"+item.name,item.name.hasPrefix("select-") && value.hasPrefix("--") ? "./"+value : value]
            }
        }
        return try parse(arguments)
    }
}
