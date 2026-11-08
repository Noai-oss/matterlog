# Embedded fonts

## LXGW WenKai / 霞鹜文楷

Matterlog uses the proportional Medium face for Chinese and Latin text throughout
the interface, including titles, controls, records and text editors. The original
Medium outlines are registered as DVUI's normal face, without synthetic bold.

- Release: <https://github.com/lxgw/LxgwWenKai/releases/tag/v1.530>
- Source commit: `4becfb4d5cf0c92cfdb60a6e9b504bda43315325`
- Font: [`LXGWWenKai-Medium.ttf`](https://github.com/lxgw/LxgwWenKai/releases/download/v1.530/LXGWWenKai-Medium.ttf), embedded without modification
- SHA-256: `f4b8a34d1f838fe411540cb7c97b1c384ac9738a876c4104500bc42508b2312a`, verified against the official release asset digest
- License: SIL Open Font License 1.1; [`OFL.txt` at the pinned commit](https://github.com/lxgw/LxgwWenKai/blob/4becfb4d5cf0c92cfdb60a6e9b504bda43315325/OFL.txt), stored here as `LXGWWenKai-LICENSE.txt`

The default install step and Windows ZIP include `LXGWWenKai-LICENSE.txt`.

## Noto Emoji

Missing glyphs such as ✅ 🙂 🚀 use the embedded, monochrome Noto Emoji font.
The original font files are embedded without modification.

- Source: <https://github.com/google/fonts/tree/8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5/ofl/notoemoji>
- Upstream file: `NotoEmoji[wght].ttf`, stored here as `NotoEmoji.ttf`
- SHA-256: `de6c18832938afc99caf132b39d6a30a19bac7f2e812e28db2535b4608d27551`
- License: SIL Open Font License 1.1; see `NotoEmoji-LICENSE.txt`, also installed and included in the Windows ZIP.

The current renderer uses individual glyphs; color emoji and composed emoji
sequences (such as family/flag sequences) are not supported by this fallback.
