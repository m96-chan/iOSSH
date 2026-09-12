# HackGen Console NF 2.10.0

These TrueType files are unmodified copies from the upstream release:

https://github.com/yuru7/HackGen/releases/tag/v2.10.0

Archive: https://github.com/yuru7/HackGen/releases/download/v2.10.0/HackGen_NF_v2.10.0.zip

The exact `HackGenConsoleNF` variant has a halfwidth/fullwidth ratio of 1:2
and Nerd Fonts symbols. The `35` (3:5 widths) variant is not bundled.
Upstream supplies Regular and Bold. The renderer synthesizes italic with
a glyph transform, without modifying the redistributed font files.

HackGen combines Hack, Gen Jyuu Gothic, and Nerd Fonts. The upstream
license and each source-font license are preserved in this directory and
included in the application resource bundle.

Source notices: https://github.com/yuru7/HackGen/tree/v2.10.0/source

SHA-256:

```
6c2d654cceb7ad2164d23e068bbae69647295413432ecfc970400b401d6f9873  HackGenConsoleNF-Regular.ttf
43b554e7ffccca4c1587d34ec139605bd3fa4b4843446bfb3334ab95cfb44e53  HackGenConsoleNF-Bold.ttf
```

## Noto Sans CJK JP 2.004 fallback

The Japanese-region Regular and Bold OpenType files are unmodified copies
from the official Noto CJK repository, tag `Sans2.004`, commit
`523d033d6cb47f4a80c58a35753646f5c3608a78`:

https://github.com/notofonts/noto-cjk/releases/tag/Sans2.004

Source files:

- https://raw.githubusercontent.com/notofonts/noto-cjk/523d033d6cb47f4a80c58a35753646f5c3608a78/Sans/OTF/Japanese/NotoSansCJKjp-Regular.otf
- https://raw.githubusercontent.com/notofonts/noto-cjk/523d033d6cb47f4a80c58a35753646f5c3608a78/Sans/OTF/Japanese/NotoSansCJKjp-Bold.otf

The upstream SIL Open Font License is preserved as `LICENSE_NotoSansCJKJP.txt`.
These fonts fill missing glyphs behind the selected primary font; HackGen
Console NF remains the default. Regular/Bold follows terminal style, and
italic uses a runtime glyph transform without altering the font files.
The renderer retains terminal cell widths when fitting fallback glyphs.

SHA-256:

```
68a3fc98800b2a27b371f2fb79991daf3633bd89309d4ffaa6946fd587f375b5  NotoSansCJKjp-Regular.otf
e53dcb0dcb2922e45d01aae1ebd2f382bb81d4229b18b6b883bd170678af1f76  NotoSansCJKjp-Bold.otf
```
