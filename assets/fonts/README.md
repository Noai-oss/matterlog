# HarmonyOS Sans SC

Matterlog uses HarmonyOS Sans SC.

- Source: <https://gitee.com/openharmony/global_system_resources/tree/6b8decf6f1096706940242fd6784248b9c503c99/fonts>
- Font: `HarmonyOS_Sans_SC.ttf`
- Font SHA-256: `8978e05044e7089ad6a9de38c505c8148305607983487435a916d2610700a7ca`
- License: HarmonyOS Sans Fonts License Agreement; see `LICENSE.txt`

The default install step copies the license next to the executable as
`HarmonyOS-Sans-LICENSE.txt`.

## Noto Emoji

Missing glyphs such as ✅ 🙂 🚀 use the embedded, monochrome Noto Emoji font.
The original font files are embedded without modification.

- Source: <https://github.com/google/fonts/tree/8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5/ofl/notoemoji>
- Upstream file: `NotoEmoji[wght].ttf`, stored here as `NotoEmoji.ttf`
- SHA-256: `de6c18832938afc99caf132b39d6a30a19bac7f2e812e28db2535b4608d27551`
- License: SIL Open Font License 1.1; see `NotoEmoji-LICENSE.txt`, also installed and included in the Windows ZIP.

The current renderer uses individual glyphs; color emoji and composed emoji
sequences (such as family/flag sequences) are not supported by this fallback.
