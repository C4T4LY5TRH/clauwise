import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                log("LoginItem: registered successfully")
            } else {
                try SMAppService.mainApp.unregister()
                log("LoginItem: unregistered successfully")
            }
        } catch {
            log("LoginItem: failed to \(enabled ? "register" : "unregister"): \(error)")
        }
    }
}
