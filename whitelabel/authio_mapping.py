"""
AuthIo whitelabel brand mapping — single source of truth for build_whitelabel.py.

How this file is used
  This is pure configuration: module-level constants, no logic. build_whitelabel.py loads it with
  importlib (`--mapping`, default: this file) and reads the constants below by name. Everything
  brand-specific lives here, so another partner brand is just another mapping file:
      python3 whitelabel/build_whitelabel.py --mapping whitelabel/<brand>_mapping.py

  The generator walks every Swift file and splits it into three kinds of segment, each handled by
  different constants:
      code      (identifiers)      → IDENTIFIERS / PRESERVED_IDENTIFIERS
      strings   (literal contents) → LITERALS / PRESERVED_LITERALS
      comments                     → IDENTIFIERS, then the GENERIC fallback
  Any brand match (BRAND_PATTERN) in code or strings that no constant covers stops the build and
  prints the exact row to paste here. The same PRESERVED_* entries are also the allow-list for the
  post-build scan of the shipped binary, symbols and .swiftinterface.

iOS twin of android LongClaw-authio/whitelabel/authio-mapping.gradle; keep shared names (class
renames, storage keys, enum members) in sync with it so both partner SDKs look alike.

Where does a new brand token go?
  * code identifier           → IDENTIFIERS, unless it is a wire contract (Codable property,
                                 String-enum case without explicit raw value) → PRESERVED_IDENTIFIERS
  * merchant-visible literal   → LITERALS (log prefixes, error messages, storage keys, queue labels)
  * backend / server contract  → PRESERVED_LITERALS (hosts, telemetry values, external class names)
Every PRESERVED_* entry must say why it stays.
"""

# ---------------------------------------------------------------------------------------------
# Identity & build settings — read by main() / write_project() in build_whitelabel.py
# ---------------------------------------------------------------------------------------------
FLAVOR = 'authio'                          # scratch dir name: $TMPDIR/<FLAVOR>-whitelabel
MODULE = 'AuthIoSDK'                       # framework + Swift module name: `import AuthIoSDK`; must differ from every public type name
BUNDLE_ID = 'com.authio.sdk'               # PRODUCT_BUNDLE_IDENTIFIER of the framework
DEPLOYMENT_TARGET = '15.0'                 # Xcode 26+ floor (podspec says 13.0, unbuildable with current Xcode)
SWIFT_VERSION = '5.0'                      # Package.swift: swiftLanguageVersions [.v5]
# (file, regex) — group 1 is the version; read from the built git ref, names the zip and sets MARKETING_VERSION
VERSION_SOURCE = ('OtplessBM.podspec', r"s\.version\s*=\s*'([^']+)'")

# ---------------------------------------------------------------------------------------------
# What counts as the brand — compiled case-insensitively. Any match left in the generated tree
# or in the built xcframework must be covered by a rename or a PRESERVED_* entry.
# ---------------------------------------------------------------------------------------------
BRAND_PATTERN = r'otpless|longclaw'

# Fallback brand swap (Rewriter.generic), keyed by the casing that matched. Used only where a
# mistake cannot break the build or the wire: comments, file names, and the suggested rows the
# generator prints for unmapped identifiers. Code and literals never fall back to this.
GENERIC = {'Otpless': 'AuthIo', 'OTPLESS': 'AUTHIO', 'otpless': 'authio', 'OTPless': 'AuthIo',
           'LongClaw': 'AuthIo', 'longclaw': 'authio', 'default': 'AuthIo'}
GENERIC_CAMEL = 'authIo'                   # lowercase brand followed by an uppercase letter: otplessFoo → authIoFoo

# ---------------------------------------------------------------------------------------------
# Inputs — read by export_ref() / generate()
# ---------------------------------------------------------------------------------------------
# Every entry's *.swift files are rewritten into Sources/<dest>/ of ONE Swift module.
#   module       : original module name (used to drop `import <module>` lines once merged)
#   path         : source dir; repo-relative (snapshotted from the git ref), or inside the SPM
#                  checkout when spm_package is set (pinned by the ref's Package.resolved)
#   vendored     : merged dependency — its `public` modifiers are stripped so it stays internal,
#                  same as Android vendoring eventio/autoread
SOURCES = [
    dict(module='OtplessBM', path='Sources/OtplessBM', dest='Core'),
    dict(module='OtplessEventIO', spm_package='otpless-event-io-ios', path='Sources/OtplessEventIO',
         dest='Vendored/EventIO', vendored=True),
]

# repo path → path under Sources/; copied verbatim (the generator refuses them if they contain the brand)
RESOURCES = {
    'Sources/PrivacyInfo.xcprivacy': 'Resources/PrivacyInfo.xcprivacy',
}

# ---------------------------------------------------------------------------------------------
# Code identifiers — Rewriter.rewrite_code() renames every whole word containing the brand.
# Also applied to file names (Otpless.swift → AuthIo.swift) and comments. The compiler checks
# these renames: a missed reference fails the build instead of shipping.
# ---------------------------------------------------------------------------------------------
IDENTIFIERS = {
    # Module / entry point
    'OtplessBM':                      'AuthIoSDK',
    'Otpless':                        'AuthIo',
    'OtplessBMEvents':                'AuthIoEvents',                    # Android: LongClawEvents → AuthIoEvents
    # Public API
    'OtplessAuthCofig':               'AuthIoAuthCofig',
    'OtplessChannelType':             'AuthIoChannelType',
    'OtplessChannelTypeObjC':         'AuthIoChannelTypeObjC',
    'OtplessEnvironment':             'AuthIoEnvironment',
    'OtplessLoggerDelegate':          'AuthIoLoggerDelegate',
    'OtplessRequest':                 'AuthIoRequest',
    'OtplessResponse':                'AuthIoResponse',
    'OtplessResponseDelegate':        'AuthIoResponseDelegate',
    'OtplessSessionManager':          'AuthIoSessionManager',
    'OtplessSessionState':            'AuthIoSessionState',
    'OtplessSslKind':                 'AuthIoSslKind',
    'OTPLESS':                        'AUTHIO',                          # ProviderType case (Int raw value); Android: enumRenames
    'isOtplessDeeplink':              'isAuthIoDeeplink',
    'setOtplessObjcResponseDelegate': 'setAuthIoObjcResponseDelegate',
    'withOtplessRequest':             'withAuthIoRequest',               # argument label
    # Internal
    'commitOtplessResponse':          'commitAuthIoResponse',
    'merchantOtplessRequest':         'merchantAuthIoRequest',
    'OtplessConstant':                'AuthIoConstant',
    'OtplessExtensions':              'AuthIoExtensions',
    'OtplessKeyVault':                'AuthIoKeyVault',
    'OtplessSessionInfo':             'AuthIoSessionInfo',
    'OtplessSslPinManager':           'AuthIoSslPinManager',
    'OTPLESS_INTERNAL':               'AUTHIO_INTERNAL',                 # compilation condition (never set in release)
    'otplessCellularNetwork':         'authIoCellularNetwork',
    'otplessLoggerDelegate':          'authIoLoggerDelegate',
    'otplessRequest':                 'authIoRequest',
    'otplessResponse':                'authIoResponse',
    'otplessResponseDelegate':        'authIoResponseDelegate',
    'otplessResponses':               'authIoResponses',
    # Vendored OtplessEventIO
    'OtplessEventIO':                 'AuthIoEventIO',
    'OtplessEventIOContract':         'AuthIoEventIOContract',
    'OtplessEventIOImpl':             'AuthIoEventIOImpl',
    'OtplessTrackEvent':              'AuthIoTrackEvent',
}

# Code identifiers that must keep the brand, because renaming them would silently change data on
# the wire (the compiler cannot catch that). Value = reason, required. Also allowed by the audit.
PRESERVED_IDENTIFIERS = {
    'otplessId':      'Codable property of MerchantConfigResponse.Merchant — JSON key sent by the backend',
    'SDK_TO_OTPLESS': 'OtplessEventIO EventType case (String raw value = case name) — telemetry wire value',
}

# ---------------------------------------------------------------------------------------------
# String literals — Rewriter.rewrite_string() applies these substring replacements inside every
# literal, longest key first (so 'OtplessBM' wins over a shorter overlapping key). Literals are
# never renamed implicitly: if brand text is still left after these rules, it must match
# PRESERVED_LITERALS or the build fails.
# ---------------------------------------------------------------------------------------------
LITERALS = {
    # Reflection — functional, NSClassFromString("<Module>.<Class>")
    'OtplessBM':                      'AuthIoSDK',
    'OtplessSDK':                     'AuthIoSDK',
    'OtplessEventIO':                 'AuthIoEventIO',                   # os_log category
    # Merchant-visible messages
    'OTPLESS:':                       'AuthIo:',
    'OTPLESS Dashboard':              'AuthIo Dashboard',
    'Otpless authentication request cancelled': 'AuthIo authentication request cancelled',
    'Otpless auth in progress':       'AuthIo auth in progress',
    'OTPless headless SDK':           'AuthIo SDK',
    'otpless: failed to parse data':  'authio: failed to parse data',
    'OtplessCellularManager':         'AuthIoCellularManager',
    'OtplessGIDSignIn':               'AuthIoGIDSignIn',
    'otplesssdk':                     'authiosdk',                       # User-Agent suffix; Android: ' otplesssdk' → ' authiosdk'
    "Invalid host — expected 'otpless', got '": "Invalid host — expected the AuthIo login host, got '",  # DLog; host itself stays otpless
    # Telemetry identifiers — the backend must recognise these AuthIo values (Android still sends the otpless ones)
    'native_cle_otpless':             'native_cle_authio',               # ProviderType.nativeName
    'otpless-headless(':              'authio-headless(',                # buildPlatform, e.g. authio-headless(ios)
    # Queue labels, os_log subsystems, keychain service
    'com.otpless':                    'com.authio',
    # UserDefaults / keychain / sqlite names (Android sharedPrefsRenames use the _kss3 suffix)
    'otpless_bm_state':               'authio_state_kss3',
    'otpless_bm_inid':                'authio_inid_kss3',
    'otpless_bm_uid':                 'authio_uid_kss3',
    'otpless_session_info':           'authio_session_info_kss3',
    'otpless_session_state':          'authio_session_state_kss3',
    'otplessbm_pin_manifest_envelope': 'authio_pin_manifest_envelope_kss3',
    'otplessbm_pin_last_fetch_at':    'authio_pin_last_fetch_at_kss3',
    'otpless_event_prefs':            'authio_event_prefs_kss3',
    'otpless_event.db':               'authio_event_kss3.db',
}

# Regex → reason. Brand text matching one of these may stay in a literal after LITERALS ran, and
# may appear in the built binary. ^ and $ anchor to one literal segment (the text between quotes
# or around an interpolation), e.g. "otpless.\(appId)://otpless" is checked as "otpless." and
# "://otpless". In the binary audit they anchor to one `strings` / demangled-symbol line.
PRESERVED_LITERALS = {
    r'(?:[\w-]+\.)*otpless\.(?:app|com|tech)\b': 'OTPLESS backend hosts — AuthIo talks to the same backend',
    r'OTPlessIntelligence':                      'external OTPlessIntelligence SDK, loaded via NSClassFromString — its class name is fixed',
    r'^otpless\.$|^://otpless$|^otpless$':       'deeplink otpless.<appId>://otpless — loginUri registered with the backend (Android keeps it too)',
}
