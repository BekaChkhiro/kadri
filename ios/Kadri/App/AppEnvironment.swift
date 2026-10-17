import Foundation
import Observation

/// The app's single Worker config, session store, API client and sign-in controller.
@MainActor
@Observable
final class AppEnvironment {
    let config: APIConfig
    let authStore: AuthStore
    let client: KadriClient
    let googleAuth: GoogleAuthController

    /// `KADRI_API_URL` from Info.plist (project.yml); a local `wrangler dev` when it is missing.
    init(config: APIConfig = APIConfig.fromBundle() ?? APIConfig(baseURL: URL(string: "http://localhost:8797")!)) {
        self.config = config
        authStore = AuthStore(config: config)
        client = KadriClient(config: config, auth: authStore)
        googleAuth = GoogleAuthController(
            google: GIDTokenProvider(),
            worker: WorkerAuth(store: authStore, config: config)
        )
    }
}
