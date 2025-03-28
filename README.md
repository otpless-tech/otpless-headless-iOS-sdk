# OTPLESS iOS Headless SDK

The OTPLESS iOS Headless SDK empowers developers to integrate seamless, passwordless authentication into iOS applications using custom user interfaces. This SDK provides the flexibility to design tailored authentication flows while leveraging OTPLESS's robust backend services.

For comprehensive integration details and advanced configurations, refer to the [OTPLESS iOS Headless SDK Documentation](https://otpless.com/docs/frontend-sdks/app-sdks/ios/new/headless/headless). 

## Key Features

- **Custom UI Integration**: Design and implement your own authentication interfaces.
- **Multiple Authentication Channels**: Support for various methods including phone number, email, and social logins.
- **Enhanced Security**: Utilize OTPLESS's secure backend for reliable authentication.

## Requirements

- **iOS 13.0** or later
- **Xcode 12.0** or later
- **Swift 5.5** or later

## Installation

You can integrate the OTPLESS iOS Headless SDK into your project using either CocoaPods or Swift Package Manager (SPM).

### CocoaPods

1. **Add the SDK to Your Podfile**:

   ```ruby
   pod 'OtplessBM/Core', 'latest_version'
   ```

   Replace `'latest_version'` with the latest version of the SDK.

2. **Install the Pod**:

   ```bash
   pod repo update
   pod install
   ```


### Swift Package Manager (SPM)

1. **Add the Package Dependency**:

   - In Xcode, navigate to `File > Swift Packages > Add Package Dependency`.
   - Enter the repository URL:

     ```
     https://github.com/otpless-tech/otpless-headless-iOS-sdk
     ```

   - Use the exact version and complete the integration.

## Integration Steps

1. **Configure `Info.plist`**:

   Add the following configurations to your project's `Info.plist` file:

   ```xml
   <key>CFBundleURLTypes</key>
   <array>
       <dict>
           <key>CFBundleURLSchemes</key>
           <array>
               <string>otpless.YOUR_APP_ID_IN_LOWERCASE</string>
           </array>
           <key>CFBundleTypeRole</key>
           <string>Editor</string>
           <key>CFBundleURLName</key>
           <string>otpless</string>
       </dict>
   </array>
   <key>LSApplicationQueriesSchemes</key>
   <array>
       <string>whatsapp</string>
       <string>otpless</string>
       <string>gootpless</string>
       <string>com.otpless.ios.app.otpless</string>
       <string>googlegmail</string>
   </array>
   ```


   Replace `YOUR_APP_ID_IN_LOWERCASE` with your actual App ID in lowercase, as provided in your OTPLESS dashboard.

2. **Handle URL Redirection**:

   Implement the following method in your `AppDelegate` to manage URL redirections:

   ```swift
   func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
       if Otpless.shared.isOtplessDeeplink(url: url) {
           Task(priority: .userInitiated) {
               await Otpless.shared.handleDeeplink(url)
           }
       }
       return true
   }
   ```


3. **Initialize OTPLESS**:

   In your view controller, import the SDK and initialize it:

   ```swift
   import OtplessBM

   class YourViewController: UIViewController, OtplessResponseDelegate {
       override func viewDidLoad() {
           super.viewDidLoad()
           Otpless.shared.initialise(withAppId: "YOUR_APP_ID", vc: self)
           Otpless.shared.setResponseDelegate(self)
       }

       // Implement OtplessResponseDelegate methods here
   }
   ```


   Replace `YOUR_APP_ID` with your actual App ID from the OTPLESS dashboard.

4. **Handle Authentication Responses**:

   Conform to the `OtplessResponseDelegate` protocol to manage authentication callbacks:

   ```swift
   extension YourViewController: OtplessResponseDelegate {
       func onOtplessResponse(response: OtplessResponse) {
           // Handle successful authentication response
       }
   }
   ```
