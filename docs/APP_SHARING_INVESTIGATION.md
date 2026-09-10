# App-sharing investigation: historical record

The original investigation is preserved in the [documentation archive](archive/APP_SHARING_INVESTIGATION_2025-02.md). Its failure descriptions and proposed fixes are historical, not a current feature assessment.

For the current workflows, read [LocalCast](LOCALCAST.md): use **Stream Controls → Apps** inside the Metal Streaming viewer to select a desktop, app, or window. **Screen Share + App Control** in device details is a separate option that combines macOS Screen Sharing with the LocalCast control channel.

The current implementation includes app-list timeouts, an empty response when host enumeration fails, and validation of requested app/window identifiers against the last advertised list. The original investigation predates those changes.

[Documentation index](README.md)
