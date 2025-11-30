import Foundation

@objcMembers
public class DeviceMeta: NSObject, Codable {

    public var cpuType: String?
    public var product: String?
    public var androidVersion: String?
    public var iOSVersion: String?
    public var storageAvailable: String?
    public var storageTotal: String?
    public var model: String?
    public var screenResolution: String?
    public var brand: String?
    public var totalRAM: String?

    public override init() {
        super.init()
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cpuType          = try c.decodeIfPresent(String.self, forKey: .cpuType)
        product          = try c.decodeIfPresent(String.self, forKey: .product)
        androidVersion   = try c.decodeIfPresent(String.self, forKey: .androidVersion)
        iOSVersion       = try c.decodeIfPresent(String.self, forKey: .iOSVersion)
        storageAvailable = try c.decodeIfPresent(String.self, forKey: .storageAvailable)
        storageTotal     = try c.decodeIfPresent(String.self, forKey: .storageTotal)
        model            = try c.decodeIfPresent(String.self, forKey: .model)
        screenResolution = try c.decodeIfPresent(String.self, forKey: .screenResolution)
        brand            = try c.decodeIfPresent(String.self, forKey: .brand)
        totalRAM         = try c.decodeIfPresent(String.self, forKey: .totalRAM)
        super.init()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(cpuType,          forKey: .cpuType)
        try c.encodeIfPresent(product,          forKey: .product)
        try c.encodeIfPresent(androidVersion,   forKey: .androidVersion)
        try c.encodeIfPresent(iOSVersion,       forKey: .iOSVersion)
        try c.encodeIfPresent(storageAvailable, forKey: .storageAvailable)
        try c.encodeIfPresent(storageTotal,     forKey: .storageTotal)
        try c.encodeIfPresent(model,            forKey: .model)
        try c.encodeIfPresent(screenResolution, forKey: .screenResolution)
        try c.encodeIfPresent(brand,            forKey: .brand)
        try c.encodeIfPresent(totalRAM,         forKey: .totalRAM)
    }

    private enum CodingKeys: String, CodingKey {
        case cpuType
        case product
        case androidVersion
        case iOSVersion
        case storageAvailable
        case storageTotal
        case model
        case screenResolution
        case brand
        case totalRAM
    }

    override public var description: String {
        return """
        DeviceMeta(
            cpuType: \(cpuType ?? "nil"),
            product: \(product ?? "nil"),
            androidVersion: \(androidVersion ?? "nil"),
            iOSVersion: \(iOSVersion ?? "nil"),
            storageAvailable: \(storageAvailable ?? "nil"),
            storageTotal: \(storageTotal ?? "nil"),
            model: \(model ?? "nil"),
            screenResolution: \(screenResolution ?? "nil"),
            brand: \(brand ?? "nil"),
            totalRAM: \(totalRAM ?? "nil")
        )
        """
    }
}

@objcMembers
public class IPDetails: NSObject, Codable {

    public var asn: String?
    public var city: String?
    public var country: String?
    public var isp: String?
    public var region: String?

    // Use Double? instead of NSNumber? for Codable
    public var fraudScore: Double?
    public var latitude: Double?
    public var longitude: Double?

    public override init() {
        super.init()
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        asn        = try c.decodeIfPresent(String.self, forKey: .asn)
        city       = try c.decodeIfPresent(String.self, forKey: .city)
        country    = try c.decodeIfPresent(String.self, forKey: .country)
        isp        = try c.decodeIfPresent(String.self, forKey: .isp)
        region     = try c.decodeIfPresent(String.self, forKey: .region)
        fraudScore = try c.decodeIfPresent(Double.self, forKey: .fraudScore)
        latitude   = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude  = try c.decodeIfPresent(Double.self, forKey: .longitude)
        super.init()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(asn,        forKey: .asn)
        try c.encodeIfPresent(city,       forKey: .city)
        try c.encodeIfPresent(country,    forKey: .country)
        try c.encodeIfPresent(isp,        forKey: .isp)
        try c.encodeIfPresent(region,     forKey: .region)
        try c.encodeIfPresent(fraudScore, forKey: .fraudScore)
        try c.encodeIfPresent(latitude,   forKey: .latitude)
        try c.encodeIfPresent(longitude,  forKey: .longitude)
    }

    private enum CodingKeys: String, CodingKey {
        case asn
        case city
        case country
        case isp
        case region
        case fraudScore
        case latitude
        case longitude
    }

    override public var description: String {
        return """
        IPDetails(
            asn: \(asn ?? "nil"),
            city: \(city ?? "nil"),
            country: \(country ?? "nil"),
            isp: \(isp ?? "nil"),
            region: \(region ?? "nil"),
            fraudScore: \(fraudScore?.description ?? "nil"),
            latitude: \(latitude?.description ?? "nil"),
            longitude: \(longitude?.description ?? "nil")
        )
        """
    }
}

@objcMembers
public class GPSLocation: NSObject, Codable {

    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?

    public override init() {
        super.init()
    }

    public init(latitude: Double, longitude: Double, altitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        super.init()
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        latitude  = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        altitude  = try c.decodeIfPresent(Double.self, forKey: .altitude)
        super.init()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(latitude,  forKey: .latitude)
        try c.encodeIfPresent(longitude, forKey: .longitude)
        try c.encodeIfPresent(altitude,  forKey: .altitude)
    }

    private enum CodingKeys: String, CodingKey {
        case latitude
        case longitude
        case altitude
    }

    override public var description: String {
        return """
        GPSLocation(
            latitude: \(latitude?.description ?? "nil"),
            longitude: \(longitude?.description ?? "nil"),
            altitude: \(altitude?.description ?? "nil")
        )
        """
    }
}



@objcMembers
public class IntelligenceInfoData: NSObject {
    public let requestId: String
    public let deviceId: String
    public let ip: String

    public let simulator: Bool
    public let jailbroken: Bool
    public let vpn: Bool
    public let geoSpoofed: Bool
    public let appTampering: Bool
    public let hooking: Bool
    public let proxy: Bool
    public let mirroredScreen: Bool
    public let cloned: Bool
    public let newDevice: Bool
    public let factoryReset: Bool

    public let factoryResetTime: Int
    public let sdkTsid: String

    // New DTO fields (same as OTPlessIntelligenceResponse)
    public let gpsLocation: GPSLocation?
    public let ipDetails: IPDetails?
    public let deviceMeta: DeviceMeta?

    public init(
        requestId: String,
        deviceId: String,
        ip: String,
        simulator: Bool,
        jailbroken: Bool,
        vpn: Bool,
        geoSpoofed: Bool,
        appTampering: Bool,
        hooking: Bool,
        proxy: Bool,
        mirroredScreen: Bool,
        cloned: Bool,
        newDevice: Bool,
        factoryReset: Bool,
        factoryResetTime: Int,
        sdkTsid: String,
        gpsLocation: GPSLocation?,
        ipDetails: IPDetails?,
        deviceMeta: DeviceMeta?
    ) {
        self.requestId = requestId
        self.deviceId = deviceId
        self.ip = ip
        self.simulator = simulator
        self.jailbroken = jailbroken
        self.vpn = vpn
        self.geoSpoofed = geoSpoofed
        self.appTampering = appTampering
        self.hooking = hooking
        self.proxy = proxy
        self.mirroredScreen = mirroredScreen
        self.cloned = cloned
        self.newDevice = newDevice
        self.factoryReset = factoryReset
        self.factoryResetTime = factoryResetTime
        self.sdkTsid = sdkTsid
        self.gpsLocation = gpsLocation
        self.ipDetails = ipDetails
        self.deviceMeta = deviceMeta
        super.init()
    }
    
    override public var description: String {
        return """
        IntelligenceInfoData(
            requestId: \(requestId),
            deviceId: \(deviceId),
            ip: \(ip),
            simulator: \(simulator),
            jailbroken: \(jailbroken),
            vpn: \(vpn),
            geoSpoofed: \(geoSpoofed),
            appTampering: \(appTampering),
            hooking: \(hooking),
            proxy: \(proxy),
            mirroredScreen: \(mirroredScreen),
            cloned: \(cloned),
            newDevice: \(newDevice),
            factoryReset: \(factoryReset),
            factoryResetTime: \(factoryResetTime),
            sdkTsid: \(sdkTsid),
            gpsLocation: \(String(describing: gpsLocation?.description)),
            ipDetails: \(String(describing: ipDetails?.description)),
            deviceMeta: \(String(describing: deviceMeta?.description))
        )
        """
    }
}
