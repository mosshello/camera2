# camera2

## iOS debug startup modes

- Metro mode (default): keep `DEBUG_EMBED_BUNDLE=0` in `my-app/ios/.xcode.env`, then start Metro/dev-client as usual.
- Offline fallback mode: set `DEBUG_EMBED_BUNDLE=1` (in `my-app/ios/.xcode.env.local` is recommended), rebuild iOS app, and the app can fallback to embedded `main.jsbundle` when Metro is unavailable.

## Local network troubleshooting

- If you see `NSURLErrorDomain -1009` with `Denied over Wi-Fi interface`, enable **Local Network** for this app in iOS Settings.
- Ensure the iPhone and the development machine are on the same LAN and Metro is reachable at `http://<dev-ip>:8081/status`.
- Keep offline fallback available by rebuilding with `DEBUG_EMBED_BUNDLE=1` when Metro is intentionally unavailable.