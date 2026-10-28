# Cloud weather rendering

macOS and iOS share the same Metal cloud field, density atlas and native surface. The macOS weather adapter supplies its performance configuration, scene state and clear interaction; the iOS dashboard supplies its weather snapshot and existing accessibility, thermal and power policy. Other weather conditions keep their existing renderers.

`CinematicCloudView` renders an opaque sky with linear-light scattering and explicit sRGB display output. Intensity, wind and quality accept finite values and clamp them to 0...1. `isAnimating: false` preserves a static frame and redraws only when the viewport or visual parameters change. The caller owns scene/power policy; the native surface owns cadence and releases its drawable on dismantling.

The cloud viewport caps its shorter dimension at 600 pixels and its longer dimension at 1300 pixels. Lower quality uses 75% of that size and 24 view steps; normal quality uses 48 steps. At most two GPU frames may be in flight. Resource compilation runs away from the main actor and transfers exclusive ownership of the resulting resources to the surface. Missing resources and GPU failures are reported explicitly.

The 528 × 528 RGBA8 atlas stores periodic density channels, with border texels around 64 depth slices. It is data, so it must not undergo image colour conversion. `Scripts/sync_cloud_weather.py` in the containing repository exports the field and atlas from the approved Android source and checks subsequent drift:

```sh
python3 Scripts/sync_cloud_weather.py --android-root '/path/to/SkyBridge Compass - Android' --check
swift test --package-path Packages/SkyBridgeWeatherRendering -Xswiftc -warnings-as-errors
```

The tests render the real Metal program and verify opaque output, shading, text-area luminance, wind continuity, aspect preservation, bounded resolution and pause behaviour. The native surface test also checks display colour space and loading while paused.

Physical iOS tests use the separate `Tests/HostApp` project, which links this production package and the same test files. It has its own app identity and no account, network or persistence features. Regenerate its Xcode project with `xcodegen generate --spec project.yml`, then run the `CloudRenderingHost` scheme on a paired device. It does not replace the SkyBridge product app.
