import Foundation
import PostieCore

public struct AutomationToolDefinition: Sendable {
    public let operation: AutomationOperation
    public let description: String
    public let inputSchema: AutomationJSON
}

public enum AutomationToolCatalog {
    public static let definitions: [AutomationToolDefinition] = AutomationOperation.allCases.map { operation in
        let fields: [String]
        let required: [String]
        let description: String
        switch operation {
        case .collectionsList:
            fields = []; required = []; description = "List accessible collections."
        case .requestsList:
            fields = ["collectionName", "query"]; required = [];
            description =
                "List accessible requests, optionally by collection name and a case-insensitive substring of the request name or saved URL path."
        case .requestsGet:
            fields = ["collectionName", "requestID"]; required = fields;
            description = "Read a request template without revealing encrypted secrets."
        case .requestsCreate:
            fields = ["collectionName", "request"]; required = fields;
            description = "Create a request from explicit editable fields."
        case .requestsUpdate:
            fields = ["collectionName", "requestID", "request"]; required = fields;
            description = "Patch explicit request fields, preserving omitted settings and access policy."
        case .requestsStart:
            fields = ["collectionName", "requestID"]; required = fields;
            description = "Start a request and return its run handle immediately."
        case .runsList:
            fields = []; required = []; description = "List accessible ongoing runs, including runs started in the app."
        case .runsGet:
            fields = ["runID"]; required = fields;
            description = "Read run state and policy-filtered response information."
        case .runsCancel:
            fields = ["runID"]; required = fields; description = "Cancel exactly the specified ongoing run."
        case .variablesList:
            fields = ["collectionName", "requestID"]; required = [];
            description = "List variable names and nonsecret values at global, collection, or request scope."
        case .variablesGet:
            fields = ["collectionName", "requestID", "name"]; required = ["name"];
            description = "Read one nonsecret variable. Secret values cannot be read directly."
        case .snapshotsList:
            fields = ["collectionName", "requestID"]; required = []; description = "List accessible saved snapshots."
        case .snapshotsGet:
            fields = ["snapshotID"]; required = fields;
            description = "Read a saved snapshot under its current response-view policy."
        case .snapshotsCreate:
            fields = ["runID", "name"]; required = ["runID"];
            description = "Save the exact completed run as a snapshot."
        case .snapshotsRename:
            fields = ["snapshotID", "name"]; required = fields; description = "Rename a saved snapshot."
        case .snapshotsDelete:
            fields = ["snapshotID"]; required = fields; description = "Delete a saved snapshot."
        }
        let properties = Dictionary(
            uniqueKeysWithValues: fields.map { field in
                (field, field == "request" ? requestSchema : AutomationJSON.object(["type": .string("string")]))
            })
        return AutomationToolDefinition(
            operation: operation,
            description: description,
            inputSchema: .object([
                "type": .string("object"), "properties": .object(properties),
                "required": .array(required.map(AutomationJSON.string)), "additionalProperties": .bool(false),
            ])
        )
    }

    private static var requestSchema: AutomationJSON {
        let string: AutomationJSON = .object(["type": .string("string")])
        let boolean: AutomationJSON = .object(["type": .string("boolean")])
        let row: AutomationJSON = .object([
            "type": .string("object"), "additionalProperties": .bool(false),
            "properties": .object(["name": string, "value": string, "isEnabled": boolean]),
            "required": .array([.string("name"), .string("value")]),
        ])
        let rows: AutomationJSON = .object(["type": .string("array"), "items": row, "maxItems": .number(4096)])
        let optionalNumber: AutomationJSON = .object([
            "type": .array([.string("number"), .string("null")]), "exclusiveMinimum": .number(0),
        ])
        let file: AutomationJSON = .object([
            "type": .array([.string("object"), .string("null")]),
            "additionalProperties": .bool(false),
            "properties": .object(["path": string, "filename": string, "contentType": string]),
            "required": .array([.string("path")]),
        ])
        let multipartPart: AutomationJSON = .object([
            "type": .string("object"), "additionalProperties": .bool(false),
            "properties": .object([
                "name": string,
                "kind": .object(["type": .string("string"), "enum": .array([.string("text"), .string("file")])]),
                "text": string, "file": file, "isEnabled": boolean,
            ]),
            "required": .array([.string("name"), .string("kind")]),
        ])
        return .object([
            "type": .string("object"), "additionalProperties": .bool(false),
            "properties": .object([
                "name": string, "method": string, "url": string,
                "pathParameters": rows, "query": rows, "headers": rows,
                "body": string, "bodyEnabled": boolean,
                "bodyKind": .object([
                    "type": .string("string"),
                    "enum": .array(RequestBodyKind.allCases.map { .string($0.rawValue) }),
                ]),
                "rawFile": file,
                "multipartParts": .object([
                    "type": .string("array"), "items": multipartPart, "maxItems": .number(4096),
                ]),
                "bodySyntax": .object([
                    "type": .string("string"),
                    "enum": .array(BodySyntax.allCases.map { .string($0.rawValue) }),
                ]),
                "inheritsCollectionAuthentication": boolean,
                "optionOverrides": .object([
                    "type": .string("object"), "additionalProperties": .bool(false),
                    "properties": .object([
                        "followRedirects": .object(["type": .array([.string("boolean"), .string("null")])]),
                        "inactivityTimeout": optionalNumber, "overallTimeout": optionalNumber,
                        "maximumResponseBytes": .object([
                            "type": .array([.string("integer"), .string("null")]), "minimum": .number(1),
                        ]),
                        "overallTimeoutIsUnlimited": boolean, "responseSizeIsUnlimited": boolean,
                    ]),
                ]),
                "authentication": .object([
                    "type": .string("object"), "additionalProperties": .bool(false),
                    "properties": .object([
                        "kind": .object([
                            "type": .string("string"),
                            "enum": .array(["none", "basic", "bearer", "apiKey"].map(AutomationJSON.string)),
                        ]),
                        "username": string, "password": string, "token": string,
                        "apiKeyHeaderName": string, "apiKey": string,
                    ]),
                ]),
            ]),
        ])
    }
}
