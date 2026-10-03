import ManagedSettings
import ManagedSettingsUI
import UIKit

// Overrides the system shield shown when a metered app/category runs out of
// earned time. Same look across all four override points — application,
// application category, web domain, and web domain category — since the
// messaging ("do pushups to earn more") applies uniformly.
class ShieldConfigurationExtension: ShieldConfigurationDataSource {

    private var configuration: ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .systemMaterialDark,
            backgroundColor: .black,
            title: ShieldConfiguration.Label(text: "Out of minutes", color: .white),
            subtitle: ShieldConfiguration.Label(
                text: "Do pushups in PushupTime to earn more",
                color: .lightGray
            ),
            primaryButtonLabel: ShieldConfiguration.Label(text: "Earn time", color: .black),
            primaryButtonBackgroundColor: .white
        )
    }

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        configuration
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        configuration
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        configuration
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        configuration
    }
}
