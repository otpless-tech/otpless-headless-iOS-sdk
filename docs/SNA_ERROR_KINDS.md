# SNA Failure Payload Reference

On any Silent Network Auth (SNA) failure, `SNAUseCase` falls back to a regular transaction request and forwards the error metadata to the backend as a stringified dictionary under the key `lapseMeta`.

The dictionary is produced by `SnaErrorKind.toDictionary()` in `Sources/OtplessBM/network/cellular/CellularConnectionManager.swift`. Every entry carries at minimum:

- `cause` — machine-readable identifier (`Constants.ERROR_KEY`)
- `brief` — human-readable description (`Constants.ERROR_DESCRIPTION_KEY`)

Some cases add extra keys with request/response context.

## Error kinds

| Enum case | `cause` | `brief` | Additional keys | Trigger |
|---|---|---|---|---|
| `iosConnectivityApiUnavailable` | `cellular_api_unavaiable` | `could not get instance of OtplessCellularManager.` | — | `ApiRepository.makeSNACall` cannot get an `otplessCellularNetwork` instance. |
| `callbackInstanceLost(response)` | `cellular_api_instance_lost` | `The callback self instance is lost. could not revert the callback.` | `status`, `body`, `url` (from `ConnectionResponse.toDict()`) | `checkResponseHandler` fires after `CellularConnectionManager` (`self`) has been deallocated. |
| `badUrl(url)` | `sna_bad_url` | `Failed to parse the sna URL <url>.` | — | URL has no scheme/host, or the intent URL string cannot be parsed to `URL`. |
| `parsingError(src, error)` | `sna_parsing_error` | `Failed to parse the sna response: <error>.\n<raw body>` | — | `JSONSerialization` throws while decoding a 2xx body. |
| `timerFinished` | `sna_url_timeout` | `Didn't get the response in 7 seconds. Closing nw protocol call.` | — | The connection timer (default 7s) fires before a response is received. |
| `httpCommandConversionError(command)` | `sna_http_command_conversion_error` | `Failed to convert HTTP command to Data\ncommand: <command>` **or** `Failed to create the HTTP command` when `command == nil` | — | `createHttpCommand(url:)` returns nil, or the resulting string cannot be UTF-8 encoded. |
| `noDataConnectivity(error)` | `sna_no_data_connectivity` | `error.localizedDescription` or `No data connectivity. Please check your internet connection.` | — | Reserved for connectivity loss (defined but not yet emitted in the diff). |
| `nwProtocolConnectionError(state)` | `nw_protocol_connection_error` | `Failed to create NW connection. state is: <state>` | — | `NWConnection` state transitions to `.failed` or unknown. `state` is `"failed"` or `"unknown"`. |
| `nwProtocolMakeError` | `nw_protocol_make_error` | `iOS api failed to create NWPathConnection instance.` | — | `createConnection(scheme:host:)` returned nil. |
| `nwProtocolFailedToSendData(url, error)` | `nw_protocol_data_send_error` | `error.localizedDescription` or `NWPathConnection failed to send the data.` | `url` | `NWConnection.send` completion delivered an error. |
| `nwProtocolFailedToReceiveData(url, error)` | `nw_protocol_data_receive_error` | `error.localizedDescription` or `NWPathConnection failed to receive the data.` | `url` | `NWConnection.receive` delivered an error. |
| `nonOkError(url, code, data)` | `sna_non_ok_response` | `Non 200..299 response received.\ndata:\n<stringified data>` | `status_code`, `url` | HTTP 4xx/5xx or unexpected status with no parseable body, OR any non-2xx branch of `ConnectionResponse.toResult()`. When built by `toResult()`, `data` carries `status`, `errorBody` (raw response body string), and `url`; when built directly by the status-code branches in `sendAndReceiveWithBody`, `data` is the parsed JSON body (or empty). |
| `invalidResponseBody` | `invalid_sna_response` | `No response received from NWPathConnection` | — | Response has no data, or 2xx body is missing/unparseable. |
| `redirectParsingFailed(response)` | `sna_redirect_parsing_failed` | `Failed to parse redirect response: <response>` | — | 3xx status returned but `parseRedirect` could not extract a Location URL. |
| `pollingTimeOut` | `sna_polling_timeout` | `Transaction could not be polled anymore.` | — | SNA URL callback never populated `snaErrorKind` and the transaction status polling loop exhausted its budget. |

## Delivery path

1. `SNAUseCase.execute` fires the cellular request via `ApiRepository.makeSNACall`.
2. On `.failure(kind)` the enum is stored in `self.snaErrorKind` and polling stops.
3. `pollSNATransaction` unwraps `snaErrorKind?.toDictionary()` (falling back to `SnaErrorKind.pollingTimeOut.toDictionary()` if the callback never fired).
4. The dictionary is serialized with `Utils.convertDictionaryToString` and passed to the fallback transaction request as `["lapseMeta": <stringified dict>]`.
5. In parallel, every failure is also emitted as the telemetry event `sna_api_error` (errorCode `5004`) via `OtplessBMEvents.Sna.snaError`.
