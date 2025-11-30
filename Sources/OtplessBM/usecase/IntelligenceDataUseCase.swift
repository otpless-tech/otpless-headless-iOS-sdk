


import Foundation

class IntelligenceDataUseCase {
    func invoke(bodyParams: [String: Any]) async -> ApiResponse<IntelligenceApiResponse> {
        let result = await Otpless.shared.apiRepository
            .pushIntelligenceData(bodyParams: bodyParams)

        switch result {
        case .success(let response):
            return .success(data: response)

        case .failure(let error):
            // Map Swift Error → ApiError
            let apiError = (error as? ApiError)
                ?? ApiError(message: error.localizedDescription)
            return .error(error: apiError)
        }
    }
}


