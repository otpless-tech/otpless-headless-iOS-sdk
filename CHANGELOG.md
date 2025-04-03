
## 1.1.0 (3rd April 2025)

### Improvements
- Added sdkVersion in appInfo

### Fixes
- Fixed an issue in which incorrect fields were sent to the server in case of sna failure

## 1.0.9 (31st March 2025)

### Fixes
- Fixed internal event name for better event tracking

## 1.0.8 (31st March 2025)

### Fixes
- `otpLength` bug fix


## 1.0.7 (28th March 2025)
## Features
- Added `otpLength` in `INITIATE` response

## Fixes
- `authType` sent incorrect in rare cases in `VERIFY` response


## 1.0.6 (24th March 2025)
### Features
- Added `DELIVERY_STATUS` responseType to indicate whether authType (OTP, MAGICLINK, OTP_LINK) has been delivered on the specified delivery channel.

## 1.0.5 (24th March 2025)
### Features
- Added INITIATE & VERIFY responses for SNA

## 1.0.4 (6th March 2025)
### Fixes
- Fixed an issue in which error code did not match the error message in the response.

## 1.0.3 (6th March 2025)
### Improvements
- Robust response handling in case of no internet connection
- Improved SNA performance
- Improved resource utilization
- providerMetadata response improvements

## Fixes
- SNA failure faced in case of slow internet

## 1.0.2 (4th March 2025)
### Fixes
- Fixed an issue in which SNA was failing for some users.

## 1.0.1 (4th March 2025)
### Features
- Added support for `SmartAuth` templateId for OTP delivery.
- Added new ResponseType `SDK_READY` to indicate that SDK has been initialized successfully.

### Fixes
- Fixed a bug in which `No Internet Connection` response was sent when it was not required.
- Fixed getter method for `OtplessResponse` object.

### Improvements
- Improved the SDK initialization process for better performance and reliability.

## 1.0.0 (24th February 2025)
- Initial release
