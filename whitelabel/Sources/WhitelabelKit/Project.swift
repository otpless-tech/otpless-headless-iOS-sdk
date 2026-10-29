// Xcode project for the generated module (synchronized folder group → no per-file bookkeeping).
//
// A minimal framework project. The key object is PBXFileSystemSynchronizedRootGroup (Xcode 16+): it points
// the target at the Sources/ folder, and Xcode classifies whatever it finds there (.swift → compile,
// .xcprivacy → resources), so the template never lists individual files. Object IDs are fixed, so the output
// is deterministic. __MODULE__, __PROJECT_SETTINGS__ and __TARGET_SETTINGS__ are filled in by writeProject();
// there is a single Release configuration. `scheme` is the shared scheme `xcodebuild archive -scheme` needs.
import Foundation

let pbxproj = """
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {
		AA0000000000000000000001 /* __MODULE__.framework */ = {isa = PBXFileReference; explicitFileType = wrapper.framework; includeInIndex = 0; path = __MODULE__.framework; sourceTree = BUILT_PRODUCTS_DIR; };
		AA0000000000000000000002 /* Sources */ = {isa = PBXFileSystemSynchronizedRootGroup; path = Sources; sourceTree = "<group>"; };
		AA0000000000000000000003 /* Frameworks */ = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
		AA0000000000000000000004 = {isa = PBXGroup; children = (AA0000000000000000000002, AA0000000000000000000005); sourceTree = "<group>"; };
		AA0000000000000000000005 /* Products */ = {isa = PBXGroup; children = (AA0000000000000000000001); name = Products; sourceTree = "<group>"; };
		AA0000000000000000000006 /* __MODULE__ */ = {isa = PBXNativeTarget; buildConfigurationList = AA0000000000000000000007; buildPhases = (AA0000000000000000000008, AA0000000000000000000003, AA0000000000000000000009); buildRules = (); dependencies = (); fileSystemSynchronizedGroups = (AA0000000000000000000002); name = __MODULE__; productName = __MODULE__; productReference = AA0000000000000000000001; productType = "com.apple.product-type.framework"; };
		AA0000000000000000000007 = {isa = XCConfigurationList; buildConfigurations = (AA000000000000000000000D); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
		AA0000000000000000000008 /* Sources */ = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
		AA0000000000000000000009 /* Resources */ = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
		AA000000000000000000000A /* Project object */ = {isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = 1; LastUpgradeCheck = 2600; }; buildConfigurationList = AA000000000000000000000B; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = AA0000000000000000000004; minimizedProjectReferenceProxies = 1; preferredProjectObjectVersion = 77; productRefGroup = AA0000000000000000000005; projectDirPath = ""; projectRoot = ""; targets = (AA0000000000000000000006); };
		AA000000000000000000000B = {isa = XCConfigurationList; buildConfigurations = (AA000000000000000000000C); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
		AA000000000000000000000C /* Release */ = {isa = XCBuildConfiguration; buildSettings = {__PROJECT_SETTINGS__}; name = Release; };
		AA000000000000000000000D /* Release */ = {isa = XCBuildConfiguration; buildSettings = {__TARGET_SETTINGS__}; name = Release; };
	};
	rootObject = AA000000000000000000000A;
}

"""

let scheme = """
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="NO" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="AA0000000000000000000006" BuildableName="__MODULE__.framework" BlueprintName="__MODULE__" ReferencedContainer="container:__MODULE__.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="NO"/>
</Scheme>

"""

/// Renders `pbxproj` + `scheme` into root/<module>.xcodeproj with the build settings below. Settings that
/// matter for distribution: BUILD_LIBRARY_FOR_DISTRIBUTION (emit .swiftinterface, module stability),
/// SKIP_INSTALL=NO (archive keeps the framework), MACH_O_TYPE (dynamic by default, staticlib with --static),
/// CODE_SIGNING_ALLOWED=NO (signing is optional, in package()).
/// - Parameters:
///   - mapping: module, bundleId, deploymentTarget and swiftVersion come from here.
///   - root: generated module directory; the project is written next to Sources/.
///   - version: MARKETING_VERSION of the framework.
///   - isStatic: true for a static framework.
func writeProject(_ mapping: Mapping, root: URL, version: String, isStatic: Bool) throws {
    let project = [
        "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
        "ENABLE_TESTABILITY": "NO", "ENABLE_USER_SCRIPT_SANDBOXING": "YES", "IPHONEOS_DEPLOYMENT_TARGET": mapping.deploymentTarget,
        "SDKROOT": "iphoneos", "SWIFT_COMPILATION_MODE": "wholemodule", "SWIFT_OPTIMIZATION_LEVEL": "-O",
        "SWIFT_VERSION": mapping.swiftVersion, "VALIDATE_PRODUCT": "YES",
    ]
    let target = [
        "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES", "CODE_SIGNING_ALLOWED": "NO", "CURRENT_PROJECT_VERSION": "1",
        "DEFINES_MODULE": "YES", "DYLIB_INSTALL_NAME_BASE": "@rpath", "GENERATE_INFOPLIST_FILE": "YES",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @loader_path/Frameworks",
        "MACH_O_TYPE": isStatic ? "staticlib" : "mh_dylib", "MARKETING_VERSION": version,
        "PRODUCT_BUNDLE_IDENTIFIER": mapping.bundleId, "PRODUCT_NAME": "$(TARGET_NAME)", "SKIP_INSTALL": "NO",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "NO", "SWIFT_EMIT_LOC_STRINGS": "NO",
        "SWIFT_INSTALL_OBJC_HEADER": "YES", "TARGETED_DEVICE_FAMILY": "1,2",
    ]
    /// pbxproj build settings syntax: KEY = "value"; (sorted for a stable file).
    func render(_ settings: [String: String]) -> String {
        settings.sorted { $0.key < $1.key }.map { "\($0.key) = \"\($0.value)\";" }.joined(separator: " ")
    }

    let pbx = pbxproj.replacingOccurrences(of: "__PROJECT_SETTINGS__", with: render(project)).replacingOccurrences(of: "__TARGET_SETTINGS__", with: render(target))
    let proj = root.appendingPathComponent("\(mapping.module).xcodeproj")
    try writeText(pbx.replacingOccurrences(of: "__MODULE__", with: mapping.module), to: proj.appendingPathComponent("project.pbxproj"))
    try writeText(scheme.replacingOccurrences(of: "__MODULE__", with: mapping.module), to: proj.appendingPathComponent("xcshareddata/xcschemes/\(mapping.module).xcscheme"))
}
