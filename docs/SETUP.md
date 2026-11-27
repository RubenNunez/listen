# Setup

## Mac

Install Xcode 27.2 and its Metal Toolchain component, and XcodeGen. Run
`ios/Tools/run-mac.sh` from the repository root. The helper generates the Xcode
project, builds a Mac Catalyst app and opens it only after a successful build.

Choose a model connection, a Voice assistant system and a local voice in the app.
Start a conversation explicitly. Recognition/model assets may need a first download.
Downloads require connectivity; downloaded local speech models run on the device.

## iPhone

Run `ios/Tools/generate-project.sh` from the root, open `Listen.xcodeproj`, and select your
device. Configure your own signing team and bundle identifier. The project does
not include the maintainer's provisioning profiles or signing credentials.

The simulator does not provide the physical device's on-device recognition path;
do not use simulator demonstrations as phone audio performance measurements.

## Models and tools

Use your own supported model connection. Optional JEV routing and cloud models
require their own access and may incur provider charges. Choosing a subscription
sign-in does not itself confer API billing entitlement.

Local voice selection changes speech output, not the reasoning model or tool grants.
Read a model's license before downloading it. Arbitrary reasoning-weight loading
is outside this alpha's general-purpose native model support.

MCP servers are configured under Connections. Enable individual bindings and retain
confirmation unless you deliberately grant a tool standing permission. HTTPS is
required for non-loopback endpoints; localhost on a Mac is not the same host as
localhost on an iPhone.

Keep environment files, keys, recordings and device-pairing data out of the source
directory and Git. Native account storage uses the app's configured secure stores.
