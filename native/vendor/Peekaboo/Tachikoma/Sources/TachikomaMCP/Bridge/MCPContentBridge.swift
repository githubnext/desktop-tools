import Foundation
import MCP
import Tachikoma

enum MCPContentBridge {
    private struct ResourceLinkDetails {
        let title: String?
        let description: String?
        let mimeType: String?
    }

    static func summary(for content: MCP.Tool.Content) -> String {
        switch content {
        case let .text(text, _, _):
            return text
        case let .image(data, mimeType, _, _):
            return "[Image: \(mimeType), size: \(data.count) bytes]"
        case let .resource(resource, _, _):
            if let text = resource.text {
                return text
            }
            if let blob = resource.blob {
                return "[Resource: \(resource.uri), blob size: \(blob.count) bytes]"
            }
            return "[Resource: \(resource.uri)]"
        case let .resourceLink(uri, _, _, _, mimeType, _):
            if let mimeType {
                return "[Resource Link: \(uri), type: \(mimeType)]"
            }
            return "[Resource Link: \(uri)]"
        case let .audio(data, mimeType, _, _):
            return "[Audio: \(mimeType), size: \(data.count) bytes]"
        }
    }

    static func convert(_ content: MCP.Tool.Content) -> AnyAgentToolValue {
        switch content {
        case let .text(text, _, _):
            AnyAgentToolValue(string: text)
        case let .image(data, mimeType, _, _):
            AnyAgentToolValue(object: [
                "type": AnyAgentToolValue(string: "image"),
                "mimeType": AnyAgentToolValue(string: mimeType),
                "data": AnyAgentToolValue(string: data),
            ])
        case let .resource(resource, annotations, meta):
            AnyAgentToolValue(object: self.resourceObject(
                resource: resource,
                annotations: annotations,
                meta: meta,
            ))
        case let .resourceLink(uri, name, title, description, mimeType, annotations):
            AnyAgentToolValue(object: self.resourceLinkObject(
                uri: uri,
                name: name,
                details: ResourceLinkDetails(
                    title: title,
                    description: description,
                    mimeType: mimeType,
                ),
                annotations: annotations,
            ))
        case let .audio(data, mimeType, _, _):
            AnyAgentToolValue(object: [
                "type": AnyAgentToolValue(string: "audio"),
                "mimeType": AnyAgentToolValue(string: mimeType),
                "data": AnyAgentToolValue(string: data),
            ])
        }
    }

    private static func resourceObject(
        resource: Resource.Content,
        annotations: Resource.Annotations?,
        meta: Metadata?,
    )
        -> [String: AnyAgentToolValue]
    {
        var resourceDict: [String: AnyAgentToolValue] = [
            "type": AnyAgentToolValue(string: "resource"),
            "uri": AnyAgentToolValue(string: resource.uri),
        ]

        if let mimeType = resource.mimeType {
            resourceDict["mimeType"] = AnyAgentToolValue(string: mimeType)
        } else {
            resourceDict["mimeType"] = AnyAgentToolValue(null: ())
        }

        if let text = resource.text {
            resourceDict["text"] = AnyAgentToolValue(string: text)
        } else {
            resourceDict["text"] = AnyAgentToolValue(null: ())
        }

        if let blob = resource.blob {
            resourceDict["blob"] = AnyAgentToolValue(string: blob)
        }

        if let annotations {
            resourceDict["annotations"] = self.convert(annotations)
        }

        if let meta {
            resourceDict["meta"] = self.convert(meta)
        }

        return resourceDict
    }

    private static func resourceLinkObject(
        uri: String,
        name: String,
        details: ResourceLinkDetails,
        annotations: Resource.Annotations?,
    )
        -> [String: AnyAgentToolValue]
    {
        var resourceDict: [String: AnyAgentToolValue] = [
            "type": AnyAgentToolValue(string: "resourceLink"),
            "uri": AnyAgentToolValue(string: uri),
            "name": AnyAgentToolValue(string: name),
        ]

        if let title = details.title {
            resourceDict["title"] = AnyAgentToolValue(string: title)
        }

        if let description = details.description {
            resourceDict["description"] = AnyAgentToolValue(string: description)
        }

        if let mimeType = details.mimeType {
            resourceDict["mimeType"] = AnyAgentToolValue(string: mimeType)
        }

        if let annotations {
            resourceDict["annotations"] = self.convert(annotations)
        }

        return resourceDict
    }

    private static func convert(_ annotations: Resource.Annotations) -> AnyAgentToolValue {
        var dict: [String: AnyAgentToolValue] = [:]

        if let audience = annotations.audience {
            dict["audience"] = AnyAgentToolValue(array: audience.map {
                AnyAgentToolValue(string: $0.rawValue)
            })
        }

        if let priority = annotations.priority {
            dict["priority"] = AnyAgentToolValue(double: priority)
        }

        if let lastModified = annotations.lastModified {
            dict["lastModified"] = AnyAgentToolValue(string: lastModified)
        }

        return AnyAgentToolValue(object: dict)
    }

    private static func convert(_ metadata: Metadata) -> AnyAgentToolValue {
        AnyAgentToolValue(object: metadata.fields.mapValues { $0.toAnyAgentToolValue() })
    }
}
