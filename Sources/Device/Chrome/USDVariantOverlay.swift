import Foundation

public enum USDVariantOverlay {
    public static func make(
        assetReference: String,
        selections: [DeviceVariantSelection]
    ) throws -> String {
        guard !assetReference.contains("@"),
              !assetReference.contains("\n"),
              !assetReference.contains("\r") else {
            throw DeviceModelError.invalidAssetReference
        }

        var byPath: [[String]: [DeviceVariantSelection]] = [:]
        for selection in selections {
            let components = selection.primPath
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard selection.primPath.hasPrefix("/"), !components.isEmpty else {
                throw DeviceModelError.invalidUSDIdentifier(selection.primPath)
            }
            for identifier in components {
                try validate(identifier)
            }
            try validate(selection.usdName)
            byPath[components, default: []].append(selection)
        }

        var source = """
        #usda 1.0
        (
            subLayers = [@\(assetReference)@]
        )

        """
        source += "\n"
        let roots = Set(byPath.keys.compactMap(\.first)).sorted()
        for root in roots {
            source += render(
                name: root,
                path: [root],
                selectionsByPath: byPath,
                indentation: ""
            )
        }
        return source
    }

    private static func render(
        name: String,
        path: [String],
        selectionsByPath: [[String]: [DeviceVariantSelection]],
        indentation: String
    ) -> String {
        let selections = (selectionsByPath[path] ?? [])
            .sorted { $0.usdName < $1.usdName }
        var result = "\(indentation)over \"\(name)\""
        if !selections.isEmpty {
            result += " (\n\(indentation)    variants = {\n"
            for selection in selections {
                result += "\(indentation)        string \(selection.usdName) = \"\(escape(selection.usdValue))\"\n"
            }
            result += "\(indentation)    }\n\(indentation))"
        }
        result += "\n\(indentation){\n"

        let children = Set(selectionsByPath.keys.compactMap { candidate -> String? in
            guard candidate.count > path.count,
                  Array(candidate.prefix(path.count)) == path else {
                return nil
            }
            return candidate[path.count]
        }).sorted()
        for child in children {
            result += render(
                name: child,
                path: path + [child],
                selectionsByPath: selectionsByPath,
                indentation: indentation + "    "
            )
        }
        result += "\(indentation)}\n"
        return result
    }

    private static func validate(_ identifier: String) throws {
        let pattern = #"^[A-Za-z_][A-Za-z0-9_]*$"#
        guard identifier.range(of: pattern, options: .regularExpression) != nil else {
            throw DeviceModelError.invalidUSDIdentifier(identifier)
        }
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: "\"", with: #"\""#)
            .replacingOccurrences(of: "\n", with: #"\n"#)
            .replacingOccurrences(of: "\r", with: #"\r"#)
    }
}
