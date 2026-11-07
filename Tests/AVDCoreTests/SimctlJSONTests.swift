import XCTest
@testable import AVDCore

/// 用本机真实 `xcrun simctl list -j` 输出（macOS 26.6 / Xcode 27.0 实测）裁剪成的静态
/// fixture 验证容错解码：缺字段不崩、未知 state 原样保留、非 iOS runtime 跳过。
final class SimctlJSONTests: XCTestCase {
    /// 字段名、字段顺序与取值格式均取自真实输出；另含 unavailable 设备、
    /// 未知 state、缺字段设备与 watchOS 分组。
    static let devicesJSON = """
    {
      "devices" : {
        "com.apple.CoreSimulator.SimRuntime.iOS-18-6" : [
          {
            "dataPath" : "\\/Users\\/demo\\/Library\\/Developer\\/CoreSimulator\\/Devices\\/DB0DBFF2-7BE8-45EA-A530-07E0ABF2E06B\\/data",
            "dataPathSize" : 3391455232,
            "logPath" : "\\/Users\\/demo\\/Library\\/Logs\\/CoreSimulator\\/DB0DBFF2-7BE8-45EA-A530-07E0ABF2E06B",
            "udid" : "DB0DBFF2-7BE8-45EA-A530-07E0ABF2E06B",
            "lastUsedAt" : "2026-10-26T23:11:03Z",
            "isAvailable" : true,
            "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-16",
            "state" : "Shutdown",
            "name" : "iPhone 16"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0" : [
          {
            "dataPath" : "\\/Users\\/demo\\/Library\\/Developer\\/CoreSimulator\\/Devices\\/D0780F59-BA2D-4279-96AD-B5FC3F73642D\\/data",
            "dataPathSize" : 6335754240,
            "logPath" : "\\/Users\\/demo\\/Library\\/Logs\\/CoreSimulator\\/D0780F59-BA2D-4279-96AD-B5FC3F73642D",
            "udid" : "D0780F59-BA2D-4279-96AD-B5FC3F73642D",
            "lastUsedAt" : "2026-11-06T10:35:09Z",
            "isAvailable" : true,
            "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            "state" : "Booted",
            "name" : "iPhone 17 Pro"
          },
          {
            "dataPath" : "\\/Users\\/demo\\/Library\\/Developer\\/CoreSimulator\\/Devices\\/17E30C5F-5F09-4A68-910A-C0FC4205B2F5\\/data",
            "dataPathSize" : 18337792,
            "logPath" : "\\/Users\\/demo\\/Library\\/Logs\\/CoreSimulator\\/17E30C5F-5F09-4A68-910A-C0FC4205B2F5",
            "udid" : "17E30C5F-5F09-4A68-910A-C0FC4205B2F5",
            "isAvailable" : false,
            "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max",
            "state" : "ZombieDetected",
            "name" : "iPhone 17 Pro Max"
          },
          {
            "udid" : "37B5EC35-D267-40F0-AD81-5A0728646CEB",
            "name" : "iPhone 17e"
          },
          {
            "state" : "Shutdown",
            "name" : "Broken Entry"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.watchOS-11-0" : [
          {
            "udid" : "AAAAAAAA-1111-2222-3333-444444444444",
            "isAvailable" : true,
            "state" : "Shutdown",
            "name" : "Apple Watch Series 10 (46mm)"
          }
        ]
      }
    }
    """

    /// 形状取自真实 `simctl list -j runtimes` 输出（首条字段完整，末条裁剪）。
    static let runtimesJSON = """
    {
      "runtimes" : [
        {
          "bundlePath" : "\\/Library\\/Developer\\/CoreSimulator\\/Profiles\\/Runtimes\\/iOS 18.6.simruntime",
          "buildversion" : "22G86",
          "platform" : "iOS",
          "runtimeRoot" : "\\/Library\\/Developer\\/CoreSimulator\\/Profiles\\/Runtimes\\/iOS 18.6.simruntime\\/Contents\\/Home",
          "identifier" : "com.apple.CoreSimulator.SimRuntime.iOS-18-6",
          "version" : "18.6",
          "isInternal" : false,
          "isAvailable" : true,
          "name" : "iOS 18.6",
          "supportedArchitectures" : [
            "x86_64",
            "arm64"
          ],
          "supportedDeviceTypes" : [
            {
              "bundlePath" : "\\/Library\\/Developer\\/CoreSimulator\\/Profiles\\/DeviceTypes\\/iPhone 16 Pro.simdevicetype",
              "name" : "iPhone 16 Pro",
              "productFamily" : "iPhone",
              "identifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
            }
          ]
        },
        {
          "bundlePath" : "\\/Library\\/Developer\\/CoreSimulator\\/Profiles\\/Runtimes\\/iOS 27.0.simruntime",
          "buildversion" : "24A434",
          "platform" : "iOS",
          "identifier" : "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
          "version" : "27.0",
          "isInternal" : false,
          "isAvailable" : true,
          "name" : "iOS 27.0",
          "supportedArchitectures" : [ "arm64" ]
        },
        {
          "identifier" : "com.apple.CoreSimulator.SimRuntime.watchOS-11-0",
          "version" : "11.0",
          "isAvailable" : false,
          "name" : "watchOS 11.0"
        }
      ]
    }
    """

    /// 形状取自真实 `simctl list -j devicetypes` 输出。
    static let deviceTypesJSON = """
    {
      "devicetypes" : [
        {
          "productFamily" : "iPhone",
          "bundlePath" : "\\/Library\\/Developer\\/CoreSimulator\\/Profiles\\/DeviceTypes\\/iPhone 17 Pro.simdevicetype",
          "maxRuntimeVersion" : 4294967295,
          "maxRuntimeVersionString" : "65535.255.255",
          "identifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
          "modelIdentifier" : "iPhone18,1",
          "minRuntimeVersionString" : "26.0.0",
          "minRuntimeVersion" : 1703936,
          "name" : "iPhone 17 Pro"
        },
        {
          "productFamily" : "iPhone",
          "identifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-16",
          "name" : "iPhone 16"
        }
      ]
    }
    """

    private var deviceTypeNames: [String: String] {
        [
            "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro": "iPhone 17 Pro",
            "com.apple.CoreSimulator.SimDeviceType.iPhone-16": "iPhone 16"
        ]
    }

    func testParseDevicesMapsRuntimeTypeAndState() throws {
        let devices = try SimctlJSONParser.parseDevices(Self.devicesJSON, deviceTypeNames: deviceTypeNames)

        // watchOS 分组与缺 udid 的条目被跳过。
        XCTAssertEqual(devices.count, 4)

        let booted = try XCTUnwrap(devices.first { $0.udid == "D0780F59-BA2D-4279-96AD-B5FC3F73642D" })
        XCTAssertEqual(booted.name, "iPhone 17 Pro")
        XCTAssertEqual(booted.state, "Booted")
        XCTAssertEqual(booted.runtimeVersion, "27.0")
        XCTAssertEqual(booted.deviceTypeName, "iPhone 17 Pro")
        XCTAssertTrue(booted.isBooted)
        XCTAssertTrue(booted.isAvailable)
        XCTAssertEqual(booted.dataPath, "/Users/demo/Library/Developer/CoreSimulator/Devices/D0780F59-BA2D-4279-96AD-B5FC3F73642D/data")

        let shutdown = try XCTUnwrap(devices.first { $0.udid == "DB0DBFF2-7BE8-45EA-A530-07E0ABF2E06B" })
        XCTAssertEqual(shutdown.state, "Shutdown")
        XCTAssertEqual(shutdown.runtimeVersion, "18.6")
        XCTAssertEqual(shutdown.deviceTypeName, "iPhone 16")
        XCTAssertFalse(shutdown.isBooted)
    }

    func testParseDevicesKeepsUnknownStateAndUnavailable() throws {
        let devices = try SimctlJSONParser.parseDevices(Self.devicesJSON, deviceTypeNames: deviceTypeNames)

        let zombie = try XCTUnwrap(devices.first { $0.udid == "17E30C5F-5F09-4A68-910A-C0FC4205B2F5" })
        XCTAssertEqual(zombie.state, "ZombieDetected", "未知 state 必须原样保留")
        XCTAssertFalse(zombie.isBooted)
        XCTAssertFalse(zombie.isAvailable)
        // 类型名映射缺失时回退为标识符。
        XCTAssertEqual(zombie.deviceTypeName, "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max")

        let sparse = try XCTUnwrap(devices.first { $0.udid == "37B5EC35-D267-40F0-AD81-5A0728646CEB" })
        XCTAssertEqual(sparse.state, "", "缺 state 字段解码为空串，不崩溃")
        XCTAssertFalse(sparse.isBooted)
        XCTAssertFalse(sparse.isAvailable)
        XCTAssertEqual(sparse.deviceTypeName, "")
        XCTAssertNil(sparse.dataPath)
    }

    func testParseDevicesSortsRuntimeDescThenNameAsc() throws {
        let devices = try SimctlJSONParser.parseDevices(Self.devicesJSON, deviceTypeNames: deviceTypeNames)
        let versions = devices.map(\.runtimeVersion)
        XCTAssertEqual(versions.first, "27.0")
        XCTAssertEqual(versions.last, "18.6")
        let ios27Names = devices.filter { $0.runtimeVersion == "27.0" }.map(\.name)
        XCTAssertEqual(ios27Names, ["iPhone 17 Pro", "iPhone 17 Pro Max", "iPhone 17e"])
    }

    func testParseDevicesSkipsNonIOSRuntime() throws {
        let json = """
        {
          "devices" : {
            "com.apple.CoreSimulator.SimRuntime.watchOS-11-0" : [
              { "udid" : "AAAAAAAA-1111-2222-3333-444444444444", "state" : "Shutdown", "name" : "Watch" }
            ]
          }
        }
        """
        XCTAssertEqual(try SimctlJSONParser.parseDevices(json, deviceTypeNames: [:]), [])
    }

    func testParseDevicesRejectsBrokenStructure() {
        XCTAssertThrowsError(try SimctlJSONParser.parseDevices("not json", deviceTypeNames: [:]))
        // 顶层缺 devices 键视作结构损坏，而不是静默空列表。
        XCTAssertThrowsError(try SimctlJSONParser.parseDevices("{}", deviceTypeNames: [:]))
    }

    func testParseDevicesToleratesEmptyDeviceEntry() throws {
        let json = """
        {
          "devices" : {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0" : [ {} ]
          }
        }
        """
        XCTAssertEqual(try SimctlJSONParser.parseDevices(json, deviceTypeNames: [:]), [])
    }

    func testParseRuntimes() throws {
        let runtimes = try SimctlJSONParser.parseRuntimes(Self.runtimesJSON)
        XCTAssertEqual(runtimes.count, 3)
        // 按版本降序。
        XCTAssertEqual(runtimes.map(\.version), ["27.0", "18.6", "11.0"])

        let ios27 = runtimes[0]
        XCTAssertEqual(ios27.identifier, "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        XCTAssertEqual(ios27.buildVersion, "24A434")
        XCTAssertTrue(ios27.isAvailable)
        XCTAssertTrue(ios27.isIOS)

        let watchOS = runtimes[2]
        XCTAssertFalse(watchOS.isIOS)
        XCTAssertFalse(watchOS.isAvailable)
    }

    func testParseRuntimesCapturesSupportedDeviceTypes() throws {
        let runtimes = try SimctlJSONParser.parseRuntimes(Self.runtimesJSON)

        // fixture 中 iOS 18.6 带一条 supportedDeviceTypes，iOS 27.0 未输出该字段。
        let ios18 = try XCTUnwrap(runtimes.first { $0.version == "18.6" })
        XCTAssertEqual(ios18.supportedDeviceTypes.map(\.identifier), [
            "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
        ])
        XCTAssertEqual(ios18.supportedDeviceTypes.first?.name, "iPhone 16 Pro")
        XCTAssertEqual(ios18.supportedDeviceTypes.first?.productFamily, "iPhone")

        let ios27 = try XCTUnwrap(runtimes.first { $0.version == "27.0" })
        XCTAssertTrue(ios27.supportedDeviceTypes.isEmpty, "缺字段解码为空数组，不崩溃")
    }

    /// 创建向导的机型过滤：优先 runtime 声明的 supportedDeviceTypes，
    /// 未声明（老版本 simctl）时回退全部候选。
    func testFilterDeviceTypesByRuntimeSupport() throws {
        let candidates = try SimctlJSONParser.parseDeviceTypes(Self.deviceTypesJSON)
        XCTAssertEqual(candidates.map(\.identifier), [
            "com.apple.CoreSimulator.SimDeviceType.iPhone-16",
            "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
        ])

        let supporting = SimulatorRuntime(
            identifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-6",
            version: "18.6",
            buildVersion: nil,
            isAvailable: true,
            supportedDeviceTypes: [
                SimulatorDeviceType(
                    identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                    name: "iPhone 17 Pro",
                    productFamily: nil
                )
            ]
        )
        XCTAssertEqual(supporting.filterDeviceTypes(candidates).map(\.identifier), [
            "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
        ])

        let undeclared = SimulatorRuntime(
            identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            version: "27.0",
            buildVersion: nil,
            isAvailable: true,
            supportedDeviceTypes: []
        )
        XCTAssertEqual(undeclared.filterDeviceTypes(candidates).map(\.identifier), candidates.map(\.identifier))
    }

    func testParseDeviceTypes() throws {
        let types = try SimctlJSONParser.parseDeviceTypes(Self.deviceTypesJSON)
        XCTAssertEqual(types.count, 2)
        XCTAssertEqual(types.map(\.name), ["iPhone 16", "iPhone 17 Pro"])
        XCTAssertEqual(types[1].identifier, "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")
        XCTAssertEqual(types[1].productFamily, "iPhone")
    }

    func testRuntimeVersionFromIdentifier() {
        XCTAssertEqual(
            SimctlJSONParser.runtimeVersion(from: "com.apple.CoreSimulator.SimRuntime.iOS-27-0"),
            "27.0"
        )
        XCTAssertEqual(
            SimctlJSONParser.runtimeVersion(from: "com.apple.CoreSimulator.SimRuntime.iOS-18-6"),
            "18.6"
        )
        XCTAssertNil(SimctlJSONParser.runtimeVersion(from: "com.apple.CoreSimulator.SimRuntime.watchOS-11-0"))
        XCTAssertNil(SimctlJSONParser.runtimeVersion(from: "com.apple.CoreSimulator.SimRuntime.iOS-"))
        XCTAssertNil(SimctlJSONParser.runtimeVersion(from: "unknown-key"))
    }

    func testCompareVersions() {
        XCTAssertEqual(SimctlJSONParser.compareVersions("27.0", "18.6"), .orderedDescending)
        XCTAssertEqual(SimctlJSONParser.compareVersions("18.6", "27.0"), .orderedAscending)
        XCTAssertEqual(SimctlJSONParser.compareVersions("18.6", "18.6"), .orderedSame)
        XCTAssertEqual(SimctlJSONParser.compareVersions("18", "18.0"), .orderedSame)
        XCTAssertEqual(SimctlJSONParser.compareVersions("18.10", "18.9"), .orderedDescending)
    }
}
