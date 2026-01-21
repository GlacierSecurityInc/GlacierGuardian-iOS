//  This file was automatically generated and should not be edited.

#if canImport(AWSAPIPlugin)
import Foundation

public protocol GraphQLInputValue {
}

public struct GraphQLVariable {
  let name: String
  
  public init(_ name: String) {
    self.name = name
  }
}

extension GraphQLVariable: GraphQLInputValue {
}

extension JSONEncodable {
  public func evaluate(with variables: [String: JSONEncodable]?) throws -> Any {
    return jsonValue
  }
}

public typealias GraphQLMap = [String: JSONEncodable?]

extension Dictionary where Key == String, Value == JSONEncodable? {
  public var withNilValuesRemoved: Dictionary<String, JSONEncodable> {
    var filtered = Dictionary<String, JSONEncodable>(minimumCapacity: count)
    for (key, value) in self {
      if value != nil {
        filtered[key] = value
      }
    }
    return filtered
  }
}

public protocol GraphQLMapConvertible: JSONEncodable {
  var graphQLMap: GraphQLMap { get }
}

public extension GraphQLMapConvertible {
  var jsonValue: Any {
    return graphQLMap.withNilValuesRemoved.jsonValue
  }
}

public typealias GraphQLID = String

public protocol APISwiftGraphQLOperation: AnyObject {
  
  static var operationString: String { get }
  static var requestString: String { get }
  static var operationIdentifier: String? { get }
  
  var variables: GraphQLMap? { get }
  
  associatedtype Data: GraphQLSelectionSet
}

public extension APISwiftGraphQLOperation {
  static var requestString: String {
    return operationString
  }

  static var operationIdentifier: String? {
    return nil
  }

  var variables: GraphQLMap? {
    return nil
  }
}

public protocol GraphQLQuery: APISwiftGraphQLOperation {}

public protocol GraphQLMutation: APISwiftGraphQLOperation {}

public protocol GraphQLSubscription: APISwiftGraphQLOperation {}

public protocol GraphQLFragment: GraphQLSelectionSet {
  static var possibleTypes: [String] { get }
}

public typealias Snapshot = [String: Any?]

public protocol GraphQLSelectionSet: Decodable {
  static var selections: [GraphQLSelection] { get }
  
  var snapshot: Snapshot { get }
  init(snapshot: Snapshot)
}

extension GraphQLSelectionSet {
    public init(from decoder: Decoder) throws {
        if let jsonObject = try? APISwiftJSONValue(from: decoder) {
            let encoder = JSONEncoder()
            let jsonData = try encoder.encode(jsonObject)
            let decodedDictionary = try JSONSerialization.jsonObject(with: jsonData, options: []) as! [String: Any]
            let optionalDictionary = decodedDictionary.mapValues { $0 as Any? }

            self.init(snapshot: optionalDictionary)
        } else {
            self.init(snapshot: [:])
        }
    }
}

enum APISwiftJSONValue: Codable {
    case array([APISwiftJSONValue])
    case boolean(Bool)
    case number(Double)
    case object([String: APISwiftJSONValue])
    case string(String)
    case null
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let value = try? container.decode([String: APISwiftJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([APISwiftJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .null
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch self {
        case .array(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public protocol GraphQLSelection {
}

public struct GraphQLField: GraphQLSelection {
  let name: String
  let alias: String?
  let arguments: [String: GraphQLInputValue]?
  
  var responseKey: String {
    return alias ?? name
  }
  
  let type: GraphQLOutputType
  
  public init(_ name: String, alias: String? = nil, arguments: [String: GraphQLInputValue]? = nil, type: GraphQLOutputType) {
    self.name = name
    self.alias = alias
    
    self.arguments = arguments
    
    self.type = type
  }
}

public indirect enum GraphQLOutputType {
  case scalar(JSONDecodable.Type)
  case object([GraphQLSelection])
  case nonNull(GraphQLOutputType)
  case list(GraphQLOutputType)
  
  var namedType: GraphQLOutputType {
    switch self {
    case .nonNull(let innerType), .list(let innerType):
      return innerType.namedType
    case .scalar, .object:
      return self
    }
  }
}

public struct GraphQLBooleanCondition: GraphQLSelection {
  let variableName: String
  let inverted: Bool
  let selections: [GraphQLSelection]
  
  public init(variableName: String, inverted: Bool, selections: [GraphQLSelection]) {
    self.variableName = variableName
    self.inverted = inverted;
    self.selections = selections;
  }
}

public struct GraphQLTypeCondition: GraphQLSelection {
  let possibleTypes: [String]
  let selections: [GraphQLSelection]
  
  public init(possibleTypes: [String], selections: [GraphQLSelection]) {
    self.possibleTypes = possibleTypes
    self.selections = selections;
  }
}

public struct GraphQLFragmentSpread: GraphQLSelection {
  let fragment: GraphQLFragment.Type
  
  public init(_ fragment: GraphQLFragment.Type) {
    self.fragment = fragment
  }
}

public struct GraphQLTypeCase: GraphQLSelection {
  let variants: [String: [GraphQLSelection]]
  let `default`: [GraphQLSelection]
  
  public init(variants: [String: [GraphQLSelection]], default: [GraphQLSelection]) {
    self.variants = variants
    self.default = `default`;
  }
}

public typealias JSONObject = [String: Any]

public protocol JSONDecodable {
  init(jsonValue value: Any) throws
}

public protocol JSONEncodable: GraphQLInputValue {
  var jsonValue: Any { get }
}

public enum JSONDecodingError: Error, LocalizedError {
  case missingValue
  case nullValue
  case wrongType
  case couldNotConvert(value: Any, to: Any.Type)
  
  public var errorDescription: String? {
    switch self {
    case .missingValue:
      return "Missing value"
    case .nullValue:
      return "Unexpected null value"
    case .wrongType:
      return "Wrong type"
    case .couldNotConvert(let value, let expectedType):
      return "Could not convert \"\(value)\" to \(expectedType)"
    }
  }
}

extension String: JSONDecodable, JSONEncodable {
  public init(jsonValue value: Any) throws {
    guard let string = value as? String else {
      throw JSONDecodingError.couldNotConvert(value: value, to: String.self)
    }
    self = string
  }

  public var jsonValue: Any {
    return self
  }
}

extension Int: JSONDecodable, JSONEncodable {
  public init(jsonValue value: Any) throws {
    guard let number = value as? NSNumber else {
      throw JSONDecodingError.couldNotConvert(value: value, to: Int.self)
    }
    self = number.intValue
  }

  public var jsonValue: Any {
    return self
  }
}

extension Float: JSONDecodable, JSONEncodable {
  public init(jsonValue value: Any) throws {
    guard let number = value as? NSNumber else {
      throw JSONDecodingError.couldNotConvert(value: value, to: Float.self)
    }
    self = number.floatValue
  }

  public var jsonValue: Any {
    return self
  }
}

extension Double: JSONDecodable, JSONEncodable {
  public init(jsonValue value: Any) throws {
    guard let number = value as? NSNumber else {
      throw JSONDecodingError.couldNotConvert(value: value, to: Double.self)
    }
    self = number.doubleValue
  }

  public var jsonValue: Any {
    return self
  }
}

extension Bool: JSONDecodable, JSONEncodable {
  public init(jsonValue value: Any) throws {
    guard let bool = value as? Bool else {
        throw JSONDecodingError.couldNotConvert(value: value, to: Bool.self)
    }
    self = bool
  }

  public var jsonValue: Any {
    return self
  }
}

extension RawRepresentable where RawValue: JSONDecodable {
  public init(jsonValue value: Any) throws {
    let rawValue = try RawValue(jsonValue: value)
    if let tempSelf = Self(rawValue: rawValue) {
      self = tempSelf
    } else {
      throw JSONDecodingError.couldNotConvert(value: value, to: Self.self)
    }
  }
}

extension RawRepresentable where RawValue: JSONEncodable {
  public var jsonValue: Any {
    return rawValue.jsonValue
  }
}

extension Optional where Wrapped: JSONDecodable {
  public init(jsonValue value: Any) throws {
    if value is NSNull {
      self = .none
    } else {
      self = .some(try Wrapped(jsonValue: value))
    }
  }
}

extension Optional: JSONEncodable {
  public var jsonValue: Any {
    switch self {
    case .none:
      return NSNull()
    case .some(let wrapped as JSONEncodable):
      return wrapped.jsonValue
    default:
      fatalError("Optional is only JSONEncodable if Wrapped is")
    }
  }
}

extension Dictionary: JSONEncodable {
  public var jsonValue: Any {
    return jsonObject
  }
  
  public var jsonObject: JSONObject {
    var jsonObject = JSONObject(minimumCapacity: count)
    for (key, value) in self {
      if case let (key as String, value as JSONEncodable) = (key, value) {
        jsonObject[key] = value.jsonValue
      } else {
        fatalError("Dictionary is only JSONEncodable if Value is (and if Key is String)")
      }
    }
    return jsonObject
  }
}

extension Array: JSONEncodable {
  public var jsonValue: Any {
    return map() { element -> (Any) in
      if case let element as JSONEncodable = element {
        return element.jsonValue
      } else {
        fatalError("Array is only JSONEncodable if Element is")
      }
    }
  }
}

extension URL: JSONDecodable, JSONEncodable {
  public init(jsonValue value: Any) throws {
    guard let string = value as? String else {
      throw JSONDecodingError.couldNotConvert(value: value, to: URL.self)
    }
    self.init(string: string)!
  }

  public var jsonValue: Any {
    return self.absoluteString
  }
}

extension Dictionary {
  static func += (lhs: inout Dictionary, rhs: Dictionary) {
    lhs.merge(rhs) { (_, new) in new }
  }
}

#elseif canImport(AWSAppSync)
import AWSAppSync
#endif

public struct CreateGlacierUsersInput: GraphQLMapConvertible {
  public var graphQLMap: GraphQLMap

  public init(email: String? = nil, extensionVoiceserver: String? = nil, firstName: String? = nil, lastName: String? = nil, messengerId: String? = nil, organization: String, securityInfo: [String?]? = nil, userName: String? = nil, username: String) {
    graphQLMap = ["email": email, "extension_voiceserver": extensionVoiceserver, "first_name": firstName, "last_name": lastName, "messenger_id": messengerId, "organization": organization, "securityInfo": securityInfo, "user_name": userName, "username": username]
  }

  public var email: String? {
    get {
      return graphQLMap["email"] as! String?
    }
    set {
      graphQLMap.updateValue(newValue, forKey: "email")
    }
  }

  public var extensionVoiceserver: String? {
    get {
      return graphQLMap["extension_voiceserver"] as! String?
    }
    set {
      graphQLMap.updateValue(newValue, forKey: "extension_voiceserver")
    }
  }

  public var firstName: String? {
    get {
      return graphQLMap["first_name"] as! String?
    }
    set {
      graphQLMap.updateValue(newValue, forKey: "first_name")
    }
  }

  public var lastName: String? {
    get {
      return graphQLMap["last_name"] as! String?
    }
    set {
      graphQLMap.updateValue(newValue, forKey: "last_name")
    }
  }

  public var messengerId: String? {
    get {
      return graphQLMap["messenger_id"] as! String?
    }
    set {
      graphQLMap.updateValue(newValue, forKey: "messenger_id")
    }
  }

  public var organization: String {
    get {
      return graphQLMap["organization"] as! String
    }
    set {
      graphQLMap.updateValue(newValue, forKey: "organization")
    }
  }

  public var securityInfo: [String?]? {
    get {
      return graphQLMap["securityInfo"] as! [String?]?
    }
    set {
      graphQLMap.updateValue(newValue, forKey: "securityInfo")
    }
  }

  public var userName: String? {
    get {
      return graphQLMap["user_name"] as! String?
    }
    set {
      graphQLMap.updateValue(newValue, forKey: "user_name")
    }
  }

  public var username: String {
    get {
      return graphQLMap["username"] as! String
    }
    set {
      graphQLMap.updateValue(newValue, forKey: "username")
    }
  }
}

public struct UpdateGlacierUsersInput: GraphQLMapConvertible {
  public var graphQLMap: GraphQLMap

  public init(addUserToPurchaseNumbers: Bool? = nil, email: String? = nil, extensionVoiceserver: String? = nil, firstName: String? = nil, lastName: String? = nil, messengerId: String? = nil, organization: String, securityInfo: [String?]? = nil, selectedTwilionumber: [String?]? = nil, userName: String? = nil, username: String) {
    graphQLMap = ["add_user_to_purchase_numbers": addUserToPurchaseNumbers, "email": email, "extension_voiceserver": extensionVoiceserver, "first_name": firstName, "last_name": lastName, "messenger_id": messengerId, "organization": organization, "securityInfo": securityInfo, "selected_twilionumber": selectedTwilionumber, "user_name": userName, "username": username]
  }

  public var addUserToPurchaseNumbers: Bool? {
    get {
      return graphQLMap["add_user_to_purchase_numbers"] as! Bool?
    }
    set {
      graphQLMap.updateValue(newValue, forKey: "add_user_to_purchase_numbers")
    }
  }

  public var email: String? {
    get {
      return graphQLMap["email"] as! String?
    }
    set {
      graphQLMap.updateValue(newValue, forKey: "email")
    }
  }

  public var extensionVoiceserver: String? {
    get {
      return graphQLMap["extension_voiceserver"] as! String?
    }
    set {
      graphQLMap.updateValue(newValue, forKey: "extension_voiceserver")
    }
  }

  public var firstName: String? {
    get {
      return graphQLMap["first_name"] as! String?
    }
    set {
      graphQLMap.updateValue(newValue, forKey: "first_name")
    }
  }

  public var lastName: String? {
    get {
      return graphQLMap["last_name"] as! String?
    }
    set {
      graphQLMap.updateValue(newValue, forKey: "last_name")
    }
  }

  public var messengerId: String? {
    get {
      return graphQLMap["messenger_id"] as! String?
    }
    set {
      graphQLMap.updateValue(newValue, forKey: "messenger_id")
    }
  }

  public var organization: String {
    get {
      return graphQLMap["organization"] as! String
    }
    set {
      graphQLMap.updateValue(newValue, forKey: "organization")
    }
  }

  public var securityInfo: [String?]? {
    get {
      return graphQLMap["securityInfo"] as! [String?]?
    }
    set {
      graphQLMap.updateValue(newValue, forKey: "securityInfo")
    }
  }

  public var selectedTwilionumber: [String?]? {
    get {
      return graphQLMap["selected_twilionumber"] as! [String?]?
    }
    set {
      graphQLMap.updateValue(newValue, forKey: "selected_twilionumber")
    }
  }

  public var userName: String? {
    get {
      return graphQLMap["user_name"] as! String?
    }
    set {
      graphQLMap.updateValue(newValue, forKey: "user_name")
    }
  }

  public var username: String {
    get {
      return graphQLMap["username"] as! String
    }
    set {
      graphQLMap.updateValue(newValue, forKey: "username")
    }
  }
}

public final class CreateGlacierUsersMutation: GraphQLMutation {
  public static let operationString =
    "mutation CreateGlacierUsers($input: CreateGlacierUsersInput!) {\n  createGlacierUsers(input: $input) {\n    __typename\n    add_to_core_vpn\n    add_user_to_SMS\n    add_user_to_purchase_numbers\n    core_region\n    email\n    extension_voiceserver\n    first_name\n    isSMSEnabled\n    last_name\n    messenger_id\n    organization\n    securityInfo\n    selected_twilionumber\n    user_name\n    username\n  }\n}"

  public var input: CreateGlacierUsersInput

  public init(input: CreateGlacierUsersInput) {
    self.input = input
  }

  public var variables: GraphQLMap? {
    return ["input": input]
  }

  public struct Data: GraphQLSelectionSet {
    public static let possibleTypes = ["Mutation"]

    public static let selections: [GraphQLSelection] = [
      GraphQLField("createGlacierUsers", arguments: ["input": GraphQLVariable("input")], type: .object(CreateGlacierUser.selections)),
    ]

    public var snapshot: Snapshot

    public init(snapshot: Snapshot) {
      self.snapshot = snapshot
    }

    public init(createGlacierUsers: CreateGlacierUser? = nil) {
      self.init(snapshot: ["__typename": "Mutation", "createGlacierUsers": createGlacierUsers.flatMap { $0.snapshot }])
    }

    public var createGlacierUsers: CreateGlacierUser? {
      get {
        return (snapshot["createGlacierUsers"] as? Snapshot).flatMap { CreateGlacierUser(snapshot: $0) }
      }
      set {
        snapshot.updateValue(newValue?.snapshot, forKey: "createGlacierUsers")
      }
    }

    public struct CreateGlacierUser: GraphQLSelectionSet {
      public static let possibleTypes = ["GlacierUsers"]

      public static let selections: [GraphQLSelection] = [
        GraphQLField("__typename", type: .nonNull(.scalar(String.self))),
        GraphQLField("add_to_core_vpn", type: .scalar(Bool.self)),
        GraphQLField("add_user_to_SMS", type: .scalar(Bool.self)),
        GraphQLField("add_user_to_purchase_numbers", type: .scalar(Bool.self)),
        GraphQLField("core_region", type: .list(.scalar(String.self))),
        GraphQLField("email", type: .scalar(String.self)),
        GraphQLField("extension_voiceserver", type: .scalar(String.self)),
        GraphQLField("first_name", type: .scalar(String.self)),
        GraphQLField("isSMSEnabled", type: .scalar(Bool.self)),
        GraphQLField("last_name", type: .scalar(String.self)),
        GraphQLField("messenger_id", type: .scalar(String.self)),
        GraphQLField("organization", type: .nonNull(.scalar(String.self))),
        GraphQLField("securityInfo", type: .list(.scalar(String.self))),
        GraphQLField("selected_twilionumber", type: .list(.scalar(String.self))),
        GraphQLField("user_name", type: .scalar(String.self)),
        GraphQLField("username", type: .nonNull(.scalar(String.self))),
      ]

      public var snapshot: Snapshot

      public init(snapshot: Snapshot) {
        self.snapshot = snapshot
      }

      public init(addToCoreVpn: Bool? = nil, addUserToSms: Bool? = nil, addUserToPurchaseNumbers: Bool? = nil, coreRegion: [String?]? = nil, email: String? = nil, extensionVoiceserver: String? = nil, firstName: String? = nil, isSmsEnabled: Bool? = nil, lastName: String? = nil, messengerId: String? = nil, organization: String, securityInfo: [String?]? = nil, selectedTwilionumber: [String?]? = nil, userName: String? = nil, username: String) {
        self.init(snapshot: ["__typename": "GlacierUsers", "add_to_core_vpn": addToCoreVpn, "add_user_to_SMS": addUserToSms, "add_user_to_purchase_numbers": addUserToPurchaseNumbers, "core_region": coreRegion, "email": email, "extension_voiceserver": extensionVoiceserver, "first_name": firstName, "isSMSEnabled": isSmsEnabled, "last_name": lastName, "messenger_id": messengerId, "organization": organization, "securityInfo": securityInfo, "selected_twilionumber": selectedTwilionumber, "user_name": userName, "username": username])
      }

      public var __typename: String {
        get {
          return snapshot["__typename"]! as! String
        }
        set {
          snapshot.updateValue(newValue, forKey: "__typename")
        }
      }

      public var addToCoreVpn: Bool? {
        get {
          return snapshot["add_to_core_vpn"] as? Bool
        }
        set {
          snapshot.updateValue(newValue, forKey: "add_to_core_vpn")
        }
      }

      public var addUserToSms: Bool? {
        get {
          return snapshot["add_user_to_SMS"] as? Bool
        }
        set {
          snapshot.updateValue(newValue, forKey: "add_user_to_SMS")
        }
      }

      public var addUserToPurchaseNumbers: Bool? {
        get {
          return snapshot["add_user_to_purchase_numbers"] as? Bool
        }
        set {
          snapshot.updateValue(newValue, forKey: "add_user_to_purchase_numbers")
        }
      }

      public var coreRegion: [String?]? {
        get {
          return snapshot["core_region"] as? [String?]
        }
        set {
          snapshot.updateValue(newValue, forKey: "core_region")
        }
      }

      public var email: String? {
        get {
          return snapshot["email"] as? String
        }
        set {
          snapshot.updateValue(newValue, forKey: "email")
        }
      }

      public var extensionVoiceserver: String? {
        get {
          return snapshot["extension_voiceserver"] as? String
        }
        set {
          snapshot.updateValue(newValue, forKey: "extension_voiceserver")
        }
      }

      public var firstName: String? {
        get {
          return snapshot["first_name"] as? String
        }
        set {
          snapshot.updateValue(newValue, forKey: "first_name")
        }
      }

      public var isSmsEnabled: Bool? {
        get {
          return snapshot["isSMSEnabled"] as? Bool
        }
        set {
          snapshot.updateValue(newValue, forKey: "isSMSEnabled")
        }
      }

      public var lastName: String? {
        get {
          return snapshot["last_name"] as? String
        }
        set {
          snapshot.updateValue(newValue, forKey: "last_name")
        }
      }

      public var messengerId: String? {
        get {
          return snapshot["messenger_id"] as? String
        }
        set {
          snapshot.updateValue(newValue, forKey: "messenger_id")
        }
      }

      public var organization: String {
        get {
          return snapshot["organization"]! as! String
        }
        set {
          snapshot.updateValue(newValue, forKey: "organization")
        }
      }

      public var securityInfo: [String?]? {
        get {
          return snapshot["securityInfo"] as? [String?]
        }
        set {
          snapshot.updateValue(newValue, forKey: "securityInfo")
        }
      }

      public var selectedTwilionumber: [String?]? {
        get {
          return snapshot["selected_twilionumber"] as? [String?]
        }
        set {
          snapshot.updateValue(newValue, forKey: "selected_twilionumber")
        }
      }

      public var userName: String? {
        get {
          return snapshot["user_name"] as? String
        }
        set {
          snapshot.updateValue(newValue, forKey: "user_name")
        }
      }

      public var username: String {
        get {
          return snapshot["username"]! as! String
        }
        set {
          snapshot.updateValue(newValue, forKey: "username")
        }
      }
    }
  }
}

public final class UpdateGlacierUsersMutation: GraphQLMutation {
  public static let operationString =
    "mutation UpdateGlacierUsers($input: UpdateGlacierUsersInput!) {\n  updateGlacierUsers(input: $input) {\n    __typename\n    add_to_core_vpn\n    add_user_to_SMS\n    add_user_to_purchase_numbers\n    core_region\n    email\n    extension_voiceserver\n    first_name\n    isSMSEnabled\n    last_name\n    messenger_id\n    organization\n    securityInfo\n    selected_twilionumber\n    user_name\n    username\n  }\n}"

  public var input: UpdateGlacierUsersInput

  public init(input: UpdateGlacierUsersInput) {
    self.input = input
  }

  public var variables: GraphQLMap? {
    return ["input": input]
  }

  public struct Data: GraphQLSelectionSet {
    public static let possibleTypes = ["Mutation"]

    public static let selections: [GraphQLSelection] = [
      GraphQLField("updateGlacierUsers", arguments: ["input": GraphQLVariable("input")], type: .object(UpdateGlacierUser.selections)),
    ]

    public var snapshot: Snapshot

    public init(snapshot: Snapshot) {
      self.snapshot = snapshot
    }

    public init(updateGlacierUsers: UpdateGlacierUser? = nil) {
      self.init(snapshot: ["__typename": "Mutation", "updateGlacierUsers": updateGlacierUsers.flatMap { $0.snapshot }])
    }

    public var updateGlacierUsers: UpdateGlacierUser? {
      get {
        return (snapshot["updateGlacierUsers"] as? Snapshot).flatMap { UpdateGlacierUser(snapshot: $0) }
      }
      set {
        snapshot.updateValue(newValue?.snapshot, forKey: "updateGlacierUsers")
      }
    }

    public struct UpdateGlacierUser: GraphQLSelectionSet {
      public static let possibleTypes = ["GlacierUsers"]

      public static let selections: [GraphQLSelection] = [
        GraphQLField("__typename", type: .nonNull(.scalar(String.self))),
        GraphQLField("add_to_core_vpn", type: .scalar(Bool.self)),
        GraphQLField("add_user_to_SMS", type: .scalar(Bool.self)),
        GraphQLField("add_user_to_purchase_numbers", type: .scalar(Bool.self)),
        GraphQLField("core_region", type: .list(.scalar(String.self))),
        GraphQLField("email", type: .scalar(String.self)),
        GraphQLField("extension_voiceserver", type: .scalar(String.self)),
        GraphQLField("first_name", type: .scalar(String.self)),
        GraphQLField("isSMSEnabled", type: .scalar(Bool.self)),
        GraphQLField("last_name", type: .scalar(String.self)),
        GraphQLField("messenger_id", type: .scalar(String.self)),
        GraphQLField("organization", type: .nonNull(.scalar(String.self))),
        GraphQLField("securityInfo", type: .list(.scalar(String.self))),
        GraphQLField("selected_twilionumber", type: .list(.scalar(String.self))),
        GraphQLField("user_name", type: .scalar(String.self)),
        GraphQLField("username", type: .nonNull(.scalar(String.self))),
      ]

      public var snapshot: Snapshot

      public init(snapshot: Snapshot) {
        self.snapshot = snapshot
      }

      public init(addToCoreVpn: Bool? = nil, addUserToSms: Bool? = nil, addUserToPurchaseNumbers: Bool? = nil, coreRegion: [String?]? = nil, email: String? = nil, extensionVoiceserver: String? = nil, firstName: String? = nil, isSmsEnabled: Bool? = nil, lastName: String? = nil, messengerId: String? = nil, organization: String, securityInfo: [String?]? = nil, selectedTwilionumber: [String?]? = nil, userName: String? = nil, username: String) {
        self.init(snapshot: ["__typename": "GlacierUsers", "add_to_core_vpn": addToCoreVpn, "add_user_to_SMS": addUserToSms, "add_user_to_purchase_numbers": addUserToPurchaseNumbers, "core_region": coreRegion, "email": email, "extension_voiceserver": extensionVoiceserver, "first_name": firstName, "isSMSEnabled": isSmsEnabled, "last_name": lastName, "messenger_id": messengerId, "organization": organization, "securityInfo": securityInfo, "selected_twilionumber": selectedTwilionumber, "user_name": userName, "username": username])
      }

      public var __typename: String {
        get {
          return snapshot["__typename"]! as! String
        }
        set {
          snapshot.updateValue(newValue, forKey: "__typename")
        }
      }

      public var addToCoreVpn: Bool? {
        get {
          return snapshot["add_to_core_vpn"] as? Bool
        }
        set {
          snapshot.updateValue(newValue, forKey: "add_to_core_vpn")
        }
      }

      public var addUserToSms: Bool? {
        get {
          return snapshot["add_user_to_SMS"] as? Bool
        }
        set {
          snapshot.updateValue(newValue, forKey: "add_user_to_SMS")
        }
      }

      public var addUserToPurchaseNumbers: Bool? {
        get {
          return snapshot["add_user_to_purchase_numbers"] as? Bool
        }
        set {
          snapshot.updateValue(newValue, forKey: "add_user_to_purchase_numbers")
        }
      }

      public var coreRegion: [String?]? {
        get {
          return snapshot["core_region"] as? [String?]
        }
        set {
          snapshot.updateValue(newValue, forKey: "core_region")
        }
      }

      public var email: String? {
        get {
          return snapshot["email"] as? String
        }
        set {
          snapshot.updateValue(newValue, forKey: "email")
        }
      }

      public var extensionVoiceserver: String? {
        get {
          return snapshot["extension_voiceserver"] as? String
        }
        set {
          snapshot.updateValue(newValue, forKey: "extension_voiceserver")
        }
      }

      public var firstName: String? {
        get {
          return snapshot["first_name"] as? String
        }
        set {
          snapshot.updateValue(newValue, forKey: "first_name")
        }
      }

      public var isSmsEnabled: Bool? {
        get {
          return snapshot["isSMSEnabled"] as? Bool
        }
        set {
          snapshot.updateValue(newValue, forKey: "isSMSEnabled")
        }
      }

      public var lastName: String? {
        get {
          return snapshot["last_name"] as? String
        }
        set {
          snapshot.updateValue(newValue, forKey: "last_name")
        }
      }

      public var messengerId: String? {
        get {
          return snapshot["messenger_id"] as? String
        }
        set {
          snapshot.updateValue(newValue, forKey: "messenger_id")
        }
      }

      public var organization: String {
        get {
          return snapshot["organization"]! as! String
        }
        set {
          snapshot.updateValue(newValue, forKey: "organization")
        }
      }

      public var securityInfo: [String?]? {
        get {
          return snapshot["securityInfo"] as? [String?]
        }
        set {
          snapshot.updateValue(newValue, forKey: "securityInfo")
        }
      }

      public var selectedTwilionumber: [String?]? {
        get {
          return snapshot["selected_twilionumber"] as? [String?]
        }
        set {
          snapshot.updateValue(newValue, forKey: "selected_twilionumber")
        }
      }

      public var userName: String? {
        get {
          return snapshot["user_name"] as? String
        }
        set {
          snapshot.updateValue(newValue, forKey: "user_name")
        }
      }

      public var username: String {
        get {
          return snapshot["username"]! as! String
        }
        set {
          snapshot.updateValue(newValue, forKey: "username")
        }
      }
    }
  }
}

public final class GetGlacierOrganizationQuery: GraphQLQuery {
  public static let operationString =
    "query GetGlacierOrganization($organization: String!) {\n  getGlacierOrganization(organization: $organization) {\n    __typename\n    api_key\n    dns_enabled\n    organization\n    remote_backup_enabled\n    securityhub_data_enabled\n    sms_enabled\n    upload_enabled\n    voicemail_enabled\n    force_tracking\n    tracking_enabled\n    tracking_frequency\n  }\n}"

  public var organization: String

  public init(organization: String) {
    self.organization = organization
  }

  public var variables: GraphQLMap? {
    return ["organization": organization]
  }

  public struct Data: GraphQLSelectionSet {
    public static let possibleTypes = ["Query"]

    public static let selections: [GraphQLSelection] = [
      GraphQLField("getGlacierOrganization", arguments: ["organization": GraphQLVariable("organization")], type: .object(GetGlacierOrganization.selections)),
    ]

    public var snapshot: Snapshot

    public init(snapshot: Snapshot) {
      self.snapshot = snapshot
    }

    public init(getGlacierOrganization: GetGlacierOrganization? = nil) {
      self.init(snapshot: ["__typename": "Query", "getGlacierOrganization": getGlacierOrganization.flatMap { $0.snapshot }])
    }

    public var getGlacierOrganization: GetGlacierOrganization? {
      get {
        return (snapshot["getGlacierOrganization"] as? Snapshot).flatMap { GetGlacierOrganization(snapshot: $0) }
      }
      set {
        snapshot.updateValue(newValue?.snapshot, forKey: "getGlacierOrganization")
      }
    }

    public struct GetGlacierOrganization: GraphQLSelectionSet {
      public static let possibleTypes = ["GlacierOrganization"]

      public static let selections: [GraphQLSelection] = [
        GraphQLField("__typename", type: .nonNull(.scalar(String.self))),
        GraphQLField("api_key", type: .nonNull(.scalar(String.self))),
        GraphQLField("dns_enabled", type: .scalar(Bool.self)),
        GraphQLField("organization", type: .nonNull(.scalar(String.self))),
        GraphQLField("remote_backup_enabled", type: .scalar(Bool.self)),
        GraphQLField("securityhub_data_enabled", type: .scalar(Bool.self)),
        GraphQLField("sms_enabled", type: .scalar(Bool.self)),
        GraphQLField("upload_enabled", type: .scalar(Bool.self)),
        GraphQLField("voicemail_enabled", type: .scalar(Bool.self)),
        GraphQLField("force_tracking", type: .scalar(Bool.self)),
        GraphQLField("tracking_enabled", type: .scalar(Bool.self)),
        GraphQLField("tracking_frequency", type: .scalar(String.self)),
      ]

      public var snapshot: Snapshot

      public init(snapshot: Snapshot) {
        self.snapshot = snapshot
      }

      public init(apiKey: String, dnsEnabled: Bool? = nil, organization: String, remoteBackupEnabled: Bool? = nil, securityhubDataEnabled: Bool? = nil, smsEnabled: Bool? = nil, uploadEnabled: Bool? = nil, voicemailEnabled: Bool? = nil, forceTracking: Bool? = nil, trackingEnabled: Bool? = nil, trackingFrequency: String? = nil) {
        self.init(snapshot: ["__typename": "GlacierOrganization", "api_key": apiKey, "dns_enabled": dnsEnabled, "organization": organization, "remote_backup_enabled": remoteBackupEnabled, "securityhub_data_enabled": securityhubDataEnabled, "sms_enabled": smsEnabled, "upload_enabled": uploadEnabled, "voicemail_enabled": voicemailEnabled, "force_tracking": forceTracking, "tracking_enabled": trackingEnabled, "tracking_frequency": trackingFrequency])
      }

      public var __typename: String {
        get {
          return snapshot["__typename"]! as! String
        }
        set {
          snapshot.updateValue(newValue, forKey: "__typename")
        }
      }

      public var apiKey: String {
        get {
          return snapshot["api_key"]! as! String
        }
        set {
          snapshot.updateValue(newValue, forKey: "api_key")
        }
      }

      public var dnsEnabled: Bool? {
        get {
          return snapshot["dns_enabled"] as? Bool
        }
        set {
          snapshot.updateValue(newValue, forKey: "dns_enabled")
        }
      }

      public var organization: String {
        get {
          return snapshot["organization"]! as! String
        }
        set {
          snapshot.updateValue(newValue, forKey: "organization")
        }
      }

      public var remoteBackupEnabled: Bool? {
        get {
          return snapshot["remote_backup_enabled"] as? Bool
        }
        set {
          snapshot.updateValue(newValue, forKey: "remote_backup_enabled")
        }
      }

      public var securityhubDataEnabled: Bool? {
        get {
          return snapshot["securityhub_data_enabled"] as? Bool
        }
        set {
          snapshot.updateValue(newValue, forKey: "securityhub_data_enabled")
        }
      }

      public var smsEnabled: Bool? {
        get {
          return snapshot["sms_enabled"] as? Bool
        }
        set {
          snapshot.updateValue(newValue, forKey: "sms_enabled")
        }
      }

      public var uploadEnabled: Bool? {
        get {
          return snapshot["upload_enabled"] as? Bool
        }
        set {
          snapshot.updateValue(newValue, forKey: "upload_enabled")
        }
      }

      public var voicemailEnabled: Bool? {
        get {
          return snapshot["voicemail_enabled"] as? Bool
        }
        set {
          snapshot.updateValue(newValue, forKey: "voicemail_enabled")
        }
      }

      public var forceTracking: Bool? {
        get {
          return snapshot["force_tracking"] as? Bool
        }
        set {
          snapshot.updateValue(newValue, forKey: "force_tracking")
        }
      }

      public var trackingEnabled: Bool? {
        get {
          return snapshot["tracking_enabled"] as? Bool
        }
        set {
          snapshot.updateValue(newValue, forKey: "tracking_enabled")
        }
      }

      public var trackingFrequency: String? {
        get {
          return snapshot["tracking_frequency"] as? String
        }
        set {
          snapshot.updateValue(newValue, forKey: "tracking_frequency")
        }
      }
    }
  }
}

public final class GetGlacierUsersQuery: GraphQLQuery {
  public static let operationString =
    "query GetGlacierUsers($organization: String!, $username: String!) {\n  getGlacierUsers(organization: $organization, username: $username) {\n    __typename\n    add_to_core_vpn\n    add_user_to_SMS\n    add_user_to_purchase_numbers\n    core_region\n    email\n    extension_voiceserver\n    first_name\n    isSMSEnabled\n    last_name\n    messenger_id\n    organization\n    securityInfo\n    selected_twilionumber\n    user_name\n    username\n  }\n}"

  public var organization: String
  public var username: String

  public init(organization: String, username: String) {
    self.organization = organization
    self.username = username
  }

  public var variables: GraphQLMap? {
    return ["organization": organization, "username": username]
  }

  public struct Data: GraphQLSelectionSet {
    public static let possibleTypes = ["Query"]

    public static let selections: [GraphQLSelection] = [
      GraphQLField("getGlacierUsers", arguments: ["organization": GraphQLVariable("organization"), "username": GraphQLVariable("username")], type: .object(GetGlacierUser.selections)),
    ]

    public var snapshot: Snapshot

    public init(snapshot: Snapshot) {
      self.snapshot = snapshot
    }

    public init(getGlacierUsers: GetGlacierUser? = nil) {
      self.init(snapshot: ["__typename": "Query", "getGlacierUsers": getGlacierUsers.flatMap { $0.snapshot }])
    }

    public var getGlacierUsers: GetGlacierUser? {
      get {
        return (snapshot["getGlacierUsers"] as? Snapshot).flatMap { GetGlacierUser(snapshot: $0) }
      }
      set {
        snapshot.updateValue(newValue?.snapshot, forKey: "getGlacierUsers")
      }
    }

    public struct GetGlacierUser: GraphQLSelectionSet {
      public static let possibleTypes = ["GlacierUsers"]

      public static let selections: [GraphQLSelection] = [
        GraphQLField("__typename", type: .nonNull(.scalar(String.self))),
        GraphQLField("add_to_core_vpn", type: .scalar(Bool.self)),
        GraphQLField("add_user_to_SMS", type: .scalar(Bool.self)),
        GraphQLField("add_user_to_purchase_numbers", type: .scalar(Bool.self)),
        GraphQLField("core_region", type: .list(.scalar(String.self))),
        GraphQLField("email", type: .scalar(String.self)),
        GraphQLField("extension_voiceserver", type: .scalar(String.self)),
        GraphQLField("first_name", type: .scalar(String.self)),
        GraphQLField("isSMSEnabled", type: .scalar(Bool.self)),
        GraphQLField("last_name", type: .scalar(String.self)),
        GraphQLField("messenger_id", type: .scalar(String.self)),
        GraphQLField("organization", type: .nonNull(.scalar(String.self))),
        GraphQLField("securityInfo", type: .list(.scalar(String.self))),
        GraphQLField("selected_twilionumber", type: .list(.scalar(String.self))),
        GraphQLField("user_name", type: .scalar(String.self)),
        GraphQLField("username", type: .nonNull(.scalar(String.self))),
      ]

      public var snapshot: Snapshot

      public init(snapshot: Snapshot) {
        self.snapshot = snapshot
      }

      public init(addToCoreVpn: Bool? = nil, addUserToSms: Bool? = nil, addUserToPurchaseNumbers: Bool? = nil, coreRegion: [String?]? = nil, email: String? = nil, extensionVoiceserver: String? = nil, firstName: String? = nil, isSmsEnabled: Bool? = nil, lastName: String? = nil, messengerId: String? = nil, organization: String, securityInfo: [String?]? = nil, selectedTwilionumber: [String?]? = nil, userName: String? = nil, username: String) {
        self.init(snapshot: ["__typename": "GlacierUsers", "add_to_core_vpn": addToCoreVpn, "add_user_to_SMS": addUserToSms, "add_user_to_purchase_numbers": addUserToPurchaseNumbers, "core_region": coreRegion, "email": email, "extension_voiceserver": extensionVoiceserver, "first_name": firstName, "isSMSEnabled": isSmsEnabled, "last_name": lastName, "messenger_id": messengerId, "organization": organization, "securityInfo": securityInfo, "selected_twilionumber": selectedTwilionumber, "user_name": userName, "username": username])
      }

      public var __typename: String {
        get {
          return snapshot["__typename"]! as! String
        }
        set {
          snapshot.updateValue(newValue, forKey: "__typename")
        }
      }

      public var addToCoreVpn: Bool? {
        get {
          return snapshot["add_to_core_vpn"] as? Bool
        }
        set {
          snapshot.updateValue(newValue, forKey: "add_to_core_vpn")
        }
      }

      public var addUserToSms: Bool? {
        get {
          return snapshot["add_user_to_SMS"] as? Bool
        }
        set {
          snapshot.updateValue(newValue, forKey: "add_user_to_SMS")
        }
      }

      public var addUserToPurchaseNumbers: Bool? {
        get {
          return snapshot["add_user_to_purchase_numbers"] as? Bool
        }
        set {
          snapshot.updateValue(newValue, forKey: "add_user_to_purchase_numbers")
        }
      }

      public var coreRegion: [String?]? {
        get {
          return snapshot["core_region"] as? [String?]
        }
        set {
          snapshot.updateValue(newValue, forKey: "core_region")
        }
      }

      public var email: String? {
        get {
          return snapshot["email"] as? String
        }
        set {
          snapshot.updateValue(newValue, forKey: "email")
        }
      }

      public var extensionVoiceserver: String? {
        get {
          return snapshot["extension_voiceserver"] as? String
        }
        set {
          snapshot.updateValue(newValue, forKey: "extension_voiceserver")
        }
      }

      public var firstName: String? {
        get {
          return snapshot["first_name"] as? String
        }
        set {
          snapshot.updateValue(newValue, forKey: "first_name")
        }
      }

      public var isSmsEnabled: Bool? {
        get {
          return snapshot["isSMSEnabled"] as? Bool
        }
        set {
          snapshot.updateValue(newValue, forKey: "isSMSEnabled")
        }
      }

      public var lastName: String? {
        get {
          return snapshot["last_name"] as? String
        }
        set {
          snapshot.updateValue(newValue, forKey: "last_name")
        }
      }

      public var messengerId: String? {
        get {
          return snapshot["messenger_id"] as? String
        }
        set {
          snapshot.updateValue(newValue, forKey: "messenger_id")
        }
      }

      public var organization: String {
        get {
          return snapshot["organization"]! as! String
        }
        set {
          snapshot.updateValue(newValue, forKey: "organization")
        }
      }

      public var securityInfo: [String?]? {
        get {
          return snapshot["securityInfo"] as? [String?]
        }
        set {
          snapshot.updateValue(newValue, forKey: "securityInfo")
        }
      }

      public var selectedTwilionumber: [String?]? {
        get {
          return snapshot["selected_twilionumber"] as? [String?]
        }
        set {
          snapshot.updateValue(newValue, forKey: "selected_twilionumber")
        }
      }

      public var userName: String? {
        get {
          return snapshot["user_name"] as? String
        }
        set {
          snapshot.updateValue(newValue, forKey: "user_name")
        }
      }

      public var username: String {
        get {
          return snapshot["username"]! as! String
        }
        set {
          snapshot.updateValue(newValue, forKey: "username")
        }
      }
    }
  }
}

public final class GetLatestVersionQuery: GraphQLQuery {
  public static let operationString =
    "query GetLatestVersion($key: String!) {\n  getLatestVersion(key: $key) {\n    __typename\n    alt_os\n    alt_os_new\n    android_os\n    glacier\n    glacier_android\n    ios\n  }\n}"

  public var key: String

  public init(key: String) {
    self.key = key
  }

  public var variables: GraphQLMap? {
    return ["key": key]
  }

  public struct Data: GraphQLSelectionSet {
    public static let possibleTypes = ["Query"]

    public static let selections: [GraphQLSelection] = [
      GraphQLField("getLatestVersion", arguments: ["key": GraphQLVariable("key")], type: .object(GetLatestVersion.selections)),
    ]

    public var snapshot: Snapshot

    public init(snapshot: Snapshot) {
      self.snapshot = snapshot
    }

    public init(getLatestVersion: GetLatestVersion? = nil) {
      self.init(snapshot: ["__typename": "Query", "getLatestVersion": getLatestVersion.flatMap { $0.snapshot }])
    }

    public var getLatestVersion: GetLatestVersion? {
      get {
        return (snapshot["getLatestVersion"] as? Snapshot).flatMap { GetLatestVersion(snapshot: $0) }
      }
      set {
        snapshot.updateValue(newValue?.snapshot, forKey: "getLatestVersion")
      }
    }

    public struct GetLatestVersion: GraphQLSelectionSet {
      public static let possibleTypes = ["LatestVersion"]

      public static let selections: [GraphQLSelection] = [
        GraphQLField("__typename", type: .nonNull(.scalar(String.self))),
        GraphQLField("alt_os", type: .nonNull(.scalar(String.self))),
        GraphQLField("alt_os_new", type: .nonNull(.scalar(String.self))),
        GraphQLField("android_os", type: .nonNull(.scalar(String.self))),
        GraphQLField("glacier", type: .nonNull(.scalar(String.self))),
        GraphQLField("glacier_android", type: .nonNull(.scalar(String.self))),
        GraphQLField("ios", type: .nonNull(.scalar(String.self))),
      ]

      public var snapshot: Snapshot

      public init(snapshot: Snapshot) {
        self.snapshot = snapshot
      }

      public init(altOs: String, altOsNew: String, androidOs: String, glacier: String, glacierAndroid: String, ios: String) {
        self.init(snapshot: ["__typename": "LatestVersion", "alt_os": altOs, "alt_os_new": altOsNew, "android_os": androidOs, "glacier": glacier, "glacier_android": glacierAndroid, "ios": ios])
      }

      public var __typename: String {
        get {
          return snapshot["__typename"]! as! String
        }
        set {
          snapshot.updateValue(newValue, forKey: "__typename")
        }
      }

      public var altOs: String {
        get {
          return snapshot["alt_os"]! as! String
        }
        set {
          snapshot.updateValue(newValue, forKey: "alt_os")
        }
      }

      public var altOsNew: String {
        get {
          return snapshot["alt_os_new"]! as! String
        }
        set {
          snapshot.updateValue(newValue, forKey: "alt_os_new")
        }
      }

      public var androidOs: String {
        get {
          return snapshot["android_os"]! as! String
        }
        set {
          snapshot.updateValue(newValue, forKey: "android_os")
        }
      }

      public var glacier: String {
        get {
          return snapshot["glacier"]! as! String
        }
        set {
          snapshot.updateValue(newValue, forKey: "glacier")
        }
      }

      public var glacierAndroid: String {
        get {
          return snapshot["glacier_android"]! as! String
        }
        set {
          snapshot.updateValue(newValue, forKey: "glacier_android")
        }
      }

      public var ios: String {
        get {
          return snapshot["ios"]! as! String
        }
        set {
          snapshot.updateValue(newValue, forKey: "ios")
        }
      }
    }
  }
}
