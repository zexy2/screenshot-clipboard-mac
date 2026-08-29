# Troubleshooting

## No preview appears

1. Confirm the screenshot workflow is publishing an image to the general
   pasteboard. A file-only screenshot destination is not enough for a
   pasteboard watcher.
2. Check that the helper is running:

   ```bash
   launchctl print "gui/$(id -u)/com.zekiakgul.screenshot-clipboard-helper-launcher"
   ```

3. Reinstall if the LaunchAgent is missing:

   ```bash
   ./Scripts/install.sh
   ```

## The screenshot saves nowhere

Allow Desktop access when macOS asks. The default output is:

```text
~/Desktop/Ekran Görüntüleri/Mac Ekran Görüntüleri/
```

The helper will still keep the validated image in the preview path when a disk
save fails, but file actions that require a URL will be unavailable.

## `⌘V` pastes the previous image

The helper only reacts to PNG data placed on the general pasteboard. Make sure
the screenshot tool has finished publishing the new image, then try again. A
large or invalid PNG is rejected by the validation limits and is not copied.

## Native text translation does not work

- macOS must be 26 or newer.
- Open the menu-bar item and choose `Çeviri dillerini aç`.
- Install both Turkish and English under System Settings → General → Language
  & Region → Translation Languages.
- Grant Accessibility permission to Screenshot Clipboard if you want the
  translated text written back into the selected field.

If the target app or selection changes during the operation, the helper keeps
the translated result in the clipboard and refuses an unsafe paste.

## ChatGPT or Gemini handoff stops after opening the app

The external flow depends on the target app’s current Accessibility tree. Check
that:

- Screenshot Clipboard appears under System Settings → Privacy & Security →
  Accessibility;
- the target desktop app is installed and already signed in;
- a normal new-chat window can be opened manually;
- the app is not showing a login, quota, update, or modal dialog.

The helper stops when it cannot find the new-chat button, message field, or send
button. It does not submit to an existing conversation as a fallback and does
not retry indefinitely.

## How to collect a useful bug report

Include:

- macOS version and Mac architecture;
- whether the issue affects preview, clipboard, file saving, OCR, native
  translation, or external handoff;
- the exact shortcut/menu action;
- whether Desktop and Accessibility permissions are enabled;
- the output of `./Scripts/check.sh`;
- a sanitized reproduction description. Do not attach screenshots containing
  secrets, account data, API keys, or personal information.
