import { ApiError } from "../errors";

/** AI-stage errors; messages are user-facing Georgian, details stay in logs. */
export const aiErrors = {
  badRequest: (detail: string) => new ApiError(400, "bad_request", `არასწორი მოთხოვნა: ${detail}`),
  notConfigured: () => new ApiError(500, "ai_not_configured", "AI სერვისი არ არის კონფიგურირებული"),
  providerUnavailable: () =>
    new ApiError(501, "ai_provider_unavailable", "ეს AI რეჟიმი ჯერ არ არის ხელმისაწვდომი"),
  upstream: () => new ApiError(502, "ai_upstream", "AI სერვისი დროებით მიუწვდომელია, სცადე თავიდან"),
  incomplete: () => new ApiError(502, "ai_incomplete", "AI-მ პასუხი ბოლომდე ვერ დაწერა, სცადე თავიდან"),
  invalid: () => new ApiError(502, "ai_invalid_response", "AI-მ არასწორი პასუხი დააბრუნა, სცადე თავიდან"),
  timeout: () => new ApiError(504, "ai_timeout", "AI-მ დროულად ვერ უპასუხა, სცადე თავიდან"),
};
