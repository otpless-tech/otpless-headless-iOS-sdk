"""
AuthIo whitelabel brand mapping — single source of truth for build_whitelabel.py.

iOS twin of android LongClaw-authio/whitelabel/authio-mapping.gradle; keep shared names (class
renames, storage keys, enum members) in sync with it so both partner SDKs look alike.

When the generator fails on an unmapped token it prints the exact row to paste here. Rule of thumb:
  * code identifier           → IDENTIFIERS, unless it is a wire contract (Codable property,
                                 String-enum case without explicit raw value) → PRESERVED_IDENTIFIERS
  * merchant-visible literal   → LITERALS (log prefixes, error messages, storage keys, queue labels)
  * backend / server contract  → PRESERVED_LITERALS (hosts, telemetry values, external class names)
Every PRESERVED_* entry must say why it stays.
"""

FLAVOR = 'authio'
MODULE = 'AuthIoSDK'                       # framework + Swift module name: `import AuthIoSDK`
BUNDLE_ID = 'com.authio.sdk'
DEPLOYMENT_TARGET = '15.0'                 # Xcode 26+ floor (podspec says 13.0, unbuildable with current Xcode)
SWIFT_VERSION = '5.0'                      # Package.swift: swiftLanguageVersions [.v5]
VERSION_SOURCE = ('OtplessBM.podspec', r"s\.version\s*=\s*'([^']+)'")

# Case-insensitive; any match in the generated tree or the built binary must be mapped or preserved
BRAND_PATTERN = r'otpless|longclaw'

# Fallback brand swap for comments / file names / suggestions (keyed by the matched casing)
GENERIC = {'Otpless': 'AuthIo', 'OTPLESS': 'AUTHIO', 'otpless': 'authio', 'OTPless': 'AuthIo',
           'LongClaw': 'AuthIo', 'longclaw': 'authio', 'default': 'AuthIo'}
GENERIC_CAMEL = 'authIo'                   # lowercase brand followed by an uppercase letter: otplessFoo → authIoFoo

# Merged into ONE Swift module. Vendored modules lose their `import` lines and `public` modifiers,
# so they become internal implementation detail (same as Android vendoring eventio/autoread).
SOURCES = [
    dict(module='OtplessBM', path='Sources/OtplessBM', dest='Core'),
    dict(module='OtplessEventIO', spm_package='otpless-event-io-ios', path='Sources/OtplessEventIO',
         dest='Vendored/EventIO', vendored=True),
]

# Copied verbatim (the generator refuses them if they contain the brand)
RESOURCES = {
    'Sources/PrivacyInfo.xcprivacy': 'Resources/PrivacyInfo.xcprivacy',
}

# Code identifiers (whole word). Also applied to file names and comments.
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

# Code identifiers that must keep the brand. Reason required.
PRESERVED_IDENTIFIERS = {
    'otplessId':      'Codable property of MerchantConfigResponse.Merchant — JSON key sent by the backend',
    'SDK_TO_OTPLESS': 'OtplessEventIO EventType case (String raw value = case name) — telemetry wire value',
}

# Substring rewrites inside string literals (longest match first).
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

# Regexes for brand text that must stay in literals (and may appear in the binary). Reason required.
PRESERVED_LITERALS = {
    r'(?:[\w-]+\.)*otpless\.(?:app|com|tech)\b': 'OTPLESS backend hosts — AuthIo talks to the same backend',
    r'native_cle_otpless':                       'ProviderType.nativeName telemetry value — parsed server-side',
    r'otpless-headless\(':                       'buildPlatform identifier sent in telemetry — identifies the underlying SDK (Android keeps it too)',
    r'OTPlessIntelligence':                      'external OTPlessIntelligence SDK, loaded via NSClassFromString — its class name is fixed',
    r'^otpless\.$|^://otpless$|^otpless$':       'deeplink otpless.<appId>://otpless — loginUri registered with the backend (Android keeps it too)',
    r"expected 'otpless'":                       'debug log naming the deeplink host above',
}
