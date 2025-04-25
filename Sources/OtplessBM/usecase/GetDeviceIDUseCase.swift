//
//  GetDeviceIDUseCase.swift
//  OtplessSDK
//
//  Created by Sparsh on 20/01/25.
//

class GetDeviceIDUseCase {
    private var retryCount = 0
    
    func invoke(
        isRetry: Bool
    ) async -> String? {
        
        if let existingDeviceID = SecureStorage.shared.retrieve(key: Constants.DEVICE_ID_KEY),
           !existingDeviceID.isEmpty {
            return existingDeviceID
        }
        
        if !isRetry {
            retryCount = 0
        }
        let response = await Otpless.shared.apiRepository
            .generateDeviceID(body: DeviceIDRequestBody())
        switch response {
        case .success(let success):
            SecureStorage.shared.save(key: Constants.DEVICE_ID_KEY, value: success.otpless_device_id ?? "")
            return success.otpless_device_id
        case .failure(let _):
            if retryCount == 1 {
                retryCount = 0
                return nil
            } else {
                retryCount += 1
                return await invoke(isRetry: true)
            }
        }
    }
}
