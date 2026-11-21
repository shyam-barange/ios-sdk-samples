# MultiSet Swift SDK Samples

The sample app for the [MultiSet Swift SDK](https://github.com/MultiSet-AI/multiset-swift-package).
It shows localization, object tracking, edge object tracking, map creation (LiDAR and Non-LiDAR), a
GeoPose map view and every SDK setting, and adds the SDK with Swift Package Manager.

To add the SDK to your own app, follow the
[package README](https://github.com/MultiSet-AI/multiset-swift-package#add-the-sdk-to-your-app).

## Requirements

- iOS 16.0+
- Xcode 26 or later
- A device with ARKit support (A12 chip or later). ARKit does not run in the simulator
- Map creation: any device above for a Non-LiDAR scan; a LiDAR scan also needs the LiDAR scanner
  (iPhone 12 Pro or a later Pro model, iPad Pro 2020 or later)
- Edge Object Tracking: a physical device. Its tracking library is built for devices only, so the
  card is disabled in the simulator

## Run the Sample App

1. Clone this repository and open `MultiSet-SDK-Samples.xcodeproj`:

   ```bash
   git clone https://github.com/MultiSet-AI/multiset-swift-samples.git
   ```

   Xcode fetches the SDK from
   [multiset-swift-package](https://github.com/MultiSet-AI/multiset-swift-package) at the version
   the project pins, and downloads its framework from that release.
2. Add your credentials and map code to `MultiSet-SDK-Samples/SDKConfig.swift`:

   ```swift
   struct SDKConfig {
       static let clientId = "YOUR_CLIENT_ID"
       static let clientSecret = "YOUR_CLIENT_SECRET"

       // Use either mapCode OR mapSetCode (not both)
       static let mapCode = "YOUR_MAP_CODE"
       static let mapSetCode = ""

       // Optional, for object tracking (max 10)
       static let objectCodes: [String] = []

       // Optional, objects processed in "Edge Based" mode on the dashboard
       static let edgeObjectCodes: [String] = []
   }
   ```

   | Property          | Description              | Required                 |
   |-------------------|--------------------------|--------------------------|
   | `clientId`        | Your client identifier   | Yes                      |
   | `clientSecret`    | Your secret key          | Yes                      |
   | `mapCode`         | Single map identifier    | For localization, one of these |
   | `mapSetCode`      | Map set identifier       | For localization, one of these |
   | `objectCodes`     | Objects to track         | For object tracking      |
   | `edgeObjectCodes` | Edge objects to track    | For edge object tracking |

   Map creation needs only the credentials. To fetch tokens from your own server instead, set
   `tokenServerURL` and leave the credentials as they are; see
   [SERVER_AUTH_GUIDE.md](https://github.com/MultiSet-AI/multiset-swift-package/blob/main/SERVER_AUTH_GUIDE.md).
   Don't commit your credentials.

   To obtain credentials, visit [https://developer.multiset.ai/credentials](https://developer.multiset.ai/credentials).
3. Select your development team under **Signing & Capabilities**, then run on a device.

## What the Sample Shows

The gear icon on the landing screen edits the localization and object-tracking settings at runtime.
The **Mapping** card scans a space into a new map — on a LiDAR device choose **LiDAR** or
**Non-LiDAR**, on any other device it scans Non-LiDAR — and **Draft Maps** lists scans that have
not been uploaded yet.

On the AR screens, the small card at the top left shows each run's steps — capturing, uploading,
waiting on the server, then a tick or a red mark — and a bar at the bottom left shows a map or
object mesh while it loads. See
[Showing a Run's Progress](https://github.com/MultiSet-AI/multiset-swift-package#showing-a-runs-progress).

The **GeoPose Map View** card opens the AR view under a map that plots each localization's GeoPose
— the position and the way the camera faced — beside the device's GPS track. It works only with a
geo-referenced map or MapSet: other maps localize, but their responses carry no GeoPose to plot.
The map is Apple MapKit, so it needs no key, and it asks for location access to draw the GPS
track. See [Reading the GeoPose](https://github.com/MultiSet-AI/multiset-swift-package#reading-the-geopose).

The **Edge Object Tracking** card follows an object frame by frame, including while it moves. It
works with objects whose CAD model was processed in "Edge Based" mode on the dashboard: a model at
true scale of a rigid object that stands out in colour from its background. Pick an object, line the
phone up with the yellow guide outline and tap **Start**; once tracked, the object is drawn with a
purple outline, and when it is lost the yellow outline shows where it was last seen. An object
processed with auto start needs no guide: keep the whole object inside the on-screen box, and the
sample asks the server where it is. Each object is about 16 MB to download and about 300 MB once
unpacked into the app's caches; swipe its row to delete it. This is sample code built on the SDK's
public API, under `MultiSet-SDK-Samples/EdgeObjectTracking/`. Its tracking library,
`EdgeObjectTracking/EOT/libeot.a`, must ship with
`EdgeObjectTracking/EOT/THIRD_PARTY_NOTICES.txt` in any app that includes it.

## SDK Version

The project pins the SDK to an exact version, and this repository moves to each new SDK release.
To try another version, select the project in Xcode, open **Package Dependencies**, and change the
version of `multiset-swift-package`.

Versions up to 2.4.0 shipped from this repository, which was called `multiset-ios-sdk`, as a
committed `MultiSetSDK.xcframework` plus the `MultiSetAR` folder. From 2.5.0 the SDK ships only as
the Swift package; the
[package changelog](https://github.com/MultiSet-AI/multiset-swift-package/blob/main/CHANGELOG.md)
covers every release.

## License

Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License; see [LICENSE.md](LICENSE.md). For license details, visit [www.multiset.ai](https://www.multiset.ai).
