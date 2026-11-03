# App-sharing investigation: historical record

The original investigation is preserved in the [documentation archive](archive/APP_SHARING_INVESTIGATION_2025-02.md). Its failure descriptions and proposed fixes are historical, not a current feature assessment.

For the current workflows, read [LocalCast](LOCALCAST.md): use **Stream Controls → Apps** inside the Metal Streaming viewer to select a desktop, app, or window. **LocalCast + App Control** in device details opens a companion panel for app focus and isolation on the same LocalCast viewer connection.

The current implementation includes app-list timeouts, an empty response when host enumeration fails, and validation of requested app/window identifiers against the last advertised list. The original investigation predates those changes.

[Documentation index](README.md)
