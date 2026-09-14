public protocol TopologyEngine { static func validate(_ topology: PhysicalTopology) throws }
public protocol PathTraceService { static func trace(from startPortID: ObjectID, in topology: PhysicalTopology) throws -> [PhysicalPath] }
public protocol IPAMValidationService { static func validate(prefixes: [Prefix], addresses: [IPAddressRecord], vlans: [VLAN]) throws }
