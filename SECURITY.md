# Security policy

## Scope

Screenshot Clipboard runs locally and handles screenshot data that may be
sensitive. The helper does not accept inbound network connections, make API
requests, or store account credentials.

The external ChatGPT/Gemini feature intentionally uses macOS Accessibility UI
automation. When invoked, the selected image is pasted into the chosen app and
that service may upload it according to its own policies.

## Reporting a vulnerability

Please do not open a public issue for a security vulnerability. Use GitHub’s
private vulnerability reporting for this repository when available. If it is
not enabled, contact the repository owner privately through the email or
private contact method listed on the owner’s GitHub profile.

Include:

- affected commit or version;
- macOS version and architecture;
- a minimal reproduction;
- impact and likely data exposure;
- a safe proof of concept, without real credentials or private screenshots.

Please allow reasonable time for investigation before public disclosure.

## User safety notes

- Keep the screenshot output folders local and out of source control.
- Review the target app and image before using an external translation action.
- Never paste API keys, passwords, or private customer data into a test image.
- Accessibility permission is powerful; grant it only to the copy of the app
  you intend to run.
